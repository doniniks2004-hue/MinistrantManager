import 'dart:io';

import 'package:dio/dio.dart';
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

  // Per Dominik's exact diagnosis: RevocationHandler.handle() calls
  // AppDatabase.closeAndDeleteFiles(), which calls
  // path_provider's getApplicationDocumentsDirectory() to locate the
  // real SQLite file on disk (see app_database.dart's _databaseFile())
  // — a call no OTHER test in this project has ever exercised before
  // (nothing else in this codebase calls closeAndDeleteFiles()), so no
  // mock for this channel existed yet. Returns a real, existing temp
  // directory's path for ANY path_provider method — these tests only
  // care that closeAndDeleteFiles() can find SOME real directory to
  // look for (and not find, since AppDatabase.forTesting()'s in-memory
  // DB was never actually written there) a sqlite file in, not that the
  // path is meaningful.
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory fakeDocumentsDir;

  setUp(() async {
    fakeDocumentsDir = await Directory.systemTemp.createTemp('offline_isolation_test_docs_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => fakeDocumentsDir.path,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProviderChannel, null);
    if (await fakeDocumentsDir.exists()) {
      await fakeDocumentsDir.delete(recursive: true);
    }
  });

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
      // Per Dominik's exact diagnosis of the previous round's failure:
      // the real UserSessionService.login() constructs its OWN internal
      // Dio, and a hand-rolled dart:io HttpServer response (this
      // sandbox's only way to simulate a server, with no way to verify
      // Dio's exact response-handling behavior against it) produced a
      // 400/401 this test could not explain — "realna metoda login()
      // odrzuca testowe dane logowania". Switched to the SAME
      // injected-Dio test-double pattern ALREADY proven passing in real
      // CI for the equivalent tests in user_session_service_test.dart,
      // rather than keep guessing at dart:io HttpServer/Dio interaction
      // details this sandbox cannot verify. Mirrors login()'s CURRENT
      // real contract exactly (token + user{id, full_name, role_id} on
      // success) rather than the EARLIER must_change_password-in-body
      // shape this file's first draft wrongly assumed.
      fakeStore['parish_id'] = 'witosa';
      fakeStore['installation_id'] = '550e8400-e29b-41d4-a716-446655440000';
      fakeStore['server_url'] = 'https://parafia-witosa.ministrant.eu';
      fakeStore['current_user_id'] = '9001'; // Admin A, already signed in on this device

      await snapshotStore.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html>Admin A dashboard</html>',
        assets: {},
      );

      final secureStorage = SecureStorageService();
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'token': 'new-token-for-ministrant-b',
            'user': {'id': 9002, 'full_name': 'Ministrant B', 'role_id': 5},
          },
        ));
      }));

      final service = _InjectedDioUserSessionService(
        api: ApiClient(secureStorage),
        secureStorage: secureStorage,
        db: AppDatabase.forTesting(),
        snapshotStore: snapshotStore,
        fakeLoginDio: dio,
      );

      final result = await service.login(username: 'ministrant_b', password: 'whatever');
      expect(result, isA<UserLoginSuccess>());

      final adminADir = await snapshotStore.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php');
      expect(
        adminADir,
        isNull,
        reason: 'Ministrant B signing in must remove Admin A\'s offline snapshot — review round: "Ministrant B nie może zobaczyć snapshotu Admina"',
      );
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

/// Minimal test double for the one test above that needs to exercise
/// login()'s real user-switch/snapshot-clear logic without a real
/// network call. Mirrors UserSessionService.login()'s CURRENT success
/// contract exactly (token + user{id, full_name, role_id}) — this
/// double deliberately does NOT replicate the full error-mapping switch
/// (403/503/428/401/400) since this test only exercises the success
/// path; see user_session_service_test.dart's own _TestUserSessionService
/// for the fuller version used by tests that DO need those branches.
class _InjectedDioUserSessionService extends UserSessionService {
  _InjectedDioUserSessionService({
    required super.api,
    required super.secureStorage,
    required super.db,
    required super.snapshotStore,
    required this.fakeLoginDio,
  });

  final Dio fakeLoginDio;

  @override
  Future<UserLoginResult> login({required String username, required String password}) async {
    final installationId = await secureStorage.installationId;
    final serverUrl = await secureStorage.serverUrl;
    if (installationId == null || serverUrl == null) {
      return const UserLoginNetworkError();
    }

    try {
      final resp = await fakeLoginDio.post('/mobile/session/login', data: {
        'username': username,
        'password': password,
        'installation_id': installationId,
      });
      final data = resp.data as Map<String, dynamic>;
      final token = data['token'] as String;
      final user = data['user'] as Map<String, dynamic>;
      final newUserId = user['id'] as int;
      final fullName = user['full_name'] as String?;
      final roleId = user['role_id'] as int?;

      final previousUserId = await secureStorage.currentUserId;
      if (previousUserId != null && previousUserId != newUserId) {
        await db.wipeUserScopedBusinessData();
        final parishId = await secureStorage.parishId;
        if (parishId != null) {
          await snapshotStore.clearForUser(parishId: parishId, userId: previousUserId.toString());
        }
      }

      await secureStorage.setUserSession(token: token, userId: newUserId, fullName: fullName, roleId: roleId);
      api.resetParishClient();

      return UserLoginSuccess(fullName: fullName);
    } on DioException {
      return const UserLoginNetworkError();
    }
  }
}
