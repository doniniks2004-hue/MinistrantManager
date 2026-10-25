import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart';

/// What the app can and cannot know about a revocation while the phone is offline.
///
/// A device that is ALREADY offline when an administrator revokes it cannot learn that: nothing reaches it. What
/// bounds the damage is the local lease (`offline_lease_hours`, from the last time the central server confirmed the
/// device). These tests pin exactly that: while offline the answer follows the lease and nothing else, a failed check
/// never extends the lease, and the revocation is acted on at the first answer that reaches the app. They do NOT claim
/// that a remote revocation is detected instantly without a connection, because it is not.
///
/// A refusal that WAS received by the app (DEVICE_REVOKED / PARISH_DISABLED) is a different case: see
/// offline_isolation_integration_test.dart (RevocationHandler removes every user's copy of the parish) and
/// revocation_wipe_test.dart (the key is destroyed even if the files cannot be deleted).
class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    calls++;
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody json(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );

class _FakeApi extends ApiClient {
  _FakeApi(SecureStorageService storage, this.adapter) : super(storage);
  final _Adapter adapter;

  @override
  Dio centralWithAuth(String deviceToken) => Dio(BaseOptions(baseUrl: ApiClient.centralBaseUrl))..httpClientAdapter = adapter;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late AppDatabase db;
  late _Adapter adapter;
  late SyncEngine engine;
  final answers = <Future<ResponseBody> Function(RequestOptions)>[];

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final key = (call.arguments as Map)['key'];
      return call.method == 'read' && key == 'device_token' ? 'device-token' : null;
    });
    db = AppDatabase.forTesting();
    answers.clear();
    adapter = _Adapter((o) => answers.removeAt(0).call(o));
    final storage = SecureStorageService();
    engine = SyncEngine(db: db, api: _FakeApi(storage, adapter), secureStorage: storage);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await db.close();
  });

  Future<void> lastChecked(Duration ago, {int? leaseHours}) async {
    await db.ensureSyncMetadata();
    await (db.update(db.syncMetadata)..where((t) => t.id.equals(1))).write(
      SyncMetadataCompanion(
        lastAuthorizationCheck: Value(DateTime.now().toUtc().subtract(ago)),
        offlineLeaseHours: leaseHours == null ? const Value.absent() : Value(leaseHours),
      ),
    );
  }

  Future<DeviceAuthState> check() async =>
      (await engine.checkDeviceStatus(appVersion: '1.0.0', osVersion: 'Android 14'))!.state;

  Future<ResponseBody> offline(RequestOptions o) => Future.error(DioException(requestOptions: o, type: DioExceptionType.connectionError));

  group('the device is OFFLINE (no answer reaches the app): the local lease decides, and only the lease', () {
    test('within the lease: the saved copy stays available, EVEN IF the device was revoked on the server a moment ago', () async {
      await lastChecked(const Duration(hours: 10), leaseHours: 72);
      answers.add(offline); // the revocation exists on the server; nothing reaches the app
      expect(await check(), DeviceAuthState.offlineWithinLease);
    });

    test('past the lease: the copy is refused until the app reaches the server', () async {
      await lastChecked(const Duration(hours: 80), leaseHours: 72);
      answers.add(offline);
      expect(await check(), DeviceAuthState.offlineLeaseExpired);
    });

    test('the lease is the one the server last reported, not a constant: a 24 h policy expires a 30 h old check', () async {
      await lastChecked(const Duration(hours: 30), leaseHours: 24);
      answers.add(offline);
      expect(await check(), DeviceAuthState.offlineLeaseExpired);
    });

    test('a device never confirmed by the server has no lease at all', () async {
      await db.ensureSyncMetadata();
      answers.add(offline);
      expect(await check(), DeviceAuthState.offlineLeaseExpired);
    });

    test('a failed check does NOT extend the lease: the time of the last confirmation is unchanged', () async {
      await lastChecked(const Duration(hours: 10), leaseHours: 72);
      final before = (await db.ensureSyncMetadata()).lastAuthorizationCheck;
      answers
        ..add(offline)
        ..add((o) => Future.value(json(503, {'message': 'maintenance'})));
      await check();
      await check();
      expect((await db.ensureSyncMetadata()).lastAuthorizationCheck, before);
    });

    test('a server outage (5xx) is treated like no answer: the lease, not a verdict', () async {
      await lastChecked(const Duration(hours: 10), leaseHours: 72);
      answers.add((o) => Future.value(json(503, {'message': 'maintenance'})));
      expect(await check(), DeviceAuthState.offlineWithinLease);
    });
  });

  group('the first answer that DOES reach the app is acted on', () {
    test('DEVICE_REVOKED is read as a revocation, whatever the lease says', () async {
      await lastChecked(const Duration(hours: 1), leaseHours: 72);
      answers.add((o) => Future.value(json(200, {'status': 'DEVICE_REVOKED'})));
      expect(await check(), DeviceAuthState.revoked);
    });

    test('PARISH_DISABLED likewise', () async {
      await lastChecked(const Duration(hours: 1), leaseHours: 72);
      answers.add((o) => Future.value(json(200, {'status': 'PARISH_DISABLED'})));
      expect(await check(), DeviceAuthState.parishDisabled);
    });

    test('a revocation is NOT read from a lease that has expired: an expired lease is its own state', () async {
      await lastChecked(const Duration(hours: 200), leaseHours: 72);
      answers.add(offline);
      expect(await check(), DeviceAuthState.offlineLeaseExpired);
      answers.add((o) => Future.value(json(200, {'status': 'DEVICE_REVOKED'})));
      expect(await check(), DeviceAuthState.revoked, reason: 'and the moment the server is reached, the verdict is the server\'s');
    });

    test('ACTIVE renews the lease and takes the new policy', () async {
      await lastChecked(const Duration(hours: 80), leaseHours: 72);
      answers.add((o) => Future.value(json(200, {'status': 'ACTIVE', 'offline_lease_hours': 24})));
      expect(await check(), DeviceAuthState.active);
      final meta = await db.ensureSyncMetadata();
      expect(meta.offlineLeaseHours, 24);
      expect(DateTime.now().toUtc().difference(meta.lastAuthorizationCheck!.toUtc()).inSeconds, lessThan(5));
    });

    test('only a CONFIRMED active answer renews it: a revocation answer does not touch the lease clock', () async {
      await lastChecked(const Duration(hours: 5), leaseHours: 72);
      final before = (await db.ensureSyncMetadata()).lastAuthorizationCheck;
      answers.add((o) => Future.value(json(200, {'status': 'DEVICE_REVOKED'})));
      await check();
      expect((await db.ensureSyncMetadata()).lastAuthorizationCheck, before);
    });
  });
}
