import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/security/access_refusals.dart' show AccessRefusals;
import 'package:ministrant_manager/core/sync/sync_engine.dart';

/// What the app does with the answers of the CENTRAL server to `POST /device/status`, and what it
/// remembers of a refusal so that a LATER start, with no connection, cannot open the saved copy.
///
/// Rules these tests pin (agreed with the owner):
///  - one unambiguous answer of the right endpoint rejecting the device token (401) is enough, and
///    it is remembered across restarts; it is reversible and erases nothing;
///  - it is lifted only by a verified ACTIVE (or by a new activation, i.e. another token);
///  - an answer that cannot be read (unknown status, a body that is not an object, a 403 this
///    endpoint does not give) is NOT ACTIVE, does not renew the lease, does not erase, does not add
///    a refusal, and does not remove one;
///  - a 401 of the PARISH api (the user's session) is not a refusal of the device.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody json(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );

class _FakeApi extends ApiClient {
  _FakeApi(SecureStorageService storage, this.central, this.parishAdapter) : super(storage);
  final _Adapter central;
  final _Adapter parishAdapter;

  @override
  Dio centralWithAuth(String deviceToken) => Dio(BaseOptions(baseUrl: ApiClient.centralBaseUrl))..httpClientAdapter = central;

  @override
  Future<Dio> parish() async => Dio(BaseOptions(baseUrl: 'https://szarlej.ministrant.eu/api'))..httpClientAdapter = parishAdapter;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late AppDatabase db;
  late SecureStorageService storage;
  late SyncEngine engine;
  late Map<String, String> keystore;
  // Failures of the keystore for the refusal records only ("refusal_*"): the device token stays readable.
  var failRefusalReads = false;
  var failRefusalWrites = false;
  var failRefusalDeletes = false;
  final centralAnswers = <Future<ResponseBody> Function(RequestOptions)>[];
  final parishAnswers = <Future<ResponseBody> Function(RequestOptions)>[];

  setUp(() async {
    keystore = {'device_token': 'device-token-A'};
    failRefusalReads = failRefusalWrites = failRefusalDeletes = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map);
      final key = args['key'] as String?;
      final isRefusal = key != null && key.startsWith('refusal_');
      if (isRefusal) {
        final broken = switch (call.method) {
          'read' => failRefusalReads,
          'write' => failRefusalWrites,
          'delete' => failRefusalDeletes,
          _ => false,
        };
        if (broken) throw PlatformException(code: 'keystore-unavailable');
      }
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
    centralAnswers.clear();
    parishAnswers.clear();
    storage = SecureStorageService();
    engine = SyncEngine(
      db: db,
      api: _FakeApi(storage, _Adapter((o) => centralAnswers.removeAt(0).call(o)), _Adapter((o) => parishAnswers.removeAt(0).call(o))),
      secureStorage: storage,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await db.close();
  });

  Future<void> lastChecked(Duration ago, {int leaseHours = 72}) async {
    await db.ensureSyncMetadata();
    await (db.update(db.syncMetadata)..where((t) => t.id.equals(1))).write(
      SyncMetadataCompanion(
        lastAuthorizationCheck: Value(DateTime.now().toUtc().subtract(ago)),
        offlineLeaseHours: Value(leaseHours),
      ),
    );
  }

  Future<DeviceAuthState> check() async =>
      (await engine.checkDeviceStatus(appVersion: '1.0.0', osVersion: 'Android 14'))!.state;

  Future<ResponseBody> offline(RequestOptions o) => Future.error(DioException(requestOptions: o, type: DioExceptionType.connectionError));
  Future<ResponseBody> status(int code, Object body) => Future.value(json(code, body));

  Future<DateTime?> leaseClock() async => (await db.ensureSyncMetadata()).lastAuthorizationCheck;

  Future<void> refuseWith401() async {
    centralAnswers.add((o) => status(401, {'error': 'Unknown device token'}));
    expect(await check(), DeviceAuthState.tokenRejected);
  }

