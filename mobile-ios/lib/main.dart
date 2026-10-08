import 'dart:async';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'core/deeplink/deep_link_service.dart';
import 'core/network/api_client.dart';
import 'core/secure/secure_storage_service.dart';
import 'core/startup/app_services.dart';
import 'core/util/startup_trace.dart';
import 'features/activation/activation_screen.dart';
import 'features/home/home_screen.dart';
import 'features/preflight/preflight_gate.dart';
import 'features/startup/startup_error_screen.dart';

void main() {
  StartupTrace.mark('main');
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MinistrantManagerApp());
}

class MinistrantManagerApp extends StatefulWidget {
  const MinistrantManagerApp({
    super.key,
    this.buildServices = buildAppServices,
    this.deepLinkService,
    this.startupTimeout = const Duration(seconds: 20),
  });

  /// Opens the encrypted database and wires every service that depends on
  /// it. Injectable so the startup failure paths can be tested.
  final AppServicesBuilder buildServices;
  final DeepLinkService? deepLinkService;

  /// Upper bound for the whole startup sequence (secure storage, database
  /// open, service wiring). A platform call that never answers must end in
  /// an error screen with a retry, never in an indefinite spinner.
  final Duration startupTimeout;

  @override
  State<MinistrantManagerApp> createState() => _MinistrantManagerAppState();
}

/// What one successful startup attempt produced. Applied to the state in a
/// single step, so a late or abandoned attempt can never leave the app
/// half-initialised.
class _StartupData {
  const _StartupData({
    required this.appVersion,
    required this.osVersion,
    required this.activated,
    required this.services,
  });

  final String appVersion;
  final String osVersion;
  final bool activated;
  final AppServices services;
}

