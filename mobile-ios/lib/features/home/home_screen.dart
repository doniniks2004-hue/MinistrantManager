import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/util/store_link_launcher.dart';
import '../../core/database/app_database.dart';
import '../../core/sync/sync_engine.dart';
import '../auth/login_screen.dart';
import '../auth/user_session_service.dart';
import '../config/config_service.dart';
import '../device_settings/device_settings_screen.dart';
import '../../core/offline/offline_page_coordinator.dart';
import '../revocation/revocation_handler.dart';
import '../webview/offline_aware_page_screen.dart';

/// Spec §26–§28: renders instantly from SQLite, shows an OFFLINE banner
/// with the timestamp of the last known-good sync when relevant, and
/// updates reactively once the background sync completes.
///
/// Hybrid dashboard milestone: this screen owns the DEVICE-level
/// Owns device/user lifecycle and, after login, opens the real legacy PHP
/// dashboard through the offline-aware WebView. The PHP page is the
/// single source of truth for the post-login UI; native Flutter UI is
/// intentionally limited to activation, login, device state and the
/// single allowed offline-status banner.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.db,
    required this.syncEngine,
    required this.configService,
    required this.revocationHandler,
    required this.userSessionService,
    required this.offlinePageCoordinator,
    required this.onRevoked,
    required this.appVersion,
    required this.osVersion,
  });

  final AppDatabase db;
  final SyncEngine syncEngine;
  final ConfigService configService;
  final RevocationHandler revocationHandler;
  final UserSessionService userSessionService;

  /// P13 fix: constructed once in main.dart (rebuilt fresh on every
  /// revoke/reset cycle, same as everything else wired there) and passed
  /// down here, rather than this screen building its own
  /// WebviewHandoffService internally the way it used to — the real
  /// online<->offline chain needs a SHARED OfflinePageCoordinator with a
  /// SHARED LocalSnapshotServer instance (its rootDirectory gets
  /// repointed per page load; a screen-local one would lose that state
  /// every time this widget rebuilds). Its own `handoffService` field is
  /// how OfflineAwarePageScreen reaches WebviewHandoffService when it
  /// needs to — nothing here needs a separate reference to it.
  final OfflinePageCoordinator offlinePageCoordinator;

  final VoidCallback onRevoked;
  final String appVersion;
  final String osVersion;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  DeviceAuthState? _authState;
  String? _minimumSupportedAppVersion;
  Map<String, dynamic>? _clientConfig;
  bool? _hasUserSession; // null while checking
  int? _userId;
  String? _parishId;
  String? _serverUrl;

  /// True once the identifiers above have been read from local storage for
  /// the CURRENT session (reset when a login completes, since the values
  /// from before it no longer apply). Separates "still being read" — a
  /// spinner is right — from "read, and something is missing" — which is an
  /// error the user must be able to act on, not a spinner.
  bool _identityRead = false;

  /// The very first local read failed, so nothing is known about this
  /// device's state. There is no cached state to fall back on; without this
  /// flag the screen stayed on its first-frame spinner indefinitely.
  bool _stateLoadFailed = false;
  bool _syncInProgress = false;
  int _sessionGeneration = 0;
  Timer? _leaseTimer;

  Future<void> _openDeviceSettings() async {
    final slug = await widget.userSessionService.secureStorage.parishSlug;
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
          builder: (_) => DeviceSettingsScreen(
                revocationHandler: widget.revocationHandler,
                parishSlug: slug,
                onParishReset: () {
                  _sessionGeneration++;
                  Navigator.of(context).popUntil((route) => route.isFirst);
                  widget.onRevoked();
                },
              )),
    );
  }

  /// A state the user can act on, instead of a spinner that never ends.
  /// The app bar keeps the device-settings entry (including "change
  /// parish"), the one way out when the stored device data itself is bad.
  Scaffold _problemScaffold({
    required String message,
    bool showLogout = false,
  }) =>
      Scaffold(
        appBar: _deviceSettingsBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _bootstrapThenSync,
                  child: const Text('SPRÓBUJ PONOWNIE'),
                ),
                if (showLogout) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _onLogout,
                    child: const Text('WYLOGUJ'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );

  AppBar _deviceSettingsBar() => AppBar(
        title: const Text('Ministrant Manager'),
        actions: [
          IconButton(
            tooltip: 'Urządzenie / Parafia',
            onPressed: _openDeviceSettings,
            icon: const Icon(Icons.settings_outlined),
          )
        ],
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrapThenSync();
    _leaseTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkLocalLease(),
    );
  }

  Future<void> _checkLocalLease() async {
    bool allowsData() =>
        _authState == DeviceAuthState.active ||
        _authState == DeviceAuthState.offlineWithinLease;
    if (!allowsData()) return;
    final generation = _sessionGeneration;
    try {
      final meta = await widget.db.ensureSyncMetadata();
      if (!mounted || generation != _sessionGeneration || !allowsData()) return;
      if (!widget.syncEngine.offlineLease.isWithinLease(
        meta.lastAuthorizationCheck,
        leaseHours: meta.offlineLeaseHours,
      )) {
        widget.offlinePageCoordinator.localServer.rootDirectory = null;
        setState(() => _authState = DeviceAuthState.offlineLeaseExpired);
        unawaited(_bootstrapThenSync());
      }
    } catch (_) {
      // A reset may close the previous database while this check is pending.
    }
  }

  @override
  void dispose() {
    _sessionGeneration++;
    _leaseTimer?.cancel();
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

  /// Always assigned together, and always from storage: marks the
  /// identifiers as read so the build can tell "missing" from "loading".
  void _applyIdentity({
    required bool hasUserSession,
    int? userId,
    String? parishId,
    String? serverUrl,
  }) {
    _hasUserSession = hasUserSession;
    _userId = userId;
    _parishId = parishId;
    _serverUrl = serverUrl;
    _identityRead = true;
  }

  /// The host of the stored server URL, or null if there is no URL or it has
  /// no host. `Uri.parse(url).host` on a malformed value used to throw
  /// inside build().
  String? get _serverHost {
    final url = _serverUrl;
    if (url == null) return null;
    final host = Uri.tryParse(url)?.host;
    return (host == null || host.isEmpty) ? null : host;
  }

  Future<void> _bootstrapThenSync() async {
    if (_syncInProgress) return;
    _syncInProgress = true;
    final generation = _sessionGeneration;
    if (_stateLoadFailed && mounted) {
      setState(() => _stateLoadFailed = false);
    }
    try {
      await _refreshState(generation);
    } catch (_) {
      // Preserve the locally validated lease state on malformed responses.
      // But if nothing has been established locally yet there is no state
      // to preserve, and silently returning leaves the spinner up forever.
      if (mounted &&
          generation == _sessionGeneration &&
          _hasUserSession == null) {
        setState(() => _stateLoadFailed = true);
      }
    } finally {
      _syncInProgress = false;
      if (mounted && generation != _sessionGeneration)
        unawaited(_bootstrapThenSync());
    }
  }

  Future<void> _refreshState(int generation) async {
    // Client-config (global: store URLs, maintenance mode) is checked
    // unconditionally and first — it has no activation dependency and
    // must be available even to a screen that's about to show a blocking
    // UPDATE_REQUIRED/maintenance state.
    // OFFLINE-FIRST: establish the local UI state before ANY network request.
    final localHasUserSession =
        await widget.userSessionService.secureStorage.hasUserSession;
    final localUserId = localHasUserSession
        ? await widget.userSessionService.secureStorage.currentUserId
        : null;
    final localParishId = localHasUserSession
        ? await widget.userSessionService.secureStorage.parishId
        : null;
    final localServerUrl = localHasUserSession
        ? await widget.userSessionService.secureStorage.serverUrl
        : null;
    final localMeta = await widget.db.ensureSyncMetadata();
    final localWithinLease = widget.syncEngine.offlineLease.isWithinLease(
      localMeta.lastAuthorizationCheck,
      leaseHours: localMeta.offlineLeaseHours,
    );

    if (!mounted || generation != _sessionGeneration) return;
    setState(() {
      _authState = localWithinLease
          ? DeviceAuthState.offlineWithinLease
          : DeviceAuthState.offlineLeaseExpired;
      _applyIdentity(
        hasUserSession: localHasUserSession,
        userId: localUserId,
        parishId: localParishId,
        serverUrl: localServerUrl,
      );
    });

    // Global config and device authorization are independent; a config timeout
    // must not postpone a confirmed revocation or opening the online page.
    final configFuture = widget.configService.loadClientConfig().catchError(
          (_) => null,
        );

    final status = await widget.syncEngine.checkDeviceStatus(
      appVersion: widget.appVersion,
      osVersion: widget.osVersion,
    );

    if (!mounted || generation != _sessionGeneration) return;
    if (status == null) {
      // Not activated — shouldn't normally reach HomeScreen in this state.
      return;
    }

    setState(() {
      _authState = status.state;
      _minimumSupportedAppVersion = status.minimumSupportedAppVersion;
    });

    if (status.state != DeviceAuthState.active &&
        status.state != DeviceAuthState.offlineWithinLease) {
      widget.offlinePageCoordinator.localServer.rootDirectory = null;
    }
    if (status.state == DeviceAuthState.revoked ||
        status.state == DeviceAuthState.parishDisabled) {
      await widget.revocationHandler.handle(status.state);
      widget.onRevoked();
      return;
    }

    if (status.state == DeviceAuthState.updateRequired) {
      // Block here — do NOT sync or render cached data past this point
      // until the user updates, since the server has explicitly said
      // this app version is no longer supported (spec §29).
      return;
    }

    if (status.state == DeviceAuthState.authError) {
      // Review round: explicit 401/403/unrecognized-status — fail closed.
      // Deliberately NOT the same handling as revoked/parishDisabled: this
      // is not a confirmed revocation signal (could be a transient server
      // bug, a genuinely unknown token, or a forward-compat gap), so local
      // data is NOT wiped — just not shown until a real ACTIVE/REVOKED/
      // PARISH_DISABLED answer is obtained.
      return;
    }

    // Is a USER actually signed in on this device? Checked regardless of
    // online/offline device state (offlineWithinLease still shows the
    // login screen if no one's signed in yet).
    final hasUserSession =
        await widget.userSessionService.secureStorage.hasUserSession;

    final earlyUserId = hasUserSession
        ? await widget.userSessionService.secureStorage.currentUserId
        : null;
    final earlyParishId = hasUserSession
        ? await widget.userSessionService.secureStorage.parishId
        : null;
    final earlyServerUrl = hasUserSession
        ? await widget.userSessionService.secureStorage.serverUrl
        : null;
    if (!mounted || generation != _sessionGeneration) return;
    setState(() {
      _applyIdentity(
        hasUserSession: hasUserSession,
        userId: earlyUserId,
        parishId: earlyParishId,
        serverUrl: earlyServerUrl,
      );
    });
    unawaited(
      configFuture.then((config) {
        if (mounted && generation == _sessionGeneration)
          setState(() => _clientConfig = config);
      }),
    );

    if (status.state == DeviceAuthState.active && hasUserSession) {
      try {
        await widget.syncEngine.runFullSync();
        await widget.syncEngine.heartbeat(
          appVersion: widget.appVersion,
          osVersion: widget.osVersion,
        );
        // Online sync succeeded; the PHP dashboard below remains the single source of truth for the UI.
      } on ParishSessionExpiredException {
        // Review round point 4: the PARISH rejected the mobile_user_token
        // — a USER session problem, never a device problem. Clear ONLY
        // the user session and fall through to the login screen; device
        // activation is completely untouched.
        if (!mounted || generation != _sessionGeneration) return;
        await widget.userSessionService.handleParishSessionExpired();
        if (mounted && generation == _sessionGeneration)
          setState(() {
            _hasUserSession = false;
          });
        return;
      } on ParishContractErrorException {
        // Review round fix, point 2: a genuine CONTRACT error
        // (400/403/422 — e.g. the real missing-X-Installation-Id bug)
        // must NEVER be swallowed as a plain network hiccup — that would
        // silently render an empty dashboard/module as if the user
        // genuinely had no data, while the sync in fact never even ran.
        // The PHP page remains available; no internal response is logged.
        // Keep the authenticated PHP dashboard as the UI source of truth even if background sync fails.
      } catch (_) {
        // Genuine transport failure / timeout / 5xx — cached data on
        // screen is still valid, no visible error needed (spec §26).
      }
    }

    final userId = hasUserSession
        ? await widget.userSessionService.secureStorage.currentUserId
        : null;
    final parishId = hasUserSession
        ? await widget.userSessionService.secureStorage.parishId
        : null;
    final serverUrl = hasUserSession
        ? await widget.userSessionService.secureStorage.serverUrl
        : null;

    if (!mounted || generation != _sessionGeneration) return;
    setState(() {
      _applyIdentity(
        hasUserSession: hasUserSession,
        userId: userId,
        parishId: parishId,
        serverUrl: serverUrl,
      );
    });
  }

  Future<void> _onLogout() async {
    _sessionGeneration++;
    widget.offlinePageCoordinator.localServer.rootDirectory = null;
    await widget.userSessionService.logout();
    if (mounted)
      setState(() {
        _hasUserSession = false;
        _userId = null;
      });
  }

  void _onLoggedIn() {
    _sessionGeneration++;
    setState(() {
      _hasUserSession = true;
      _identityRead = false;
    });
    _bootstrapThenSync();
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.build_circle_outlined,
                  size: 48,
                  color: Colors.orange,
                ),
                const SizedBox(height: 16),
                Text(
                  (_clientConfig?['maintenance_message'] as String?)
                              ?.isNotEmpty ==
                          true
                      ? _clientConfig!['maintenance_message'] as String
                      : 'Ministrant Manager jest chwilowo w trybie konserwacji.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _bootstrapThenSync,
                  child: const Text('SPRÓBUJ PONOWNIE'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_authState == DeviceAuthState.updateRequired) {
      final hasStoreUrl = Theme.of(context).platform == TargetPlatform.iOS
          ? (_clientConfig?['ios_store_url'] as String?)?.isNotEmpty == true
          : (_clientConfig?['android_store_url'] as String?)?.isNotEmpty ==
              true;

      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                  child: Text(
                    hasStoreUrl
                        ? 'AKTUALIZUJ'
                        : 'Aktualizacja wkrótce dostępna',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_authState == DeviceAuthState.authError) {
      return Scaffold(
        appBar: _deviceSettingsBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                const Text(
                  'Nie udało się potwierdzić autoryzacji tego urządzenia.\nSpróbuj ponownie za chwilę.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _bootstrapThenSync,
                  child: const Text('SPRÓBUJ PONOWNIE'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final isOfflineExpired = _authState == DeviceAuthState.offlineLeaseExpired;

    if (isOfflineExpired) {
      return Scaffold(
        appBar: _deviceSettingsBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off, size: 48, color: Colors.grey),
                const SizedBox(height: 16),
                const Text(
                  'Dostęp do danych wymaga ponownego połączenia\nz serwerem Ministrant Manager.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _bootstrapThenSync,
                  child: const Text('SPRÓBUJ PONOWNIE'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_stateLoadFailed) {
      return _problemScaffold(
        message:
            'Nie udało się odczytać danych aplikacji z urządzenia.\nSpróbuj ponownie.',
      );
    }

    if (_hasUserSession == null) {
      // Still checking (first frame) — device-level checks above already
      // completed by the time we'd reach here in practice, but guard
      // against a flash of the wrong screen regardless.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_hasUserSession == false) {
      return LoginScreen(
        userSessionService: widget.userSessionService,
        onLoggedIn: _onLoggedIn,
        onOpenDeviceSettings: _openDeviceSettings,
      );
    }

    final host = _serverHost;
    if (_userId == null || _parishId == null || host == null) {
      // Still being read: a spinner is right. Already read and something
      // is missing or unusable: it will not fix itself, so say so and
      // offer the ways out instead of spinning forever.
      if (!_identityRead) {
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      }
      return _problemScaffold(
        message:
            'Brakuje danych potrzebnych do otwarcia strony (parafia lub adres serwera).\nWyloguj się i zaloguj ponownie albo zmień parafię w ustawieniach urządzenia.',
        showLogout: true,
      );
    }

    return OfflineAwarePageScreen(
      key: ValueKey('$_parishId:$_userId'),
      title: 'Ministrant Manager',
      targetPath: '/public/dashboard.php',
      allowedHost: host,
      parishId: _parishId!,
      userId: _userId!.toString(),
      coordinator: widget.offlinePageCoordinator,
      forceOffline: _authState != DeviceAuthState.active,
      onLogout: _onLogout,
    );
  }
}
