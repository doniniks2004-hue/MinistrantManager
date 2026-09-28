import 'package:flutter/material.dart';
import '../../core/util/store_link_launcher.dart';
import '../../core/database/app_database.dart';
import '../../core/sync/sync_engine.dart';import '../auth/login_screen.dart';
import '../auth/user_session_service.dart';
import '../config/config_service.dart';
import '../revocation/revocation_handler.dart';
import '../schedule/my_schedule_screen.dart';

/// Spec §26–§28: renders instantly from SQLite, shows an OFFLINE banner
/// with the timestamp of the last known-good sync when relevant, and
/// updates reactively once the background sync completes.
///
/// Milestone "Mój grafik" (review round): this screen owns the
/// DEVICE-level lifecycle (status/heartbeat/revoke/offline-lease,
/// maintenance/update-required — all unchanged) AND now also the
/// USER-level lifecycle on top of it: once the device is confirmed
/// active/offline-ok, it checks whether a `mobile_user_token` exists
/// (UserSessionService) and shows LoginScreen if not, or MyScheduleScreen
/// if so. A device problem and a "no user signed in yet" state are
/// different things, checked in that order, never conflated.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.db,
    required this.syncEngine,
    required this.configService,
    required this.revocationHandler,
    required this.userSessionService,
    required this.onRevoked,
    required this.appVersion,
    required this.osVersion,
  });

  final AppDatabase db;
  final SyncEngine syncEngine;
  final ConfigService configService;
  final RevocationHandler revocationHandler;
  final UserSessionService userSessionService;
  final VoidCallback onRevoked;
  final String appVersion;
  final String osVersion;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  DeviceAuthState? _authState;
  String? _minimumSupportedAppVersion;
  DateTime? _lastSyncAt;
  bool _syncing = false;
  bool _lastSyncFailed = false;
  Map<String, dynamic>? _clientConfig;
  bool? _hasUserSession; // null while checking

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrapThenSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground resume is one of the three real sync triggers on iOS
    // (spec §26 / iOS background-execution note) — this is not optional.
    if (state == AppLifecycleState.resumed) {
      _bootstrapThenSync();
    }
  }

  Future<void> _bootstrapThenSync() async {
    setState(() => _syncing = true);

    // Client-config (global: store URLs, maintenance mode) is checked
    // unconditionally and first — it has no activation dependency and
    // must be available even to a screen that's about to show a blocking
    // UPDATE_REQUIRED/maintenance state.
    final clientConfig = await widget.configService.loadClientConfig();

    final status = await widget.syncEngine.checkDeviceStatus(
      appVersion: widget.appVersion,
      osVersion: widget.osVersion,
    );

    if (status == null) {
      // Not activated — shouldn't normally reach HomeScreen in this state.
      return;
    }

    setState(() {
      _authState = status.state;
      _minimumSupportedAppVersion = status.minimumSupportedAppVersion;
      _clientConfig = clientConfig;
    });

    if (status.state == DeviceAuthState.revoked || status.state == DeviceAuthState.parishDisabled) {
      await widget.revocationHandler.handle(status.state);
      widget.onRevoked();
      return;
    }

    if (status.state == DeviceAuthState.updateRequired) {
      // Block here — do NOT sync or render cached data past this point
      // until the user updates, since the server has explicitly said
      // this app version is no longer supported (spec §29).
      setState(() => _syncing = false);
      return;
    }

    if (status.state == DeviceAuthState.authError) {
      // Review round: explicit 401/403/unrecognized-status — fail closed.
      // Deliberately NOT the same handling as revoked/parishDisabled: this
      // is not a confirmed revocation signal (could be a transient server
      // bug, a genuinely unknown token, or a forward-compat gap), so local
      // data is NOT wiped — just not shown until a real ACTIVE/REVOKED/
      // PARISH_DISABLED answer is obtained.
      setState(() => _syncing = false);
      return;
    }

    // Milestone "Mój grafik", review round point 2/4: is a USER actually
    // signed in on this device? Checked regardless of online/offline
    // device state (offlineWithinLease still shows the login screen if no
    // one's signed in yet — there's simply nothing user-scoped to show
    // offline in that case).
    final hasUserSession = await widget.userSessionService.secureStorage.hasUserSession;

    if (status.state == DeviceAuthState.active && hasUserSession) {
      try {
        await widget.syncEngine.runFullSync();
        await widget.syncEngine.heartbeat(appVersion: widget.appVersion, osVersion: widget.osVersion);
        _lastSyncFailed = false;
      } on ParishSessionExpiredException {
        // Review round point 4: the PARISH rejected the mobile_user_token
        // — a USER session problem, never a device problem. Clear ONLY
        // the user session and fall through to the login screen; device
        // activation is completely untouched.
        await widget.userSessionService.handleParishSessionExpired();
        setState(() {
          _hasUserSession = false;
          _syncing = false;
        });
        return;
      } on ParishContractErrorException catch (e) {
        // Review round fix, point 2: a genuine CONTRACT error
        // (400/403/422 — e.g. the real missing-X-Installation-Id bug)
        // must NEVER be swallowed as a plain network hiccup — that would
        // silently render an empty "Mój grafik" as if the user genuinely
        // had no assignments, while the sync in fact never even ran.
        // The existing snapshot is untouched either way (the failure
        // happened before any SQLite write) — this just makes the
        // failure VISIBLE instead of invisible.
        debugPrint('Parish contract error during sync: $e');
        _lastSyncFailed = true;
      } catch (_) {
        // Genuine transport failure / timeout / 5xx — cached data on
        // screen is still valid, no visible error needed (spec §26).
      }
    }

    final meta = await widget.db.ensureSyncMetadata();
    setState(() {
      _lastSyncAt = meta.lastSyncAt;
      _hasUserSession = hasUserSession;
      _syncing = false;
    });
  }

  void _onLoggedIn() {
    setState(() => _hasUserSession = true);
    _bootstrapThenSync();
  }

  Future<void> _onLogout() async {
    await widget.userSessionService.logout();
    setState(() => _hasUserSession = false);
  }

  Future<void> _openStoreListing() async {
    final url = Theme.of(context).platform == TargetPlatform.iOS
        ? (_clientConfig?['ios_store_url'] as String?)
        : (_clientConfig?['android_store_url'] as String?);
    await StoreLinkLauncher.open(url);
  }

  @override
  Widget build(BuildContext context) {
    if (_clientConfig?['maintenance_mode'] == true) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.build_circle_outlined, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                (_clientConfig?['maintenance_message'] as String?)?.isNotEmpty == true
                    ? _clientConfig!['maintenance_message'] as String
                    : 'Ministrant Manager jest chwilowo w trybie konserwacji.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: _bootstrapThenSync, child: const Text('SPRÓBUJ PONOWNIE')),
            ]),
          ),
        ),
      );
    }

    if (_authState == DeviceAuthState.updateRequired) {
      final hasStoreUrl = Theme.of(context).platform == TargetPlatform.iOS
          ? (_clientConfig?['ios_store_url'] as String?)?.isNotEmpty == true
          : (_clientConfig?['android_store_url'] as String?)?.isNotEmpty == true;

      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.system_update, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              const Text(
                'Dostępna jest wymagana aktualizacja Ministrant Manager.',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Aby kontynuować, zaktualizuj aplikację'
                '${_minimumSupportedAppVersion != null ? " do wersji ${_minimumSupportedAppVersion!} lub nowszej" : ""}.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: hasStoreUrl ? _openStoreListing : null,
                child: Text(hasStoreUrl ? 'AKTUALIZUJ' : 'Aktualizacja wkrótce dostępna'),
              ),
            ]),
          ),
        ),
      );
    }

    if (_authState == DeviceAuthState.authError) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                'Nie udało się potwierdzić autoryzacji tego urządzenia.\nSpróbuj ponownie za chwilę.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: _bootstrapThenSync, child: const Text('SPRÓBUJ PONOWNIE')),
            ]),
          ),
        ),
      );
    }

    final isOfflineExpired = _authState == DeviceAuthState.offlineLeaseExpired;

    if (isOfflineExpired) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.wifi_off, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              const Text(
                'Dostęp do danych wymaga ponownego połączenia\nz serwerem Ministrant Manager.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: _bootstrapThenSync, child: const Text('SPRÓBUJ PONOWNIE')),
            ]),
          ),
        ),
      );
    }

    if (_hasUserSession == null) {
      // Still checking (first frame) — device-level checks above already
      // completed by the time we'd reach here in practice, but guard
      // against a flash of the wrong screen regardless.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_hasUserSession == false) {
      return LoginScreen(userSessionService: widget.userSessionService, onLoggedIn: _onLoggedIn);
    }

    final showOfflineBanner = _authState == DeviceAuthState.offlineWithinLease;

    return MyScheduleScreen(
      db: widget.db,
      onLogout: _onLogout,
      showOfflineBanner: showOfflineBanner,
      lastSyncAt: _lastSyncAt,
      showSyncFailedBanner: _lastSyncFailed,
    );
  }
}