class _MinistrantManagerAppState extends State<MinistrantManagerApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final SecureStorageService _secureStorage;
  late final ApiClient _api;
  late final DeepLinkService _deepLinkService =
      widget.deepLinkService ?? DeepLinkService();
  String? _pendingDeepLinkToken;

  /// The services built by the latest successful startup. Replaced as one
  /// set after a revoke/reset (see _onRevoked): the snapshot encryption key
  /// and the database key are regenerated then, so nothing built before may
  /// be kept.
  AppServices? _services;

  bool? _isActivated; // null while starting
  String _appVersion = '1.0.0';
  String _osVersion = '';

  /// Non-null => the startup failed and the error screen is shown. Cleared
  /// when a retry begins.
  String? _startupError;
  String? _startupErrorDetail;

  /// Identifies the current startup attempt. Bumped when an attempt begins
  /// and when one is abandoned (timeout), so anything a stuck or superseded
  /// attempt produces later is recognised as stale and discarded.
  int _startupGeneration = 0;

  @override
  void initState() {
    super.initState();
    _secureStorage = SecureStorageService();
    _api = ApiClient(_secureStorage);
    unawaited(_startup());
    _deepLinkService.listen((token) {
      // A link can arrive before startup finishes (cold start) or any time
      // later while already activated (harmless — ActivationScreen isn't
      // shown in that case, the token is just ignored downstream).
      setState(() => _pendingDeepLinkToken = token);
    });
  }

  @override
  void dispose() {
    _startupGeneration++;
    _deepLinkService.dispose();
    super.dispose();
  }

  /// Runs the startup sequence once. Every outcome ends in a state the user
  /// can act on: the app, or an error screen with a retry. Nothing here may
  /// end by returning silently with the spinner still showing.
  Future<void> _startup() async {
    final generation = ++_startupGeneration;
    if (_startupError != null) {
      setState(() {
        _startupError = null;
        _startupErrorDetail = null;
      });
    }

    final run = _bootstrap();
    try {
      final data = await run.timeout(widget.startupTimeout);
      if (!mounted || generation != _startupGeneration) {
        // Superseded while it was running: its database must not stay open.
        await data.services.dispose();
        return;
      }
      setState(() {
        _appVersion = data.appVersion;
        _osVersion = data.osVersion;
        _isActivated = data.activated;
        _services = data.services;
      });
      StartupTrace.mark('app_ready');
      if (data.activated) unawaited(_prewarmParishClient());
    } on TimeoutException {
      if (!mounted || generation != _startupGeneration) return;
      // Abandon this attempt: bump the generation so that if it ever does
      // finish, its result is discarded (and its database closed below).
      _startupGeneration++;
      unawaited(
        run.then((lateData) => lateData.services.dispose()).catchError((_) {}),
      );
      setState(() {
        _startupError = 'Uruchamianie aplikacji trwa zbyt długo.';
        _startupErrorDetail = null;
      });
    } catch (e) {
      if (!mounted || generation != _startupGeneration) return;
      setState(() {
        _startupError = 'Nie udało się uruchomić aplikacji.';
        // The type only — an exception's message can carry paths or URLs.
        _startupErrorDetail = e.runtimeType.toString();
      });
    }
  }

  Future<_StartupData> _bootstrap() async {
    // Real "iOS 17.5" / "Android 14" strings — NOT Platform.operatingSystem,
    // which only ever returns the bare "ios"/"android" and would silently
    // clobber the good value the activation flow already sent once the
    // first heartbeat fires. Neither lookup is worth failing startup over:
    // each falls back to the previous value.
    //
    // The two lookups start now and run WHILE the activation state is read
    // and the services are built (they were three sequential platform
    // round-trips ahead of anything else). Neither can throw.
    final versionLookup = _lookup(
      () async => (await PackageInfo.fromPlatform()).version,
      _appVersion,
    );
    final osLookup = _lookup(_resolveOsVersion, _osVersion);

    // These two are not optional: without the activation state and the
    // database there is no app to show. Sequential on purpose: a storage
    // that cannot be read must stop here, before a database is opened.
    final activated = await _secureStorage.isActivated;
    StartupTrace.mark('activation_read');
    final services = await widget.buildServices(_secureStorage, _api);
    StartupTrace.mark('services_built');

    return _StartupData(
      appVersion: await versionLookup,
      osVersion: await osLookup,
      activated: activated,
      services: services,
    );
  }

  /// [lookup]'s result, or [fallback] if it throws. For values the app can
  /// carry on without; never for anything that gates access.
  Future<T> _lookup<T>(Future<T> Function() lookup, T fallback) async {
    try {
      return await lookup();
    } catch (_) {
      return fallback;
    }
  }

  /// Builds the parish API client (three keystore reads and an HTTP client)
  /// ahead of time. Without this the first handoff paid for those reads
  /// INSIDE its 1.4 s network limit, so on a cold start a slow keystore
  /// could make the request "time out" before it was even sent: a false
  /// OFFLINE with a working network. Any failure (no user signed in yet)
  /// is expected and ignored; the client is rebuilt on demand, and every
  /// change of token already discards it (resetParishClient).
  Future<void> _prewarmParishClient() async {
    try {
      await _api.parish();
      StartupTrace.mark('parish_client_ready');
    } catch (_) {}
  }

  Future<String> _resolveOsVersion() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      return 'Android ${info.version.release}';
    } else if (Platform.isIOS) {
      final info = await deviceInfo.iosInfo;
      return 'iOS ${info.systemVersion}';
    }
    return Platform.operatingSystem;
  }

  void _onActivated() => setState(() => _isActivated = true);

  /// Called by HomeScreen AFTER RevocationHandler.handle() already closed
  /// the old AppDatabase and deleted its file + encryption key (review
  /// round 2, point 2). Dropping the services immediately keeps the old,
  /// now-closed ones from being used while a fresh database (and fresh
  /// key) is opened underneath; the full startup runs again, so a failure
  /// of the rebuild ends in the same retryable error screen as at cold
  /// start rather than a spinner nobody can get out of.
  void _onRevoked() {
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    _services?.offlinePageCoordinator.localServer.stop();
    setState(() {
      _isActivated = false;
      _services = null;
    });
    unawaited(_startup());
  }

  @override
  Widget build(BuildContext context) {
    final services = _services;

    final Widget home;
    if (_startupError != null) {
      home = StartupErrorScreen(
        message: _startupError!,
        detail: _startupErrorDetail,
        onRetry: () => unawaited(_startup()),
      );
    } else if (_isActivated == null || services == null) {
      home = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else {
      // Review round 2, point 5: global client-config (maintenance mode /
      // forced update) is checked HERE, in front of BOTH HomeScreen and
      // ActivationScreen — not only after activation. See PreflightGate's
      // own docblock for the exact ordering.
      home = PreflightGate(
        configService: services.configService,
        appVersion: _appVersion,
        child: _isActivated!
            ? HomeScreen(
                db: services.db,
                syncEngine: services.syncEngine,
                configService: services.configService,
                revocationHandler: services.revocationHandler,
                userSessionService: services.userSessionService,
                offlinePageCoordinator: services.offlinePageCoordinator,
                onRevoked: _onRevoked,
                appVersion: _appVersion,
                osVersion: _osVersion,
              )
            : ActivationScreen(
                key: ValueKey(_pendingDeepLinkToken),
                activationService: services.activationService,
                onActivated: _onActivated,
                initialToken: _pendingDeepLinkToken,
              ),
      );
    }

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Ministrant Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          useMaterial3: true, colorSchemeSeed: const Color(0xFF1C2B4A)),
      home: home,
    );
  }
}
