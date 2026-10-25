import 'dart:async';

import 'support/isolated_secure_storage.dart';
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
import 'package:ministrant_manager/core/security/wipe_lock.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart';
import 'package:ministrant_manager/features/auth/user_session_service.dart';
import 'package:ministrant_manager/features/config/config_service.dart';
import 'package:ministrant_manager/features/home/home_screen.dart';
import 'package:ministrant_manager/features/revocation/revocation_handler.dart';
import 'package:ministrant_manager/features/revocation/wipe_marker.dart';
import 'package:ministrant_manager/features/webview/webview_handoff_service.dart';

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

class _FlakyStorage extends IsolatedSecureStorage {
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


class _AcceptingHandoff extends WebviewHandoffService {
  _AcceptingHandoff(SecureStorageService storage) : super(api: ApiClient(storage), secureStorage: storage);

  @override
  Future<Uri> requestHandoffUrl(String path, {Duration timeout = WebviewHandoffService.defaultTimeout}) async =>
      Uri.parse('https://parish.example/mobile_handoff.php?t=x');
}

/// A MANUAL reset ("Zmień parafię") that does not complete: from the moment it starts until it has
/// succeeded, nothing of the device's data can be reached, whatever the user does next: the button,
/// the system Back, the coordinator that hands out saved copies. Retrying continues the SAME wipe.
/// (Written without being able to run Flutter here: not executed.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late AppDatabase db;
  late _FlakyStorage storage;
  late Map<String, String> keystore;
  late _Memory markerA;
  late _Memory markerB;
  late WipeLock lock;
  late OfflinePageCoordinator coordinator;
  late RevocationHandler handler;
  late Widget home;
  var revokedCalls = 0;
  var dbFilesRemain = true;