  group('a 401 from /device/status (the central server does not accept this device token)', () {
    test('is one answer enough: the device is refused, and the refusal is remembered', () async {
      await lastChecked(const Duration(hours: 1));
      await refuseWith401();
      expect(await engine.persistedRefusal(), isNotNull);
    });

    test('the NEXT start with no connection does not get the lease back: the refusal stands, even within the lease', () async {
      await lastChecked(const Duration(hours: 1), leaseHours: 72);
      await refuseWith401();
      centralAnswers.add(offline);
      expect(await check(), DeviceAuthState.tokenRejected, reason: 'was offlineWithinLease before the refusal');
    });

    test('and it is known BEFORE the network is asked, from local storage alone', () async {
      await lastChecked(const Duration(hours: 1));
      await refuseWith401();
      final fresh = SyncEngine(
        db: db,
        api: _FakeApi(storage, _Adapter((o) => throw StateError('no network call expected')), _Adapter((o) => throw StateError('no network call expected'))),
        secureStorage: storage,
      );
      expect((await fresh.persistedRefusal())!.state, DeviceAuthState.tokenRejected, reason: 'a new process, nothing in memory');
    });

    test('erases nothing: the token and the activation are still there', () async {
      await refuseWith401();
      expect(keystore['device_token'], 'device-token-A');
      expect(await storage.isActivated, isTrue);
    });

    test('a server outage (5xx) afterwards does not undo it', () async {
      await lastChecked(const Duration(hours: 1));
      await refuseWith401();
      centralAnswers.add((o) => status(503, {'message': 'maintenance'}));
      expect(await check(), DeviceAuthState.tokenRejected);
    });

    test('the lease clock is not touched by it', () async {
      await lastChecked(const Duration(hours: 5));
      final before = await leaseClock();
      await refuseWith401();
      centralAnswers.add(offline);
      await check();
      expect(await leaseClock(), before);
    });
  });

  group('answers that cannot be read are NOT a refusal, NOT active, and do not disturb what is remembered', () {
    final unreadable = <String, Future<ResponseBody> Function(RequestOptions)>{
      'an unknown status string': (o) => status(200, {'status': 'SOMETHING_NEW'}),
      'a missing status': (o) => status(200, {'offline_lease_hours': 72}),
      'a body that is not an object': (o) => status(200, ['ACTIVE']),
      'a 403 (this endpoint does not give one: a firewall or proxy does)': (o) => status(403, '<html>blocked</html>'),
      'a 404': (o) => status(404, {'message': 'nope'}),
      'a 422': (o) => status(422, {'message': 'bad version'}),
    };

    for (final e in unreadable.entries) {
      test('${e.key}: with nothing remembered it fails closed (authError), remembers nothing, does not renew the lease', () async {
        await lastChecked(const Duration(hours: 5));
        final before = await leaseClock();
        centralAnswers.add(e.value);
        expect(await check(), DeviceAuthState.authError);
        expect(await engine.persistedRefusal(), isNull, reason: 'an unreadable answer is not a refusal');
        expect(await leaseClock(), before, reason: 'and it is not an ACTIVE, so the lease is not renewed');
        expect(keystore['device_token'], 'device-token-A', reason: 'nothing erased');
      });

      test('${e.key}: with a refusal remembered, the refusal is still reported and still remembered', () async {
        await lastChecked(const Duration(hours: 5));
        await refuseWith401();
        centralAnswers.add(e.value);
        expect(await check(), DeviceAuthState.tokenRejected);
        expect(await engine.persistedRefusal(), isNotNull, reason: 'noise does not lift it');
      });
    }

    test('an unknown status is not given the meaning of DEVICE_REVOKED: it does not erase and is not revoked', () async {
      centralAnswers.add((o) => status(200, {'status': 'DEVICE_BANNED'}));
      final state = await check();
      expect(state, isNot(DeviceAuthState.revoked));
      expect(state, isNot(DeviceAuthState.parishDisabled));
    });
  });

