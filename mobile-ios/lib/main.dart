import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io' show Platform;

import 'core/database/app_database.dart';
import 'core/deeplink/deep_link_service.dart';
import 'core/network/api_client.dart';
import 'core/secure/secure_storage_service.dart';
import 'core/sync/sync_engine.dart';
import 'features/activation/activation_screen.dart';
import 'features/activation/activation_service.dart';
import 'features/auth/user_session_service.dart';
import 'features/config/config_service.dart';
import 'features/home/home_screen.dart';
import 'features/preflight/preflight_gate.dart';
import 'features/revocation/revocation_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MinistrantManagerApp());
}

class MinistrantManagerApp extends StatefulWidget {
  const MinistrantManagerApp({super.key});

  @override
  State<MinistrantManagerApp> createState() => _MinistrantManagerAppState();
}

class _MinistrantManagerAppState extends State<MinistrantManagerApp> {
  AppDatabase? _db;
  late final SecureStorageService _secureStorage;
  late final ApiClient _api;
  SyncEngine? _syncEngine;
  ActivationService? _activationService;
  RevocationHandler? _revocationHandler;
  ConfigService? _configService;
  UserSessionService? _userSessionService;
  final _deepLinkService = DeepLinkService();
  String? _pendingDeepLinkToken;

  bool? _isActivated; // null while checking
  String _appVersion = '1.0.0';
  String _osVersion = '';

  @override
  void initState() {
    super.initState();
    _secureStorage = SecureStorageService();
    _api = ApiClient(_secureStorage);
    _init();
    _deepLinkService.listen((token) {
      // A link can arrive before _init() finishes (cold start) or any
      // time later while already activated (harmless — ActivationScreen
      // isn't shown in that case, the token is just ignored downstream).
      setState(() => _pendingDeepLinkToken = token);
    });
  }

  @override
  void dispose() {
    _deepLinkService.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    // Real "iOS 17.5" / "Android 14" strings — NOT Platform.operatingSystem,
    // which only ever returns the bare "ios"/"android" and would silently
    // clobber the good value the activation flow already sent once the
    // first heartbeat fires.
    final pkgInfo = await PackageInfo.fromPlatform();
    final osVersion = await _resolveOsVersion();
    final activated = await _secureStorage.isActivated;

    await _openFreshDatabaseAndWireServices();

    setState(() {
      _appVersion = pkgInfo.version;
      _osVersion = osVersion;
      _isActivated = activated;
    });
  }

  /// Builds a brand-new AppDatabase (with its encryption key — freshly
  /// generated if none exists, e.g. right after a crypto-erase — see
  /// SecureStorageService.getOrCreateDbEncryptionKey()) and every service
  /// that depends on it. Called once at cold start, and AGAIN after a
  /// revoke-triggered crypto-erase (review round 2, point 2) — the OLD
  /// AppDatabase instance is closed and its file is gone at that point,
  /// so nothing that follows may keep using it.
  Future<void> _openFreshDatabaseAndWireServices() async {
    final dbKey = await _secureStorage.getOrCreateDbEncryptionKey();
    final db = AppDatabase(dbKey);
    final syncEngine = SyncEngine(db: db, api: _api, secureStorage: _secureStorage);
    final activationService = ActivationService(api: _api, secureStorage: _secureStorage);
    final revocationHandler = RevocationHandler(db: db, secureStorage: _secureStorage);
    final configService = ConfigService(db: db, api: _api);
    final userSessionService = UserSessionService(api: _api, secureStorage: _secureStorage, db: db);

    setState(() {
      _db = db;
      _syncEngine = syncEngine;
      _activationService = activationService;
      _revocationHandler = revocationHandler;
      _configService = configService;
      _userSessionService = userSessionService;
    });
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
  /// round 2, point 2). Nulling the service fields out immediately means
  /// `build()`'s `ready` check goes false and shows the loading spinner
  /// rather than an ActivationScreen briefly wired to now-closed services,
  /// while a fresh database (and fresh key) is opened underneath.
  void _onRevoked() {
    setState(() {
      _isActivated = false;
      _db = null;
      _syncEngine = null;
      _activationService = null;
      _revocationHandler = null;
      _configService = null;
      _userSessionService = null;
    });
    _openFreshDatabaseAndWireServices();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _isActivated != null &&
        _db != null &&
        _syncEngine != null &&
        _activationService != null &&
        _revocationHandler != null &&
        _configService != null &&
        _userSessionService != null;

    return MaterialApp(
      title: 'Ministrant Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF1C2B4A)),
      home: !ready
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          // Review round 2, point 5: global client-config (maintenance
          // mode / forced update) is checked HERE, in front of BOTH
          // HomeScreen and ActivationScreen — not only after activation.
          // See PreflightGate's own docblock for the exact ordering.
          : PreflightGate(
              configService: _configService!,
              appVersion: _appVersion,
              child: _isActivated!
                  ? HomeScreen(
                      db: _db!,
                      syncEngine: _syncEngine!,
                      configService: _configService!,
                      revocationHandler: _revocationHandler!,
                      userSessionService: _userSessionService!,
                      onRevoked: _onRevoked,
                      appVersion: _appVersion,
                      osVersion: _osVersion,
                    )
                  : ActivationScreen(
                      key: ValueKey(_pendingDeepLinkToken),
                      activationService: _activationService!,
                      onActivated: _onActivated,
                      initialToken: _pendingDeepLinkToken,
                    ),
            ),
    );
  }
}