  setUp(() async {
    revokedCalls = 0;
    dbFilesRemain = true;
    keystore = {'device_token': 'device-token-A', 'mobile_user_token': 'token', 'current_user_id': '7'};
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
    final api = _FakeApi(
      storage,
      _Adapter((o) => Future.value(_json(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}))),
    );
    final snapshotStore = _NoIoStore();
    final engine = SyncEngine(db: db, api: api, secureStorage: storage);
    lock = WipeLock();
    coordinator = OfflinePageCoordinator(
      connectivityProbe: ConnectivityProbe(),
      captureService: SnapshotCaptureService(downloader: PageResourceDownloader(), store: snapshotStore),
      snapshotStore: snapshotStore,
      localServer: LocalSnapshotServer(encryptor: SnapshotEncryptor(hexKey: 'c' * 64)),
      handoffService: _AcceptingHandoff(storage),
      reverifyDevice: engine.reverifyDevice,
      wipeLock: lock,
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
      wipeLock: lock,
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

  Future<void> openSettingsAndConfirmReset(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Urządzenie / Parafia'));
    await settle(tester);
    await tester.tap(find.text('Zmień parafię'));
    await settle(tester);
    await tester.tap(find.text('ZMIEŃ PARAFIĘ'));
    await settle(tester);
  }

  void makeWipeFail() {
    markerA.failWrite = true;
    markerB.failWrite = true;
    storage.failClear = true;
  }

  const blockingText = 'Nie udało się dokończyć usuwania danych tego urządzenia';

  testWidgets('an incomplete manual reset: the screen goes back to a BLOCKED home, the lock stays held', (tester) async {
    makeWipeFail();
    await tester.pumpWidget(home);
    await settle(tester);
    await openSettingsAndConfirmReset(tester);

    expect(revokedCalls, 0, reason: 'not rebuilt as though the device were clean');
    expect(lock.isHeld, isTrue);
    expect(handler.hasIncompleteWipe, isTrue);
    expect(find.text('Urządzenie / Parafia'), findsNothing, reason: 'the settings screen is gone');
    expect(find.textContaining(blockingText), findsOneWidget, reason: 'HomeScreen shows the block, though it never saw the exception');
    expect(find.text('SPRÓBUJ PONOWNIE'), findsOneWidget);
  });

  testWidgets('the system Back (and a second Back) cannot reveal what was there before', (tester) async {
    makeWipeFail();
    await tester.pumpWidget(home);
    await settle(tester);
    await openSettingsAndConfirmReset(tester);

    for (var i = 0; i < 2; i++) {
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.textContaining(blockingText), findsOneWidget, reason: 'Back number ${i + 1}');
      expect(find.byTooltip('Urządzenie / Parafia'), findsNothing, reason: 'no way back into the app bar of the old screen');
    }
    expect(revokedCalls, 0);
  });

  testWidgets('the coordinator hands out nothing while the lock is held; the local server is shut', (tester) async {
    makeWipeFail();
    await tester.pumpWidget(home);
    await settle(tester);
    await openSettingsAndConfirmReset(tester);

    final plan = await coordinator.plan(parishId: 'p', userId: '7', targetPath: '/public/dashboard.php');
    expect(plan, isA<PageLoadServerError>());
    expect((plan as PageLoadServerError).errorCode, 'wipe_in_progress');
    expect(await coordinator.hasSavedCopy(parishId: 'p', userId: '7', pagePath: '/public/dashboard.php'), isFalse);
    expect(await coordinator.savedCopyFact(parishId: 'p', userId: '7', pagePath: '/public/dashboard.php'), SavedCopyFact.unknown);
    expect(coordinator.localServer.rootDirectory, isNull);
  });

  testWidgets('retry continues the SAME wipe: while it fails nothing opens, once it succeeds the flow goes on', (tester) async {
    makeWipeFail();
    await tester.pumpWidget(home);
    await settle(tester);
    await openSettingsAndConfirmReset(tester);

    // Retry that still fails.
    await tester.tap(find.text('SPRÓBUJ PONOWNIE'));
    await settle(tester);
    expect(revokedCalls, 0);
    expect(lock.isHeld, isTrue);
    expect(find.textContaining(blockingText), findsOneWidget);

    // The keystore works again; the retry finishes the wipe that is pending (it does not start a new one).
    storage.failClear = false;
    markerA.failWrite = false;
    markerB.failWrite = false;
    final outcomeBefore = handler.lastOutcome;
    await tester.tap(find.text('SPRÓBUJ PONOWNIE'));
    await settle(tester);
    expect(handler.lastOutcome, isNot(same(outcomeBefore)));
    expect(handler.lastOutcome!.complete, isTrue);
    expect(lock.isHeld, isFalse, reason: 'released only now');
    expect(handler.hasIncompleteWipe, isFalse);
    expect(revokedCalls, 1, reason: 'only a SUCCESS lets the app go on');
    expect(keystore.containsKey('device_token'), isFalse);
    expect(dbFilesRemain, isFalse);
  });

  testWidgets('while the manual reset is running the lock is already held; the system Back does not leave the settings', (tester) async {
    final gate = Completer<void>();
    // The database deletion waits, so the wipe is "in progress".
    handler = RevocationHandler(
      db: null,
      secureStorage: storage,
      snapshotStore: _NoIoStore(),
      clearWebViewCookies: () async {},
      markerStore: markerA,
      fallbackMarkerStore: markerB,
      deleteDatabaseFiles: () async {
        await gate.future;
        dbFilesRemain = false;
      },
      databaseFilesRemain: () async => dbFilesRemain,
      wipeLock: lock,
    );
    final engine = SyncEngine(db: db, api: _FakeApi(storage, _Adapter((o) => Future.value(_json(200, {'status': 'ACTIVE'})))), secureStorage: storage);
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        db: db,
        syncEngine: engine,
        configService: _NoConfig(db: db, api: _FakeApi(storage, _Adapter((o) => Future.value(_json(200, {}))))),
        revocationHandler: handler,
        userSessionService: UserSessionService(
          api: _FakeApi(storage, _Adapter((o) => Future.value(_json(200, {})))),
          secureStorage: storage,
          db: db,
          snapshotStore: _NoIoStore(),
        ),
        offlinePageCoordinator: coordinator,
        onRevoked: () => revokedCalls++,
        appVersion: '1.0.0',
        osVersion: 'test',
      ),
    ));
    await settle(tester);
    await openSettingsAndConfirmReset(tester);
    expect(lock.isHeld, isTrue, reason: 'held from the START of the wipe');
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(revokedCalls, 0);
    gate.complete();
    await settle(tester);
    expect(lock.isHeld, isFalse);
    expect(revokedCalls, 1);
  });
}
