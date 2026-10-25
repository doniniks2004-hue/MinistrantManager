import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/offline/connectivity_probe.dart';
import 'package:ministrant_manager/core/offline/local_snapshot_server.dart';
import 'package:ministrant_manager/core/offline/offline_page_coordinator.dart';
import 'package:ministrant_manager/core/offline/page_resource_downloader.dart';
import 'package:ministrant_manager/core/offline/snapshot_capture_service.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_manifest.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/security/access_refusals.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart';
import 'package:ministrant_manager/features/auth/user_session_service.dart';
import 'package:ministrant_manager/features/config/config_service.dart';
import 'package:ministrant_manager/features/home/home_screen.dart';
import 'package:ministrant_manager/features/revocation/revocation_handler.dart';
import 'package:ministrant_manager/features/revocation/wipe_marker.dart';
import 'package:ministrant_manager/features/webview/webview_handoff_service.dart';

/// The WHOLE path of a parish refusal that is checked against the central server:
///
///   parish handoff says "device revoked"  ->  OfflinePageCoordinator asks the central server again
///   (the REAL SyncEngine, with a fake HTTP adapter)  ->  the central answer decides:
///     DEVICE_REVOKED / PARISH_DISABLED -> HomeScreen -> RevocationHandler erases (the existing handling)
///     ACTIVE                           -> the parish answer was old: nothing blocked, nothing erased
///     anything else / no answer        -> the parish refusal blocks, nothing is erased
///
/// Nothing here is a stand-in for the engine: the answers come from the HTTP layer. (Written without
/// being able to run Flutter here: not executed.)

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );

class _FakeApi extends ApiClient {
  _FakeApi(SecureStorageService storage, this.centralAdapter) : super(storage);
  final _Adapter centralAdapter;

  @override
  Dio centralWithAuth(String deviceToken) => Dio(BaseOptions(baseUrl: ApiClient.centralBaseUrl))..httpClientAdapter = centralAdapter;
}

class _FlakyStorage extends SecureStorageService {
  bool failClear = false;

  @override
  Future<void> clearActivation() async {
    if (failClear) throw StateError('keystore unavailable');
    await super.clearActivation();
  }
}

/// No file system: the manifest read and the deletions are instant.
class _NoIoStore extends SnapshotStore {
  _NoIoStore() : super(encryptor: SnapshotEncryptor(hexKey: 'c' * 64));

  @override
  Future<SnapshotManifest?> readManifestFor({
    required String parishId,
    required String userId,
    required String pagePath,
  }) async => null;

  @override
  Future<void> clearForParish({required String parishId}) async {}

  @override
  Future<void> clearAll() async {}
}

class _ParishSaysRevoked extends WebviewHandoffService {
  _ParishSaysRevoked(SecureStorageService storage) : super(api: ApiClient(storage), secureStorage: storage);

  @override
  Future<Uri> requestHandoffUrl(String path, {Duration timeout = WebviewHandoffService.defaultTimeout}) async {
    final request = RequestOptions(path: '/mobile/webview/handoff');
    throw DioException(
      requestOptions: request,
      type: DioExceptionType.badResponse,
      response: Response<Object?>(
        requestOptions: request,
        statusCode: 403,
        data: {'error': 'device_not_authorized', 'device_state': 'revoked'},
      ),
    );
  }
}

class _Memory implements WipeMarkerStore {
  String? value;
  bool failWrite = false;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async {
    if (failWrite) throw StateError('unwritable');
    value = v;
  }

  @override
  Future<void> delete() async => value = null;
}

class _NoConfig extends ConfigService {
  _NoConfig({required super.db, required super.api});

  @override
  Future<Map<String, dynamic>?> loadClientConfig() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late AppDatabase db;
  late _FlakyStorage storage;
  late Map<String, String> keystore;
  late List<Future<ResponseBody> Function(RequestOptions)> central;
  late _Memory markerA;
  late _Memory markerB;
  late OfflinePageCoordinator coordinator;
  late RevocationHandler handler;
  late Widget home;
  var revokedCalls = 0;
  var dbFilesRemain = true;

