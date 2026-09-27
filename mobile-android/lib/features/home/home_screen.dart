import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/database/app_database.dart';
import '../../core/sync/sync_engine.dart';
import '../config/config_service.dart';
import '../dashboard/dashboard_renderer.dart';
import '../revocation/revocation_handler.dart';

/// Spec §26–§28: renders instantly from SQLite, shows an OFFLINE banner
/// with the timestamp of the last known-good sync when relevant, and
/// updates reactively once the background sync completes. The dashboard
/// body itself is server-driven (spec §15–§19) via DashboardRenderer —
/// this screen owns the sync/auth-state lifecycle around it, not the
/// dashboard's actual layout/content.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.db,
    required this.syncEngine,
    required this.configService,
    required this.revocationHandler,
    required this.onRevoked,
    required this.appVersion,
    required this.osVersion,
  });

  final AppDatabase db;
  final SyncEngine syncEngine;
  final ConfigService configService;
  final RevocationHandler revocationHandler;
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
  Map<String, dynamic>? _dashboardConfig;
  Map<String, dynamic>? _clientConfig;

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

    if (status.state == DeviceAuthState.active) {
      try {
        await widget.syncEngine.runFullSync();
        await widget.syncEngine.heartbeat(appVersion: widget.appVersion, osVersion: widget.osVersion);
      } catch (_) {
        // Network hiccup mid-sync — cached data on screen is still valid.
      }
    }

    // Dashboard config fetch-or-cache (spec §19) happens regardless of
    // whether the business-data sync above succeeded — a parish that
    // changed its module order should see that even on a run where the
    // bootstrap/sync call itself timed out.
    final dashboardConfig = await widget.configService.loadDashboardConfig();

    final meta = await widget.db.ensureSyncMetadata();
    setState(() {
      _lastSyncAt = meta.lastSyncAt;
      _dashboardConfig = dashboardConfig;
      _syncing = false;
    });
  }

  Future<void> _openStoreListing() async {
    final url = Theme.of(context).platform == TargetPlatform.iOS
        ? (_clientConfig?['ios_store_url'] as String?)
        : (_clientConfig?['android_store_url'] as String?);
    if (url == null || url.isEmpty) return; // spec decision #15: no link yet published — button simply does nothing extra
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
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

    final showOfflineBanner = _authState == DeviceAuthState.offlineWithinLease;

    return Scaffold(
      appBar: AppBar(title: const Text('Ministrant Manager')),
      body: RefreshIndicator(
        onRefresh: _bootstrapThenSync,
        child: ListView(children: [
          if (showOfflineBanner)
            Container(
              width: double.infinity,
              color: Colors.amber.shade100,
              padding: const EdgeInsets.all(12),
              child: Text(
                '⚠ OFFLINE — dane z ${_lastSyncAt != null ? _formatDate(_lastSyncAt!) : "poprzedniej synchronizacji"}',
                textAlign: TextAlign.center,
              ),
            )
          else if (_lastSyncAt != null && !_syncing)
            Container(
              width: double.infinity,
              color: Colors.green.shade50,
              padding: const EdgeInsets.all(8),
              child: const Text('✓ Zsynchronizowano', textAlign: TextAlign.center),
            ),
          if (_dashboardConfig != null)
            DashboardRenderer(config: _dashboardConfig!, deviceAppVersion: widget.appVersion)
          else
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Konfiguracja dashboardu nie jest jeszcze dostępna (brak połączenia i brak wcześniejszego cache).',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ),
        ]),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}, ${two(local.hour)}:${two(local.minute)}';
  }
}
