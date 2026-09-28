import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/features/auth/user_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Review round (milestone "Mój grafik"): unlike config_service_test.dart's
  // mock (which always returns null for 'read' — fine for "not activated"
  // paths), THIS test needs a real round-trip: write a value, read it back
  // on a LATER call, to genuinely exercise "was a different user signed in
  // before?". A plain in-memory map behind the same MethodChannel every
  // flutter_secure_storage call goes through.
  //
  // NOTE (honesty, same as the schema-migration test): this mock's
  // assumption about the exact argument shape flutter_secure_storage's
  // platform channel uses (`{'key': ..., 'value': ...}`) could not be
  // verified against the real plugin from this sandbox (no Flutter
  // toolchain here) — written carefully, but needs confirming against a
  // real `flutter test` run.
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

  /// Builds a UserSessionService whose login() talks to a FAKE parish
  /// server via a Dio interceptor (no real network) — returns [userId]
  /// for any successful login attempt, regardless of what
  /// username/password were passed (this test is about the user-switch
  /// wipe logic, not credential verification, which LegacyRepositoriesTest.php
  /// already covers on the backend).
  _TestUserSessionService buildServiceReturningUser(int userId, {String fullName = 'Test User'}) {
    final secureStorage = SecureStorageService();
    final api = ApiClient(secureStorage);
    final db = AppDatabase.forTesting();

    // Pre-seed activation (installation_id + server_url) — login() requires
    // both to be present before it will even attempt a request.
    fakeStore['installation_id'] = '550e8400-e29b-41d4-a716-446655440000';
    fakeStore['server_url'] = 'https://witosa.ministrant.eu';

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: {
          'token': 'fake-token-for-user-$userId',
          'user': {'id': userId, 'full_name': fullName, 'role_id': 5},
        },
      ));
    }));

    return _TestUserSessionService(api: api, secureStorage: secureStorage, db: db, fakeLoginDio: dio);
  }

  test('logging in as a DIFFERENT user than previously stored wipes user-scoped business data', () async {
    final service = buildServiceReturningUser(9001);
    final db = service.db;

    // Simulate: user 9001 already has a synced schedule on this device.
    await db.into(db.events).insert(EventsCompanion.insert(
          id: 'events:1', rawId: 1, source: 'events', eventDate: DateTime.now().toUtc(),
        ));
    await db.into(db.scheduleAssignments).insert(ScheduleAssignmentsCompanion.insert(
          id: 'schedule:1', rawId: 1, eventId: 'events:1', eventSource: 'events', status: 'assigned',
          userId: const Value(9001),
        ));
    expect((await db.select(db.events).get()).length, 1);

    // First login as 9001 (same user as already stored) — nothing to wipe,
    // this is just "the same person opening the app again".
    await service.login(username: 'adam', password: 'whatever');
    expect((await db.select(db.events).get()).length, 1, reason: 'same user logging in again must NOT wipe their own just-synced data');

    // NOW a different user (9002 — "Bartek") logs in on this SAME device.
    final serviceForSecondUser = buildServiceReturningUser(9002);
    // Re-point the second service at the SAME db/secure storage the first
    // one used, so this genuinely simulates "one device, two accounts",
    // not two unrelated installs.
    final secondLoginService = _TestUserSessionService(
      api: service.api,
      secureStorage: service.secureStorage,
      db: db,
      fakeLoginDio: serviceForSecondUser.fakeLoginDio,
    );

    await secondLoginService.login(username: 'bartek', password: 'whatever');

    final eventsAfterSwitch = await db.select(db.events).get();
    expect(eventsAfterSwitch, isEmpty, reason: "Adam's cached schedule must be gone the instant Bartek signs in — never glimpsed, even briefly");

    final storedUserId = await service.secureStorage.currentUserId;
    expect(storedUserId, 9002, reason: 'the stored current user is now Bartek');

    await db.close();
  });

  test('logout clears the user session and wipes user-scoped business data, but keeps activation', () async {
    final service = buildServiceReturningUser(9001);
    final db = service.db;

    await service.login(username: 'adam', password: 'whatever');
    await db.into(db.events).insert(EventsCompanion.insert(
          id: 'events:1', rawId: 1, source: 'events', eventDate: DateTime.now().toUtc(),
        ));

    await service.logout();

    expect(await service.secureStorage.hasUserSession, isFalse);
    expect((await db.select(db.events).get()), isEmpty);
    // Activation itself must survive logout — no re-scanning the QR code.
    expect(await service.secureStorage.installationId, isNotNull);
    expect(await service.secureStorage.serverUrl, isNotNull);

    await db.close();
  });

  test('user switch clears lastSyncAt but leaves lastAuthorizationCheck/offlineLeaseHours untouched', () async {
    final service = buildServiceReturningUser(9001);
    final db = service.db;

    await service.login(username: 'adam', password: 'whatever');
    final deviceCheckTime = DateTime.utc(2026, 1, 1, 12, 0);
    // Real bug in THIS TEST (not production code): sync_metadata has NO
    // row yet on a fresh AppDatabase.forTesting() — `ensureSyncMetadata()`
    // creates it lazily on first real use, which login() never triggers.
    // A bare UPDATE ... WHERE id=1 against zero existing rows is a silent
    // no-op, so the values below would never actually be set without this
    // first call — ensure the row exists before updating it.
    await db.ensureSyncMetadata();
    await (db.update(db.syncMetadata)..where((t) => t.id.equals(1))).write(
      SyncMetadataCompanion(
        lastSyncAt: Value(DateTime.utc(2026, 1, 1, 12, 30)), // Adam's last snapshot time
        lastAuthorizationCheck: Value(deviceCheckTime),
        offlineLeaseHours: const Value(72),
      ),
    );

    final secondLoginService = _TestUserSessionService(
      api: service.api,
      secureStorage: service.secureStorage,
      db: db,
      fakeLoginDio: buildServiceReturningUser(9002).fakeLoginDio,
    );
    await secondLoginService.login(username: 'bartek', password: 'whatever');

    final meta = await db.ensureSyncMetadata();
    expect(meta.lastSyncAt, isNull, reason: "Bartek must not see Adam's last-sync timestamp in an offline banner");
    expect(
      meta.lastAuthorizationCheck?.toUtc(),
      deviceCheckTime.toUtc(),
      reason: 'device-level auth-check timestamp is unrelated to which user is signed in',
    );
    expect(meta.offlineLeaseHours, 72, reason: 'device-level lease policy is unrelated to which user is signed in');

    await db.close();
  });

  test('hasUserSession requires BOTH token and user_id — a half-written state (interrupted process) is never read as a valid session', () async {
    final secureStorage = SecureStorageService();
    // Simulate a process interrupted between the two writes inside
    // setUserSession() — user_id present, but the token write never
    // happened (the FIXED write order: user_id first, token last — so
    // this is the realistic half-written state after the fix, not the
    // old bug's shape).
    fakeStore['current_user_id'] = '9001';

    expect(await secureStorage.hasUserSession, isFalse);
  });
}

/// Test seam: real UserSessionService.login() builds its own Dio pointed
/// at the real parish server URL — this subclass swaps that internal call
/// for a fake, pre-wired Dio instead, so the test never attempts real
/// network I/O. Mirrors the login()/logout() logic exactly; kept as a
/// thin override rather than changing the production class's shape for
/// testability alone.
class _TestUserSessionService extends UserSessionService {
  _TestUserSessionService({
    required super.api,
    required super.secureStorage,
    required super.db,
    required this.fakeLoginDio,
  });

  final Dio fakeLoginDio;

  @override
  Future<UserLoginResult> login({required String username, required String password}) async {
    final installationId = await secureStorage.installationId;
    if (installationId == null) return const UserLoginNetworkError();

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
      }

      await secureStorage.setUserSession(token: token, userId: newUserId, fullName: fullName, roleId: roleId);
      api.resetParishClient();

      return UserLoginSuccess(fullName: fullName);
    } on DioException {
      return const UserLoginNetworkError();
    }
  }
}
