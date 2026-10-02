import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/offline/connectivity_probe.dart';
import 'package:ministrant_manager/core/offline/local_snapshot_server.dart';
import 'package:ministrant_manager/core/offline/offline_page_coordinator.dart';
import 'package:ministrant_manager/core/offline/page_resource_downloader.dart';
import 'package:ministrant_manager/core/offline/snapshot_capture_service.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/features/webview/webview_handoff_service.dart';

/// P10 fix: a test double for WebviewHandoffService, which
/// OfflinePageCoordinator now requires (targetPath/handoffUrl
/// separation — see that class's own docblock for the real-Szarlej
/// finding this fixes). Overrides ONLY requestHandoffUrl(); secureStorage
/// is still the REAL field OfflinePageCoordinator reads
/// (handoffService.secureStorage.serverUrl) for its reachability check.
class _FakeHandoffService extends WebviewHandoffService {
  _FakeHandoffService(SecureStorageService secureStorage) : super(api: ApiClient(secureStorage), secureStorage: secureStorage);

  Uri? handoffUrlToReturn;
  Object? errorToThrow;

  @override
  Future<Uri> requestHandoffUrl(String path) async {
    if (errorToThrow != null) throw errorToThrow!;
    return handoffUrlToReturn!;
  }
}

/// Offline-architecture milestone, P8.2: SnapshotStore/LocalSnapshotServer
/// now require a SnapshotEncryptor. A fixed, valid 64-character hex test
/// key, built programmatically (P8.1's own lesson about hand-counted
/// hex literals).
final _testEncryptor = SnapshotEncryptor(hexKey: 'c' * 64);

