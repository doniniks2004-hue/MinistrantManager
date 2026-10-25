import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:ministrant_manager/core/security/wipe_lock.dart';
import 'package:ministrant_manager/features/webview/webview_handoff_service.dart';

/// Every path of the coordinator that talks to the parish obeys the wipe lock: before the request
/// (nothing is asked while a wipe runs) and before the result is used (an answer to a request that was
/// started before a wipe cannot bring access back, record a refusal, pass on a revocation or lift a
/// module block, even when that wipe is already over by then). Written without being able to run
/// Flutter here: not executed.

class _Refusals implements RefusalStorage {
  final data = <RefusalSlot, String>{};
  @override
  Future<String?> read(RefusalSlot slot) async => data[slot];
  @override
  Future<void> write(RefusalSlot slot, String value) async => data[slot] = value;
  @override
  Future<void> delete(RefusalSlot slot) async => data.remove(slot);
}

class _Secure extends SecureStorageService {
  @override
  Future<String?> get deviceToken async => 'device-token-A';
}

class _NoIoStore extends SnapshotStore {
  _NoIoStore() : super(encryptor: SnapshotEncryptor(hexKey: 'c' * 64));

  @override
  Future<SnapshotManifest?> readManifestFor({
    required String parishId,
    required String userId,
    required String pagePath,
  }) async => null;
}

/// The parish's answer is held until the test lets it go.
class _Delayed extends WebviewHandoffService {
  _Delayed(SecureStorageService storage) : super(api: ApiClient(storage), secureStorage: storage);
  Completer<Uri> gate = Completer<Uri>();
  int calls = 0;

  @override
  Future<Uri> requestHandoffUrl(String path, {Duration timeout = WebviewHandoffService.defaultTimeout}) {
    calls++;
    return gate.future;
  }
}

DioException _moduleForbidden() {
  final request = RequestOptions(path: '/mobile/webview/handoff');
  return DioException(
    requestOptions: request,
    type: DioExceptionType.badResponse,
    response: Response<Object?>(requestOptions: request, statusCode: 403, data: {'error': 'forbidden'}),
  );
}

void main() {
  late _Refusals storage;
  late AccessRefusals refusals;
  late _Delayed handoff;
  late WipeLock lock;
  late OfflinePageCoordinator coordinator;
  final ok = Uri.parse('https://parish.example/mobile_handoff.php?t=x');
  const page = '/public/dashboard.php';

  setUp(() {
    storage = _Refusals();
    refusals = AccessRefusals(storage);
    final secure = _Secure();
    handoff = _Delayed(secure);
    lock = WipeLock();
    final snapshotStore = _NoIoStore();
    coordinator = OfflinePageCoordinator(
      connectivityProbe: ConnectivityProbe(),
      captureService: SnapshotCaptureService(downloader: PageResourceDownloader(), store: snapshotStore),
      snapshotStore: snapshotStore,
      localServer: LocalSnapshotServer(encryptor: SnapshotEncryptor(hexKey: 'c' * 64)),
      handoffService: handoff,
      refusals: refusals,
      onlineTimeout: const Duration(seconds: 5),
      firstOnlineTimeout: const Duration(seconds: 5),
      wipeLock: lock,
    );
  });

  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 20));

  group('plan()', () {
    test('control: no wipe -> the ticket is used and the module block is lifted', () async {
      await refusals.blockModule(parishId: 'p', userId: '7', path: page);
      final planning = coordinator.plan(parishId: 'p', userId: '7', targetPath: page);
      await tick();
      handoff.gate.complete(ok);
      expect(await planning, isA<PageLoadOnline>());
      await tick();
      expect(await refusals.checkModule(parishId: 'p', userId: '7', path: page), RefusalCheck.clear);
    });

    test('a wipe STARTS while the handoff is out: the late ticket is not used and lifts nothing', () async {
      await refusals.blockModule(parishId: 'p', userId: '7', path: page);
      final planning = coordinator.plan(parishId: 'p', userId: '7', targetPath: page);
      await tick();
      expect(handoff.calls, 1);
      lock.acquire(); // the wipe starts during the wait
      handoff.gate.complete(ok);
      final result = await planning;
      expect(result, isA<PageLoadServerError>());
      expect((result as PageLoadServerError).errorCode, 'wipe_in_progress');
      await tick();
      expect(await refusals.checkModule(parishId: 'p', userId: '7', path: page), RefusalCheck.blocked,
          reason: 'the module block was not lifted by an answer from before the wipe');
      expect(coordinator.localServer.rootDirectory, isNull);
    });

    test('the wipe is already OVER (lock released) by the time the late ticket arrives: still not used', () async {
      await refusals.blockModule(parishId: 'p', userId: '7', path: page);
      final planning = coordinator.plan(parishId: 'p', userId: '7', targetPath: page);
      await tick();
      lock.acquire();
      lock.release();
      handoff.gate.complete(ok);
      expect(await planning, isA<PageLoadServerError>());
      await tick();
      expect(await refusals.checkModule(parishId: 'p', userId: '7', path: page), RefusalCheck.blocked);
    });

    test('a REFUSAL that arrives after the wipe began is not recorded either', () async {
      final planning = coordinator.plan(parishId: 'p', userId: '7', targetPath: page);
      await tick();
      lock.acquire();
      handoff.gate.completeError(_moduleForbidden());
      expect((await planning as PageLoadServerError).errorCode, 'wipe_in_progress');
      expect(storage.data, isEmpty, reason: 'nothing was written for the data that is being erased');
      expect(await refusals.checkModule(parishId: 'p', userId: '7', path: page), RefusalCheck.clear);
    });

    test('while the wipe runs nothing is requested at all', () async {
      lock.acquire();
      final result = await coordinator.plan(parishId: 'p', userId: '7', targetPath: page);
      expect(result, isA<PageLoadServerError>());
      expect(handoff.calls, 0);
    });
  });

  group('probeOnline()', () {
    test('control: no wipe -> recovered, and the module block is lifted', () async {
      await refusals.blockModule(parishId: 'p', userId: '7', path: page);
      final probing = coordinator.probeOnline(parishId: 'p', userId: '7', targetPath: page);
      await tick();
      handoff.gate.complete(ok);
      expect(await probing, isA<OnlineProbeRecovered>());
      await tick();
      expect(await refusals.checkModule(parishId: 'p', userId: '7', path: page), RefusalCheck.clear);
    });

    test('while the wipe runs no handoff is requested', () async {
      lock.acquire();
      final result = await coordinator.probeOnline(parishId: 'p', userId: '7', targetPath: page);
      expect(result, isA<OnlineProbeUnavailable>());
      expect(handoff.calls, 0);
    });

    test('a wipe starts while the probe waits: NOT "recovered", nothing lifted', () async {
      await refusals.blockModule(parishId: 'p', userId: '7', path: page);
      final probing = coordinator.probeOnline(parishId: 'p', userId: '7', targetPath: page);
      await tick();
      lock.acquire();
      handoff.gate.complete(ok);
      expect(await probing, isA<OnlineProbeUnavailable>());
      await tick();
      expect(await refusals.checkModule(parishId: 'p', userId: '7', path: page), RefusalCheck.blocked);
    });

    test('a refusal that arrives after the wipe began is neither recorded nor reported', () async {
      final probing = coordinator.probeOnline(parishId: 'p', userId: '7', targetPath: page);
      await tick();
      lock.acquire();
      handoff.gate.completeError(_moduleForbidden());
      expect(await probing, isA<OnlineProbeUnavailable>());
      expect(storage.data, isEmpty);
    });
  });
}
