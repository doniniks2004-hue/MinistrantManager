import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import '../../core/util/store_link_launcher.dart';
import '../config/config_service.dart';
import '../dashboard/module_version_gate.dart';

/// Review round 2, point 5 fix: `GET /api/client-config` (maintenance
/// mode, global forced-update) was documented as checkable BEFORE
/// activation, but nothing actually called `loadClientConfig()` until
/// `HomeScreen`, which only exists AFTER activation. A brand new install
/// therefore never saw maintenance mode or a global forced update at the
/// one moment it matters most — first launch.
///
/// This widget sits in front of BOTH `ActivationScreen` and `HomeScreen`
/// (see main.dart), enforcing exactly the ordering requested:
///
///   app start -> load cached/fresh client config -> maintenance/update
///   gate -> only then activation/home.
///
/// Per explicit instruction: no internet AND no cache yet must NOT block
/// first activation — `ConfigService.loadClientConfig()` already returns
/// null in exactly that case (no fresh fetch, no cache to fall back to),
/// and this widget treats null as "nothing to gate on, proceed" rather
/// than a failure.
class PreflightGate extends StatefulWidget {
  const PreflightGate({
    super.key,
    required this.configService,
    required this.appVersion,
    required this.child,
  });

  final ConfigService configService;
  final String appVersion;
  final Widget child;

  @override
  State<PreflightGate> createState() => _PreflightGateState();
}

class _PreflightGateState extends State<PreflightGate> {
  Map<String, dynamic>? _config;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final config = await widget.configService.loadClientConfig();
    if (!mounted) return;
    setState(() {
      _config = config;
      _checked = true;
    });
  }

  void _retry() {
    setState(() => _checked = false);
    _check();
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final config = _config;

    // No fresh fetch AND no cache (first launch, offline) — do not block.
    if (config == null) {
      return widget.child;
    }

    if (config['maintenance_mode'] == true) {
      return _MaintenanceScreen(
        message: config['maintenance_message'] as String?,
        onRetry: _retry,
      );
    }

    final minVersionKey = Platform.isIOS ? 'minimum_supported_ios_version' : 'minimum_supported_android_version';
    final storeUrlKey = Platform.isIOS ? 'ios_store_url' : 'android_store_url';
    final minVersion = config[minVersionKey] as String?;

    if (minVersion != null && ModuleVersionGate.isOlderThan(widget.appVersion, minVersion)) {
      return _ForcedUpdateScreen(
        minVersion: minVersion,
        storeUrl: config[storeUrlKey] as String?,
        onRetry: _retry,
      );
    }

    return widget.child;
  }
}

class _MaintenanceScreen extends StatelessWidget {
  const _MaintenanceScreen({required this.message, required this.onRetry});
  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.build_circle_outlined, size: 48, color: Colors.orange),
            const SizedBox(height: 16),
            Text(
              (message?.isNotEmpty ?? false) ? message! : 'Ministrant Manager jest chwilowo w trybie konserwacji.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('SPRÓBUJ PONOWNIE')),
          ]),
        ),
      ),
    );
  }
}

class _ForcedUpdateScreen extends StatelessWidget {
  const _ForcedUpdateScreen({required this.minVersion, required this.storeUrl, required this.onRetry});
  final String minVersion;
  final String? storeUrl;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final hasStoreUrl = storeUrl != null && storeUrl!.isNotEmpty;
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
            Text('Wymagana wersja: $minVersion lub nowsza.', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            if (hasStoreUrl)
              FilledButton(onPressed: () => StoreLinkLauncher.open(storeUrl), child: const Text('AKTUALIZUJ'))
            else
              const Text('Aktualizacja wkrótce dostępna.', style: TextStyle(color: Colors.grey)),
          ]),
        ),
      ),
    );
  }
}