void main() {
  group('ConnectivityProbe', () {
    late HttpServer reachableServer;
    late Uri reachableUrl;

    setUp(() async {
      reachableServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      reachableUrl = Uri.parse('http://127.0.0.1:${reachableServer.port}/public/dashboard.php');
      reachableServer.listen((request) async {
        await request.response.close();
      });
    });

    tearDown(() async {
      await reachableServer.close(force: true);
    });

    test('a real, responding server is reachable', () async {
      final probe = ConnectivityProbe();
      expect(await probe.canReach(reachableUrl), isTrue);
    });

    test('a 404 response still counts as reachable — this checks network reachability, not whether the path exists', () async {
      final notFoundServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      notFoundServer.listen((request) async {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      final probe = ConnectivityProbe();
      expect(await probe.canReach(Uri.parse('http://127.0.0.1:${notFoundServer.port}/anything')), isTrue);
      await notFoundServer.close(force: true);
    });

    test('a closed port is not reachable', () async {
      final port = reachableServer.port;
      await reachableServer.close(force: true);
      final probe = ConnectivityProbe();
      expect(await probe.canReach(Uri.parse('http://127.0.0.1:$port/public/dashboard.php')), isFalse);
    });

    test('a server that never responds within the timeout is treated as unreachable', () async {
      final hangingServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      hangingServer.listen((request) {
        // Deliberately never responds — the probe's own timeout must
        // still resolve this to false rather than hanging the caller.
      });
      final probe = ConnectivityProbe(timeout: const Duration(milliseconds: 200));
      expect(await probe.canReach(Uri.parse('http://127.0.0.1:${hangingServer.port}/slow')), isFalse);
      await hangingServer.close(force: true);
    });
  });

  group('OfflinePageCoordinator', () {
    const secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final fakeStore = <String, String>{};

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
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
    late SnapshotStore store;
    late LocalSnapshotServer localServer;
    late SnapshotCaptureService captureService;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('offline_page_coordinator_test_');
      store = SnapshotStore(encryptor: _testEncryptor, rootOverride: tempRoot);
      localServer = LocalSnapshotServer(encryptor: _testEncryptor);
      captureService = SnapshotCaptureService(downloader: PageResourceDownloader(), store: store);
    });

    tearDown(() async {
      await localServer.stop();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('a reachable page plans to load online via a freshly-minted handoff URL, never targetPath itself', () async {
      final site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      site.listen((request) async => request.response.close());
      fakeStore['server_url'] = 'http://127.0.0.1:${site.port}';

      final secureStorage = SecureStorageService();
      final handoffUrl = Uri.parse('http://127.0.0.1:${site.port}/public/mobile_handoff.php?ticket=abc123');
      final handoffService = _FakeHandoffService(secureStorage)..handoffUrlToReturn = handoffUrl;

      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: handoffService,
      );

      final plan = await coordinator.plan(parishId: 'witosa', userId: '9001', targetPath: '/public/dashboard.php');
      expect(plan, isA<PageLoadOnline>());
      final onlinePlan = plan as PageLoadOnline;
      expect(onlinePlan.url, handoffUrl, reason: 'navigation must use the one-time handoff URL, never the plain target path');
      expect(onlinePlan.targetPath, '/public/dashboard.php', reason: 'the page identity must still be the real target, for capture/storage later');

      await site.close(force: true);
    });

    test('reachable but handoff-ticket-minting fails anyway falls through to the offline branch', () async {
      final site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      site.listen((request) async => request.response.close());
      fakeStore['server_url'] = 'http://127.0.0.1:${site.port}';

      await store.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html><body>Fallback snapshot</body></html>',
        assets: {},
        capturedAt: DateTime.utc(2026, 10, 1, 8, 0, 0),
      );

      final secureStorage = SecureStorageService();
      final handoffService = _FakeHandoffService(secureStorage)..errorToThrow = Exception('ticket mint failed');

      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: handoffService,
      );

      final plan = await coordinator.plan(parishId: 'witosa', userId: '9001', targetPath: '/public/dashboard.php');
      expect(
        plan,
        isA<PageLoadOffline>(),
        reason: 'reachability succeeding is not enough on its own — the ticket mint call itself can still fail',
      );

      await site.close(force: true);
    });

    test('unreachable page with no prior snapshot plans offlineNoSnapshot', () async {
      fakeStore['server_url'] = 'http://127.0.0.1:1';
      final secureStorage = SecureStorageService();
      final handoffService = _FakeHandoffService(secureStorage);

      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(timeout: const Duration(milliseconds: 200)),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: handoffService,
      );

      final plan = await coordinator.plan(parishId: 'witosa', userId: '9001', targetPath: '/public/dashboard.php');
      expect(plan, isA<PageLoadOfflineNoSnapshot>());
    });

    test('unreachable page WITH a prior snapshot plans offline, pointed at a working LocalSnapshotServer URL', () async {
      fakeStore['server_url'] = 'http://127.0.0.1:1';
      await store.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html><body>Last known good</body></html>',
        assets: {},
        capturedAt: DateTime.utc(2026, 10, 1, 8, 42, 0),
      );

      final secureStorage = SecureStorageService();
      final handoffService = _FakeHandoffService(secureStorage);

      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(timeout: const Duration(milliseconds: 200)),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: handoffService,
      );

      final plan = await coordinator.plan(parishId: 'witosa', userId: '9001', targetPath: '/public/dashboard.php');
      expect(plan, isA<PageLoadOffline>());
      final offlinePlan = plan as PageLoadOffline;
      expect(offlinePlan.capturedAt, DateTime.utc(2026, 10, 1, 8, 42, 0));

      // The capstone proof: the URL the plan hands back is ACTUALLY
      // servable, right now, by the SAME localServer instance.
      final client = HttpClient();
      final response = await (await client.getUrl(offlinePlan.url)).close();
      expect(response.statusCode, 200);
      final body = await utf8.decoder.bind(response).join();
      expect(body, contains('Last known good'));
    });

    test('formatOfflineBannerText produces the exact required format', () {
      expect(formatOfflineBannerText(DateTime(2026, 10, 1, 8, 42)), 'OFFLINE • ostatnia synchronizacja: 08:42');
      expect(formatOfflineBannerText(DateTime(2026, 10, 1, 23, 5)), 'OFFLINE • ostatnia synchronizacja: 23:05');
    });

    test('captureInBackground eventually persists a snapshot keyed by targetPath, without the caller awaiting it', () async {
      fakeStore['server_url'] = 'https://szarlej.ministrant.eu';
      final secureStorage = SecureStorageService();
      final handoffService = _FakeHandoffService(secureStorage);

      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: handoffService,
      );

      coordinator.captureInBackground(
        parishId: 'witosa',
        userId: '9001',
        targetPath: '/public/dashboard.php',
        renderedHtml: '<html><body>Freshly rendered</body></html>',
      );

      // Fire-and-forget by design (see the coordinator's own docblock) —
      // poll for the result rather than awaiting a Future that
      // deliberately doesn't exist at the call site.
      var found = false;
      for (var attempt = 0; attempt < 20 && !found; attempt++) {
        final manifest = await store.readManifestFor(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php');
        found = manifest != null;
        if (!found) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      final dir = await store.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php');
      expect(dir, isNotNull, reason: 'captureInBackground must eventually write a real snapshot even though nothing was awaited at the call site');
      final encryptedHtml = await File('${dir!.path}/snapshot.html').readAsBytes();
      final decryptedHtml = utf8.decode(_testEncryptor.decryptBytes(encryptedHtml));
      expect(decryptedHtml, contains('Freshly rendered'));
    });
  });
}
