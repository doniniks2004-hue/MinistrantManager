import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/features/auth/user_session_service.dart';
import 'package:ministrant_manager/features/revocation/revocation_handler.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart' show DeviceAuthState;

/// Offline-architecture milestone, P7. Review round: "nie dokładamy
/// kolejnych funkcji, dopóki nie upewnimy się, że cache nie może
/// przeciec między użytkownikami/parafiami." P3 already proved
/// SnapshotStore's own clearForUser/clearForParish work correctly in
/// isolation (snapshot_store_test.dart) — these tests prove the
/// DIFFERENT, equally real question: are those methods actually CALLED
/// by the real logout/login/revocation code paths. Before this
/// milestone, grepping the whole lib/ tree for clearForUser/clearForParish
/// found zero call sites outside SnapshotStore's own definition — the
/// methods existed but nothing ever invoked them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final fakeStore = <String, String>{};

  setUp(() {
    fakeStore.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      secureStorageChannel,
      (call) async {
        final args = call.arguments as Map?;
        final key = args?['key'] as String?;
        switch (call.method) {
          case 'read':
            return key != null ? fakeStore[key] : null;
          case 'write':
            final value = args?['value'] as String?;
            if (key != null) {
              if (value == null) {
                fakeStore.remove(key);
              } else {
                fakeStore[key] = value;
              }
            }
            return null;
          case 'delete':
            if (key != null) fakeStore.remove(key);
            return null;
          case 'readAll':
            return Map<String, String>.from(fakeStore);
          case 'deleteAll':
            fakeStore.clear();
            return null;
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(secureStorageChannel, null);
  });

  late Directory tempRoot;
  late SnapshotStore snapshotStore;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('offline_isolation_test_');
    snapshotStore = SnapshotStore(rootOverride: tempRoot);
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('UserSessionService wires SnapshotStore.clearForUser into logout()', () {
    test('logout removes the signed-in user\'s own snapshot', () async {
      fakeStore['parish_id'] = 'witosa';
      fakeStore['current_user_id'] = '9001';
      fakeStore['mobile_user_token'] = 'some-token';

      await snapshotStore.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html>Ministrant 9001 dashboard</html>',
        assets: {},
      );

      final secureStorage = SecureStorageService();
      final service = UserSessionService(
        api: ApiClient(secureStorage),
        secureStorage: secureStorage,
        db: AppDatabase.forTesting(),
        snapshotStore: snapshotStore,
      );

      await service.logout();

      final dir = await snapshotStore.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php');
      expect(dir, isNull, reason: 'logout must remove the user\'s own offline snapshot, not just the SQLite cache');
    });

    test('logout never touches a DIFFERENT user\'s snapshot in the same parish', () async {
      fakeStore['parish_id'] = 'witosa';
      fakeStore['current_user_id'] = '9001';

      await snapshotStore.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html>9001</html>',
        assets: {},
      );
      await snapshotStore.writeSnapshot(
        parishId: 'witosa',
        userId: '9002',
        pagePath: '/public/dashboard.php',
        html: '<html>9002</html>',
        assets: {},
      );

      final secureStorage = SecureStorageService();
      final service = UserSessionService(
        api: ApiClient(secureStorage),
        secureStorage: secureStorage,
        db: AppDatabase.forTesting(),
        snapshotStore: snapshotStore,
      );

      await service.logout();

      final otherUserDir = await snapshotStore.getPageDirectoryIfReady(parishId: 'witosa', userId: '9002', pagePath: '/public/dashboard.php');
      expect(otherUserDir, isNotNull, reason: '9001 logging out must never remove 9002\'s own snapshot');
    });
  });

  group('UserSessionService wires SnapshotStore.clearForUser into the user-switch path', () {
    test('a different user signing in removes the PREVIOUS user\'s snapshot before returning', () async {
      // Exercises the REAL UserSessionService.login() — not a test
      // double — by pointing server_url at a real local HTTP server
      // this test controls, since login() constructs its own internal
      // Dio against exactly "$server_url/api/v1/mobile/session/login"
      // and there is no way to inject a fake Dio into that real method
      // from outside.
      final fakeParishServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      fakeParishServer.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"must_change_password": false, "token": "new-token", "user": {"id": 9002, "full_name": "Ministrant B", "role_id": 5}}',
        );
        await request.response.close();
      });

      fakeStore['parish_id'] = 'witosa';
      fakeStore['installation_id'] = '550e8400-e29b-41d4-a716-446655440000';
      fakeStore['server_url'] = 'http://127.0.0.1:${fakeParishServer.port}';
      fakeStore['current_user_id'] = '9001'; // Admin A, already signed in on this device

      await snapshotStore.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html>Admin A dashboard</html>',
        assets: {},
      );

      final secureStorage = SecureStorageService();
      final service = UserSessionService(
        api: ApiClient(secureStorage),
        secureStorage: secureStorage,
        db: AppDatabase.forTesting(),
        snapshotStore: snapshotStore,
      );

      final result = await service.login(username: 'ministrant_b', password: 'whatever');
      expect(result, isA<UserLoginSuccess>());

      final adminADir = await snapshotStore.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php');
      expect(
        adminADir,
        isNull,
        reason: 'Ministrant B signing in must remove Admin A\'s offline snapshot — review round: "Ministrant B nie może zobaczyć snapshotu Admina"',
      );

      await fakeParishServer.close(force: true);
    });
  });

  group('RevocationHandler wires SnapshotStore.clearForParish', () {
    test('revocation removes EVERY user\'s snapshot for the revoked parish', () async {
      fakeStore['parish_id'] = 'witosa';

      await snapshotStore.writeSnapshot(
        parishId: 'witosa',
        userId: 'admin-1',
        pagePath: '/public/dashboard.php',
        html: '<html>Witosa admin</html>',
        assets: {},
      );
      await snapshotStore.writeSnapshot(
        parishId: 'witosa',
        userId: 'ministrant-5',
        pagePath: '/public/dashboard.php',
        html: '<html>Witosa ministrant</html>',
        assets: {},
      );

      final secureStorage = SecureStorageService();
      final handler = RevocationHandler(db: AppDatabase.forTesting(), secureStorage: secureStorage, snapshotStore: snapshotStore);

      await handler.handle(DeviceAuthState.revoked);

      expect(
        await snapshotStore.getPageDirectoryIfReady(parishId: 'witosa', userId: 'admin-1', pagePath: '/public/dashboard.php'),
        isNull,
      );
      expect(
        await snapshotStore.getPageDirectoryIfReady(parishId: 'witosa', userId: 'ministrant-5', pagePath: '/public/dashboard.php'),
        isNull,
        reason: 'revocation must clear EVERY user under that parish, not just one',
      );
    });

    test(
      'the capstone isolation proof: Szarlej -> Panewniki — revoking/clearing Szarlej leaves zero trace, Panewniki untouched',
      () async {
        fakeStore['parish_id'] = 'szarlej';

        await snapshotStore.writeSnapshot(
          parishId: 'szarlej',
          userId: '9001',
          pagePath: '/public/dashboard.php',
          html: '<html>Szarlej dashboard — should NEVER survive</html>',
          assets: {'img/szarlej-logo.png': [1, 2, 3]},
        );
        await snapshotStore.writeSnapshot(
          parishId: 'parafia-stare-panewniki',
          userId: '9001',
          pagePath: '/public/dashboard.php',
          html: '<html>Stare Panewniki dashboard</html>',
          assets: {},
        );

        final secureStorage = SecureStorageService();
        final handler = RevocationHandler(db: AppDatabase.forTesting(), secureStorage: secureStorage, snapshotStore: snapshotStore);

        await handler.handle(DeviceAuthState.parishDisabled);

        expect(
          await snapshotStore.getPageDirectoryIfReady(parishId: 'szarlej', userId: '9001', pagePath: '/public/dashboard.php'),
          isNull,
          reason: 'Szarlej snapshot, including its own logo asset, must be completely gone',
        );
        expect(
          await snapshotStore.getPageDirectoryIfReady(parishId: 'parafia-stare-panewniki', userId: '9001', pagePath: '/public/dashboard.php'),
          isNotNull,
          reason: 'Stare Panewniki must be COMPLETELY untouched by Szarlej being disabled — zero bleed between parishes',
        );
      },
    );

    test('a non-revocation state (e.g. active) never touches any snapshot', () async {
      fakeStore['parish_id'] = 'witosa';
      await snapshotStore.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html>still here</html>',
        assets: {},
      );

      final secureStorage = SecureStorageService();
      final handler = RevocationHandler(db: AppDatabase.forTesting(), secureStorage: secureStorage, snapshotStore: snapshotStore);

      await handler.handle(DeviceAuthState.active);

      expect(
        await snapshotStore.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php'),
        isNotNull,
      );
    });
  });
}
