import 'dart:async';

import '../database/app_database.dart';
import '../network/api_client.dart';
import '../offline/connectivity_probe.dart';
import '../offline/local_snapshot_server.dart';
import '../offline/offline_page_coordinator.dart';
import '../offline/page_resource_downloader.dart';
import '../offline/snapshot_capture_service.dart';
import '../offline/snapshot_encryptor.dart';
import '../offline/snapshot_store.dart';
import '../secure/secure_storage_service.dart';
import '../sync/sync_engine.dart';
import '../../features/activation/activation_service.dart';
import '../../features/auth/user_session_service.dart';
import '../../features/config/config_service.dart';
import '../../features/revocation/revocation_handler.dart';
import '../../features/webview/webview_handoff_service.dart';

/// Everything that depends on the encrypted database and the snapshot
/// encryption key. Built as ONE unit: after a revoke-triggered crypto-erase
/// the whole set must be rebuilt together (the old database is closed, its
/// file and both keys are gone), and a half-built set must never be used.
class AppServices {
  const AppServices({
    required this.db,
    required this.syncEngine,
    required this.activationService,
    required this.revocationHandler,
    required this.configService,
    required this.userSessionService,
    required this.offlinePageCoordinator,
  });

  final AppDatabase db;
  final SyncEngine syncEngine;
  final ActivationService activationService;
  final RevocationHandler revocationHandler;
  final ConfigService configService;
  final UserSessionService userSessionService;
  final OfflinePageCoordinator offlinePageCoordinator;

  /// Releases what holds a resource, for a set that was built but is never
  /// going to be used (an abandoned startup attempt). Never throws.
  Future<void> dispose() async {
    try {
      await offlinePageCoordinator.localServer.stop();
    } catch (_) {}
    try {
      await db.close();
    } catch (_) {}
  }
}

typedef AppServicesBuilder = Future<AppServices> Function(
  SecureStorageService secureStorage,
  ApiClient api,
);

/// Builds a brand-new AppDatabase (with its encryption key — freshly
/// generated if none exists, e.g. right after a crypto-erase — see
/// SecureStorageService.getOrCreateDbEncryptionKey()) and every service
/// that depends on it. Called at cold start, and AGAIN after a
/// revoke-triggered crypto-erase (review round 2, point 2): the OLD
/// AppDatabase instance is closed and its file is gone at that point, so
/// nothing that follows may keep using it.
///
/// If anything after the database is opened throws, the database is closed
/// again before the error propagates — otherwise a retry would open a
/// second instance on the same file while the failed attempt's one is
/// still alive.
Future<AppServices> buildAppServices(
  SecureStorageService secureStorage,
  ApiClient api,
) async {
  final dbKey = await secureStorage.getOrCreateDbEncryptionKey();
  final db = AppDatabase(dbKey);
  try {
    // The database is opened lazily, on the first query, and opening it
    // (a background isolate plus key derivation) is the slowest step before
    // the first screen can decide anything. Start it NOW so it runs while
    // the rest of the services are built and the home screen reads its
    // state, instead of beginning only when that first query is made. A
    // failure is deliberately not raised here: the same open is awaited by
    // the first real query, which reports it where it can be handled.
    unawaited(db.ensureSyncMetadata().then<void>((_) {}, onError: (_) {}));
    // Offline-architecture milestone, P8.2: resolved fresh on every call,
    // exactly like dbKey above — after a revoke-triggered crypto-erase,
    // RevocationHandler has already deleted the OLD snapshot encryption
    // key, so building this once and reusing it forever would keep using
    // a stale encryptor referencing a key that no longer exists.
    final snapshotKey = await secureStorage.getOrCreateSnapshotEncryptionKey();
    // One shared instance — SnapshotEncryptor is a stateless wrapper around
    // this one key, so SnapshotStore and LocalSnapshotServer can safely use
    // the exact same instance.
    final snapshotEncryptor = SnapshotEncryptor(hexKey: snapshotKey);
    final snapshotStore = SnapshotStore(encryptor: snapshotEncryptor);
    final syncEngine =
        SyncEngine(db: db, api: api, secureStorage: secureStorage);
    final activationService =
        ActivationService(api: api, secureStorage: secureStorage);
    final revocationHandler = RevocationHandler(
        db: db, secureStorage: secureStorage, snapshotStore: snapshotStore);
    final configService = ConfigService(db: db, api: api);
    final userSessionService = UserSessionService(
        api: api,
        secureStorage: secureStorage,
        db: db,
        snapshotStore: snapshotStore);

    // The online<->offline WebView chain. Rebuilt fresh on every call for
    // the same reason as snapshotStore above: the snapshot encryption key
    // can be deleted/regenerated by RevocationHandler.
    final handoffService =
        WebviewHandoffService(api: api, secureStorage: secureStorage);
    final offlinePageCoordinator = OfflinePageCoordinator(
      connectivityProbe: ConnectivityProbe(),
      captureService: SnapshotCaptureService(
          downloader: PageResourceDownloader(), store: snapshotStore),
      snapshotStore: snapshotStore,
      localServer: LocalSnapshotServer(encryptor: snapshotEncryptor),
      handoffService: handoffService,
    );

    return AppServices(
      db: db,
      syncEngine: syncEngine,
      activationService: activationService,
      revocationHandler: revocationHandler,
      configService: configService,
      userSessionService: userSessionService,
      offlinePageCoordinator: offlinePageCoordinator,
    );
  } catch (_) {
    try {
      await db.close();
    } catch (_) {}
    rethrow;
  }
}