  Future<ResponseBody> answer(int status, Object body) => Future.value(_json(status, body));
  Future<ResponseBody> noConnection(RequestOptions o) =>
      Future.error(DioException(requestOptions: o, type: DioExceptionType.connectionError));

  setUp(() async {
    revokedCalls = 0;
    dbFilesRemain = true;
    keystore = {
      'device_token': 'device-token-A',
      'mobile_user_token': 'token',
      'current_user_id': '7',
      // no parish_id: HomeScreen ends on its "missing data" screen and never loads a page
    };
    central = [];
    markerA = _Memory();
    markerB = _Memory();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return keystore[key];
        case 'write':
          keystore[key!] = args['value'] as String;
          return null;
        case 'delete':
          keystore.remove(key);
          return null;
        default:
          return null;
      }
    });
    db = AppDatabase.forTesting();
    // Open SQLite outside the widget fake-async zone; teardown must not wait on
    // an unfinished lazy-open operation after a failed widget assertion.
    await db.ensureSyncMetadata();
    storage = _FlakyStorage();
    final api = _FakeApi(storage, _Adapter((o) => central.removeAt(0).call(o)));
    final snapshotStore = _NoIoStore();
    final engine = SyncEngine(db: db, api: api, secureStorage: storage); // the REAL engine
    coordinator = OfflinePageCoordinator(
      connectivityProbe: ConnectivityProbe(),
      captureService: SnapshotCaptureService(downloader: PageResourceDownloader(), store: snapshotStore),
      snapshotStore: snapshotStore,
      localServer: LocalSnapshotServer(encryptor: SnapshotEncryptor(hexKey: 'c' * 64)),
      handoffService: _ParishSaysRevoked(storage),
      reverifyDevice: engine.reverifyDevice,
    );
    handler = RevocationHandler(
      db: null,
      secureStorage: storage,
      snapshotStore: snapshotStore,
      clearWebViewCookies: () async {},
      markerStore: markerA,
      fallbackMarkerStore: markerB,
      deleteDatabaseFiles: () async => dbFilesRemain = false,
      databaseFilesRemain: () async => dbFilesRemain,
    );
    home = MaterialApp(
      home: HomeScreen(
        db: db,
        syncEngine: engine,
        configService: _NoConfig(db: db, api: api),
        revocationHandler: handler,
        userSessionService: UserSessionService(api: api, secureStorage: storage, db: db, snapshotStore: snapshotStore),
        offlinePageCoordinator: coordinator,
        onRevoked: () => revokedCalls++,
        appVersion: '1.0.0',
        osVersion: 'test',
      ),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await db.close();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('central DEVICE_REVOKED on the re-check reaches the revocation handling: erased, rebuilt', (tester) async {
    central.add((o) => answer(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
    central.add((o) => answer(200, {'status': 'DEVICE_REVOKED'}));
    await tester.pumpWidget(home);
    await settle(tester);
    final plan = coordinator.plan(parishId: 'p', userId: '7', targetPath: '/public/dashboard.php');
    await settle(tester);

    expect((await plan as PageLoadServerError).refusal, HandoffRefusal.device, reason: 'this reply is still refused');
    expect(revokedCalls, 1, reason: 'the existing handling ran, and HomeScreen then rebuilt');
    expect(keystore.containsKey('device_token'), isFalse, reason: 'the activation was erased');
    expect(markerA.value, isNull);
    expect(markerB.value, isNull, reason: 'complete: the marker was removed');
    expect(dbFilesRemain, isFalse);
  });

  testWidgets('central PARISH_DISABLED likewise', (tester) async {
    central.add((o) => answer(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
    central.add((o) => answer(200, {'status': 'PARISH_DISABLED'}));
    await tester.pumpWidget(home);
    await settle(tester);
    final plan = coordinator.plan(parishId: 'p', userId: '7', targetPath: '/public/dashboard.php');
    await settle(tester);
    await plan;
    expect(revokedCalls, 1);
    expect(keystore.containsKey('device_token'), isFalse);
  });

  testWidgets('a refusal from the PARISH ALONE (the central server cannot be reached) blocks and erases nothing', (tester) async {
    central.add((o) => answer(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
    central.add((o) => noConnection(o)); // the central server cannot be reached for the re-check
    await tester.pumpWidget(home);
    await settle(tester);
    final plan = coordinator.plan(parishId: 'p', userId: '7', targetPath: '/public/dashboard.php');
    await settle(tester);

    expect((await plan as PageLoadServerError).refusal, HandoffRefusal.device);
    expect(revokedCalls, 0);
    expect(keystore['device_token'], 'device-token-A', reason: 'blocked, not erased');
    expect(keystore['refusal_device'], isNotNull, reason: 'remembered');
    expect(markerA.value, isNull, reason: 'no wipe was started');
  });

  testWidgets('a central 401 on the re-check is a refusal too, not an erasing', (tester) async {
    central.add((o) => answer(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
    central.add((o) => answer(401, {'error': 'Unknown device token'}));
    await tester.pumpWidget(home);
    await settle(tester);
    final plan = coordinator.plan(parishId: 'p', userId: '7', targetPath: '/public/dashboard.php');
    await settle(tester);

    expect((await plan as PageLoadServerError).refusal, HandoffRefusal.device);
    expect(revokedCalls, 0);
    expect(keystore['device_token'], 'device-token-A');
  });

  testWidgets('central ACTIVE on the re-check: the parish answer was old, nothing blocked or erased', (tester) async {
    central.add((o) => answer(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
    central.add((o) => answer(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
    await tester.pumpWidget(home);
    await settle(tester);
    final plan = coordinator.plan(parishId: 'p', userId: '7', targetPath: '/public/dashboard.php');
    await settle(tester);

    final e = await plan as PageLoadServerError;
    expect(e.staleParishAnswer, isTrue);
    expect(e.refusal, isNull);
    expect(revokedCalls, 0);
    expect(keystore['device_token'], 'device-token-A');
    expect(keystore.containsKey('refusal_device'), isFalse);
  });

  group('a revocation whose wipe is NOT complete does not go on', () {
    setUp(() {
      // Neither marker can be stored, and the activation cannot be removed: the worst case.
      markerA.failWrite = true;
      markerB.failWrite = true;
      storage.failClear = true;
    });

    testWidgets('HomeScreen shows a blocking state with a retry; it does not rebuild or offer activation', (tester) async {
      central.add((o) => answer(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
      central.add((o) => answer(200, {'status': 'DEVICE_REVOKED'}));
      await tester.pumpWidget(home);
      await settle(tester);
      final plan = coordinator.plan(parishId: 'p', userId: '7', targetPath: '/public/dashboard.php');
      await settle(tester);
      await plan;

      expect(revokedCalls, 0, reason: 'the services are NOT rebuilt as though the device were clean');
      expect(find.textContaining('Nie udało się dokończyć usuwania danych'), findsOneWidget);
      expect(find.text('SPRÓBUJ PONOWNIE'), findsOneWidget);
      expect(handler.lastOutcome!.markerStored, isFalse);
      expect(handler.lastOutcome!.activationCleared, isFalse);
      expect(handler.hasIncompleteWipe, isTrue);
    });

    testWidgets('the retry keeps blocking while it fails, and goes on once it works', (tester) async {
      central.add((o) => answer(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
      central.add((o) => answer(200, {'status': 'DEVICE_REVOKED'}));
      await tester.pumpWidget(home);
      await settle(tester);
      final plan = coordinator.plan(parishId: 'p', userId: '7', targetPath: '/public/dashboard.php');
      await settle(tester);
      await plan;

      await tester.tap(find.text('SPRÓBUJ PONOWNIE'));
      await settle(tester);
      expect(revokedCalls, 0);
      expect(find.textContaining('Nie udało się dokończyć usuwania danych'), findsOneWidget, reason: 'still failing: still blocked');

      storage.failClear = false;
      await tester.tap(find.text('SPRÓBUJ PONOWNIE'));
      await settle(tester);
      expect(revokedCalls, 1, reason: 'now complete: rebuilt');
      expect(keystore.containsKey('device_token'), isFalse);
    });
  });
}