  group('what lifts it', () {
    test('a verified ACTIVE lifts it, renews the lease, and the next offline start follows the lease again', () async {
      await lastChecked(const Duration(hours: 80), leaseHours: 72);
      await refuseWith401();
      centralAnswers.add((o) => status(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
      expect(await check(), DeviceAuthState.active);
      expect(await engine.persistedRefusal(), isNull);
      centralAnswers.add(offline);
      expect(await check(), DeviceAuthState.offlineWithinLease, reason: 'the lease was renewed by that ACTIVE');
    });

    test('UPDATE_REQUIRED is unchanged and does NOT lift it: only ACTIVE does', () async {
      await refuseWith401();
      centralAnswers.add((o) => status(200, {'status': 'UPDATE_REQUIRED', 'minimum_supported_app_version': '9.9.9'}));
      expect(await check(), DeviceAuthState.updateRequired);
      expect(await engine.persistedRefusal(), isNotNull);
    });

    test('a refusal received for one token is not in force for another: a new activation starts clean', () async {
      await refuseWith401();
      keystore['device_token'] = 'device-token-B'; // activated again
      expect(await engine.persistedRefusal(), isNull);
      centralAnswers.add(offline);
      await lastChecked(const Duration(hours: 1));
      expect(await check(), DeviceAuthState.offlineWithinLease);
    });

    test('clearing the activation (a revocation or a reset) clears it with the rest', () async {
      await refuseWith401();
      await storage.clearActivation();
      expect(keystore.keys.where((k) => k.startsWith('refusal_')), isEmpty);
    });

    test('a user LOGGING OUT does not lift it', () async {
      await refuseWith401();
      await storage.clearUserSession();
      expect(await engine.persistedRefusal(), isNotNull);
    });
  });

  group('the confirmed revocation is unchanged', () {
    test('DEVICE_REVOKED and PARISH_DISABLED are read as before, with or without a remembered refusal', () async {
      centralAnswers.add((o) => status(200, {'status': 'DEVICE_REVOKED'}));
      expect(await check(), DeviceAuthState.revoked);
      await refuseWith401();
      centralAnswers.add((o) => status(200, {'status': 'PARISH_DISABLED'}));
      expect(await check(), DeviceAuthState.parishDisabled);
    });
  });

  group('a 401 of the PARISH api is the user\'s session, never a refusal of the device', () {
    test('it is reported as an expired session and remembers nothing about the device', () async {
      parishAnswers.add((o) => status(401, {'error': 'invalid_token'}));
      await expectLater(engine.fetchAndApplySnapshot(), throwsA(isA<ParishSessionExpiredException>()));
      expect(await engine.persistedRefusal(), isNull);
      centralAnswers.add(offline);
      await lastChecked(const Duration(hours: 1));
      expect(await check(), DeviceAuthState.offlineWithinLease, reason: 'the device is untouched');
    });

    test('a 403 of the parish api is a contract problem, not a refusal of the device', () async {
      parishAnswers.add((o) => status(403, {'error': 'forbidden'}));
      await expectLater(engine.fetchAndApplySnapshot(), throwsA(isA<ParishContractErrorException>()));
      expect(await engine.persistedRefusal(), isNull);
    });
  });

  group('the three answers: no refusal, a refusal, CANNOT TELL (storage failures)', () {
    test('a record that cannot be read is "cannot tell": not null, not tokenRejected', () async {
      await refuseWith401();
      // A new process (nothing held in memory) finds the keystore unreadable.
      final fresh = SyncEngine(db: db, api: engine.api, secureStorage: storage);
      failRefusalReads = true;
      expect((await fresh.persistedRefusal())!.state, DeviceAuthState.refusalUnknown);
    });

    test('a device token that cannot be read is "cannot tell" too', () async {
      final broken = _BrokenTokenStorage();
      final fresh = SyncEngine(db: db, api: engine.api, secureStorage: broken);
      expect((await fresh.persistedRefusal())!.state, DeviceAuthState.refusalUnknown);
    });

    test('an offline start with such a record does NOT get the lease back: cannot tell, nothing shown', () async {
      await lastChecked(const Duration(hours: 1));
      await refuseWith401();
      final fresh = SyncEngine(db: db, api: engine.api, secureStorage: storage);
      failRefusalReads = true;
      centralAnswers.add(offline);
      final state = (await fresh.checkDeviceStatus(appVersion: '1.0.0', osVersion: 'Android 14'))!.state;
      expect(state, DeviceAuthState.refusalUnknown, reason: 'was offlineWithinLease: the bug');
    });

    test('a 5xx and an answer that cannot be read also stay at "cannot tell"', () async {
      await lastChecked(const Duration(hours: 1));
      await refuseWith401();
      final fresh = SyncEngine(db: db, api: engine.api, secureStorage: storage);
      failRefusalReads = true;
      centralAnswers.add((o) => status(503, {'error': 'x'}));
      expect((await fresh.checkDeviceStatus(appVersion: '1.0.0', osVersion: 'Android 14'))!.state, DeviceAuthState.refusalUnknown);
      centralAnswers.add((o) => status(200, {'status': 'SOMETHING_NEW'}));
      expect((await fresh.checkDeviceStatus(appVersion: '1.0.0', osVersion: 'Android 14'))!.state, DeviceAuthState.refusalUnknown);
    });

    test('it is settled by a verified ACTIVE, which removes the record', () async {
      await refuseWith401();
      final fresh = SyncEngine(db: db, api: engine.api, secureStorage: storage);
      failRefusalReads = true;
      centralAnswers.add((o) => status(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
      expect((await fresh.checkDeviceStatus(appVersion: '1.0.0', osVersion: 'Android 14'))!.state, DeviceAuthState.active);
      failRefusalReads = false;
      expect(await fresh.persistedRefusal(), isNull);
    });
  });

  group('a refusal that cannot be WRITTEN still blocks, in this process', () {
    test('the 401 is reported as a refusal, and it is still known at the next check, offline', () async {
      await lastChecked(const Duration(hours: 1));
      failRefusalWrites = true;
      await refuseWith401();
      expect((await engine.persistedRefusal())!.state, DeviceAuthState.tokenRejected);
      centralAnswers.add(offline);
      expect(await check(), DeviceAuthState.tokenRejected, reason: 'not the lease');
    });

    test('and while the keystore also cannot be read', () async {
      failRefusalWrites = true;
      await refuseWith401();
      failRefusalReads = true;
      expect((await engine.persistedRefusal())!.state, DeviceAuthState.tokenRejected);
    });

    test('a restart does not know of it: nothing was written (stated, not hidden)', () async {
      failRefusalWrites = true;
      await refuseWith401();
      final fresh = SyncEngine(db: db, api: engine.api, secureStorage: storage);
      failRefusalWrites = false;
      expect(await fresh.persistedRefusal(), isNull);
    });
  });

  group('a refusal that cannot be REMOVED is not reported as lifted', () {
    test('ACTIVE with a failing delete: "cannot tell", the lease is NOT renewed, the block is still known', () async {
      await lastChecked(const Duration(hours: 80), leaseHours: 72);
      await refuseWith401();
      final before = await leaseClock();
      failRefusalDeletes = true;
      centralAnswers.add((o) => status(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
      expect(await check(), DeviceAuthState.refusalUnknown);
      expect(await leaseClock(), before, reason: 'a lift that failed must not renew anything');
      expect((await engine.persistedRefusal())!.state, DeviceAuthState.tokenRejected);
    });

    test('the next ACTIVE, once the delete works, says active and renews the lease', () async {
      await lastChecked(const Duration(hours: 80), leaseHours: 72);
      await refuseWith401();
      failRefusalDeletes = true;
      centralAnswers.add((o) => status(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
      expect(await check(), DeviceAuthState.refusalUnknown);
      failRefusalDeletes = false;
      centralAnswers.add((o) => status(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
      expect(await check(), DeviceAuthState.active);
      expect(await engine.persistedRefusal(), isNull);
    });
  });

  group('the parish said no, then the central server is asked again (the parish answer may be old)', () {
    test('reverifyDevice returns what the central server says, with the versions of the last check', () async {
      centralAnswers.add((o) => status(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
      expect(await check(), DeviceAuthState.active);
      centralAnswers.add((o) => status(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
      expect(await engine.reverifyDevice(), DeviceAuthState.active);
    });

    test('with no earlier check there are no versions to send: it does not guess', () async {
      expect(await engine.reverifyDevice(), isNull);
    });

    test('a 401 found by it is remembered like any other', () async {
      centralAnswers.add((o) => status(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
      await check();
      centralAnswers.add((o) => status(401, {'error': 'Unknown device token'}));
      expect(await engine.reverifyDevice(), DeviceAuthState.tokenRejected);
      expect(await engine.persistedRefusal(), isNotNull);
    });
  });

  group('an answer is applied only to the activation it was for', () {
    String recordFor(String token) =>
        jsonEncode({'tf': AccessRefusals.fingerprint(token), 'src': 'central_401', 'at': '2026-10-22T09:00:00.000Z'});

    Future<DeviceStatusResult?> checkWithAnswerHeldBack(Object body, {int status = 200}) async {
      final gate = Completer<void>();
      centralAnswers.add((o) async {
        await gate.future;
        return json(status, body);
      });
      final pending = engine.checkDeviceStatus(appVersion: '1.0.0', osVersion: 'Android 14');
      await Future<void>.delayed(const Duration(milliseconds: 20)); // the request is on its way
      // The device is activated again, with another token that has a refusal of its own.
      keystore['device_token'] = 'device-token-B';
      keystore['refusal_device'] = recordFor('device-token-B');
      gate.complete();
      return pending;
    }

    test('a late ACTIVE for the OLD token lifts nothing of the new activation and renews nothing', () async {
      await lastChecked(const Duration(hours: 80), leaseHours: 72);
      final before = await leaseClock();
      final result = await checkWithAnswerHeldBack({'status': 'ACTIVE', 'offline_lease_hours': 72});
      expect(result, isNull, reason: 'the answer is dropped');
      expect(keystore['refusal_device'], recordFor('device-token-B'), reason: 'the new activation keeps its refusal');
      expect(await leaseClock(), before);
    });

    test('a late DEVICE_REVOKED for the old token is not applied to the new one (no erasing)', () async {
      final result = await checkWithAnswerHeldBack({'status': 'DEVICE_REVOKED'});
      expect(result, isNull);
    });

    test('a late 401 for the old token adds nothing to the new activation', () async {
      final result = await checkWithAnswerHeldBack({'error': 'Unknown device token'}, status: 401);
      expect(result, isNull);
      expect(keystore['refusal_device'], recordFor('device-token-B'));
    });

    test('an ACTIVE that arrives while the token is unchanged is applied as before', () async {
      await refuseWith401();
      centralAnswers.add((o) => status(200, {'status': 'ACTIVE', 'offline_lease_hours': 72}));
      expect(await check(), DeviceAuthState.active);
      expect(keystore.containsKey('refusal_device'), isFalse);
    });
  });
}

class _BrokenTokenStorage extends SecureStorageService {
  @override
  Future<String?> get deviceToken async => throw PlatformException(code: 'keystore-unavailable');
}
