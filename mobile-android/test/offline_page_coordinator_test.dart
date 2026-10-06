import 'dart:async';
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
import 'package:ministrant_manager/core/offline/snapshot_manifest.dart';
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
  _FakeHandoffService(SecureStorageService secureStorage)
    : super(api: ApiClient(secureStorage), secureStorage: secureStorage);

  Uri? handoffUrlToReturn;
  Object? errorToThrow;
  int calls = 0;
  bool hang = false;

  @override
  Future<Uri> requestHandoffUrl(String path) async {
    calls++;
    if (hang) return Completer<Uri>().future;
    if (errorToThrow != null) throw errorToThrow!;
    return handoffUrlToReturn!;
  }
}

/// Lets a test hold individual pages' local planning steps open (until
/// the gate returned by [hold] completes — or forever, if the test never
/// completes it) while other pages plan normally. Everything else is the
/// real SnapshotStore.
class _GatedStore extends SnapshotStore {
  _GatedStore(Directory root)
    : super(encryptor: _testEncryptor, rootOverride: root);

  final Map<String, Completer<void>> _gates = {};

  Completer<void> hold(String pagePath) =>
      _gates[pagePath] = Completer<void>();

  @override
  Future<SnapshotManifest?> readManifestFor({
    required String parishId,
    required String userId,
    required String pagePath,
  }) async {
    final gate = _gates[pagePath];
    if (gate != null) await gate.future;
    return super.readManifestFor(
      parishId: parishId,
      userId: userId,
      pagePath: pagePath,
    );
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
      reachableUrl = Uri.parse(
        'http://127.0.0.1:${reachableServer.port}/public/dashboard.php',
      );
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
      final notFoundServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      notFoundServer.listen((request) async {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      final probe = ConnectivityProbe();
      expect(
        await probe.canReach(
          Uri.parse('http://127.0.0.1:${notFoundServer.port}/anything'),
        ),
        isTrue,
      );
      await notFoundServer.close(force: true);
    });

    test('a closed port is not reachable', () async {
      final port = reachableServer.port;
      await reachableServer.close(force: true);
      final probe = ConnectivityProbe();
      expect(
        await probe.canReach(
          Uri.parse('http://127.0.0.1:$port/public/dashboard.php'),
        ),
        isFalse,
      );
    });

    test('a server that never responds within the timeout is treated as unreachable', () async {
      final hangingServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      hangingServer.listen((request) {
        // Deliberately never responds — the probe's own timeout must
        // still resolve this to false rather than hanging the caller.
      });
      final probe = ConnectivityProbe(
        timeout: const Duration(milliseconds: 200),
      );
      expect(
        await probe.canReach(
          Uri.parse('http://127.0.0.1:${hangingServer.port}/slow'),
        ),
        isFalse,
      );
      await hangingServer.close(force: true);
    });
  });

  group('OfflinePageCoordinator', () {
    const secureStorageChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final fakeStore = <String, String>{};

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      fakeStore.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, (call) async {
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
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
    });

    late Directory tempRoot;
    late SnapshotStore store;
    late LocalSnapshotServer localServer;
    late SnapshotCaptureService captureService;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp(
        'offline_page_coordinator_test_',
      );
      store = SnapshotStore(encryptor: _testEncryptor, rootOverride: tempRoot);
      localServer = LocalSnapshotServer(encryptor: _testEncryptor);
      captureService = SnapshotCaptureService(
        downloader: PageResourceDownloader(),
        store: store,
      );
    });

    tearDown(() async {
      await localServer.stop();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('known offline never makes a handoff request', () async {
      final handoff = _FakeHandoffService(SecureStorageService())..hang = true;
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: handoff,
      );
      await store.writeSnapshot(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/ranking.php',
        html: '<html>Ranking</html>',
        assets: {},
      );
      final plan = await coordinator.plan(
        parishId: 'p',
        userId: 'u',
        targetPath: '/public/ranking.php',
        forceOffline: true,
      );
      expect(plan, isA<PageLoadOffline>());
      expect(handoff.calls, 0);
    });

    test('a blackholed handoff has a total deadline', () async {
      final handoff = _FakeHandoffService(SecureStorageService())..hang = true;
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: handoff,
        onlineTimeout: const Duration(milliseconds: 100),
      );
      final clock = Stopwatch()..start();
      final plan = await coordinator.plan(
        parishId: 'p',
        userId: 'u',
        targetPath: '/public/dashboard.php',
      );
      expect(plan, isA<PageLoadOfflineNoSnapshot>());
      expect(clock.elapsedMilliseconds, lessThan(500));
      expect(handoff.calls, 1);
    });

    test('a stuck local planning step has its own deadline', () async {
      final gated = _GatedStore(tempRoot)..hold('/public/dashboard.php');
      final handoff = _FakeHandoffService(SecureStorageService())
        ..errorToThrow = Exception('down');
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: gated,
        localServer: localServer,
        handoffService: handoff,
        offlinePlanTimeout: const Duration(milliseconds: 100),
      );
      final clock = Stopwatch()..start();
      final plan = await coordinator.plan(
        parishId: 'p',
        userId: 'u',
        targetPath: '/public/dashboard.php',
      );
      expect(plan, isA<PageLoadOfflineNoSnapshot>());
      expect(clock.elapsedMilliseconds, lessThan(1000));
    });

    test('a superseded local plan never repoints the shared server', () async {
      final gated = _GatedStore(tempRoot);
      await gated.writeSnapshot(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/dashboard.php',
        html: '<html>Dashboard</html>',
        assets: {},
      );
      await gated.writeSnapshot(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/ranking.php',
        html: '<html>Ranking</html>',
        assets: {},
      );
      final dashboardGate = gated.hold('/public/dashboard.php');
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: gated,
        localServer: localServer,
        handoffService: _FakeHandoffService(SecureStorageService()),
      );

      // The dashboard plan is held open at the gate; a NEWER plan for
      // another page runs to completion first.
      final slow = coordinator.plan(
        parishId: 'p',
        userId: 'u',
        targetPath: '/public/dashboard.php',
        forceOffline: true,
      );
      final fast = await coordinator.plan(
        parishId: 'p',
        userId: 'u',
        targetPath: '/public/ranking.php',
        forceOffline: true,
      );
      expect(fast, isA<PageLoadOffline>());
      final rankingDir = await gated.getPageDirectoryIfReady(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/ranking.php',
      );
      expect(localServer.rootDirectory?.path, rankingDir!.path);

      dashboardGate.complete();
      final late = await slow;
      expect(late, isA<PageLoadOfflineNoSnapshot>());
      expect(
        localServer.rootDirectory?.path,
        rankingDir.path,
        reason: 'the older, slower plan must not repoint the server',
      );
    });

    test(
      'an EXPIRED local plan never repoints the shared server when it finally finishes',
      () async {
        final gated = _GatedStore(tempRoot);
        await gated.writeSnapshot(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/dashboard.php',
          html: '<html>Dashboard</html>',
          assets: {},
        );
        final gate = gated.hold('/public/dashboard.php');
        final coordinator = OfflinePageCoordinator(
          connectivityProbe: ConnectivityProbe(),
          captureService: captureService,
          snapshotStore: gated,
          localServer: localServer,
          handoffService: _FakeHandoffService(SecureStorageService()),
          offlinePlanTimeout: const Duration(milliseconds: 100),
        );

        // No newer plan is ever started: only the plan's OWN deadline
        // can be what stops it. Future.timeout alone would not.
        final plan = await coordinator.plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/dashboard.php',
          forceOffline: true,
        );
        expect(plan, isA<PageLoadOfflineNoSnapshot>());
        expect(localServer.rootDirectory, isNull);

        gate.complete(); // the expired read now completes
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(
          localServer.rootDirectory,
          isNull,
          reason: 'an expired plan must not repoint the server afterwards',
        );
        expect(localServer.isRunning, isFalse);
      },
    );

    test(
      "one plan's timeout never invalidates a NEWER plan that is still healthy",
      () async {
        final gated = _GatedStore(tempRoot);
        for (final path in ['/public/dashboard.php', '/public/ranking.php']) {
          await gated.writeSnapshot(
            parishId: 'p',
            userId: 'u',
            pagePath: path,
            html: '<html>$path</html>',
            assets: {},
          );
        }
        final dashboardGate = gated.hold('/public/dashboard.php');
        final rankingGate = gated.hold('/public/ranking.php');
        final coordinator = OfflinePageCoordinator(
          connectivityProbe: ConnectivityProbe(),
          captureService: captureService,
          snapshotStore: gated,
          localServer: localServer,
          handoffService: _FakeHandoffService(SecureStorageService()),
          offlinePlanTimeout: const Duration(milliseconds: 600),
        );

        // t=0: older plan A starts and will expire at t=600.
        final planA = coordinator.plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/dashboard.php',
          forceOffline: true,
        );
        // t=200: NEWER plan B starts; its own deadline is t=800.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final planB = coordinator.plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/ranking.php',
          forceOffline: true,
        );
        // t=700: A has expired, B has not. Release B.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(await planA, isA<PageLoadOfflineNoSnapshot>());
        rankingGate.complete();

        expect(
          await planB,
          isA<PageLoadOffline>(),
          reason: "A's expiry must not have invalidated B",
        );
        final rankingDir = await gated.getPageDirectoryIfReady(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/ranking.php',
        );
        expect(localServer.rootDirectory?.path, rankingDir!.path);

        dashboardGate.complete(); // expired A finally unblocks
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(localServer.rootDirectory?.path, rankingDir.path);
      },
    );

    test('each offline plan has its own document URL; the previous one stops being owned', () async {
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: _FakeHandoffService(SecureStorageService()),
      );
      await store.writeSnapshot(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/ranking.php',
        html: '<html>Ranking</html>',
        assets: {},
      );
      Future<PageLoadOffline> planOffline() async =>
          await coordinator.plan(
                parishId: 'p',
                userId: 'u',
                targetPath: '/public/ranking.php',
                forceOffline: true,
              )
              as PageLoadOffline;

      final first = await planOffline();
      final second = await planOffline();

      // OfflineAwarePageScreen tells a retry's document from the one it
      // replaced by this: a late callback for the older URL is rejected
      // by ownsUrl() itself. If the server ever stopped rotating its
      // token, that separation would silently disappear — hence a test.
      expect(second.url.path, isNot(first.url.path));
      expect(localServer.ownsUrl(second.url), isTrue);
      expect(localServer.ownsUrl(first.url), isFalse);

      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        final client = HttpClient();
        final response = await (await client.getUrl(second.url)).close();
        expect(response.statusCode, 200);
        expect(await utf8.decoder.bind(response).join(), contains('Ranking'));
        client.close(force: true);
      } finally {
        HttpOverrides.global = previousHttpOverrides;
      }
    });

    test('a reachable page plans to load online via a freshly-minted handoff URL, never targetPath itself', () async {
      final site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      site.listen((request) async => request.response.close());
      fakeStore['server_url'] = 'http://127.0.0.1:${site.port}';

      final secureStorage = SecureStorageService();
      final handoffUrl = Uri.parse(
        'http://127.0.0.1:${site.port}/public/mobile_handoff.php?ticket=abc123',
      );
      final handoffService = _FakeHandoffService(secureStorage)
        ..handoffUrlToReturn = handoffUrl;

      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: handoffService,
      );

      final plan = await coordinator.plan(
        parishId: 'witosa',
        userId: '9001',
        targetPath: '/public/dashboard.php',
      );
      expect(plan, isA<PageLoadOnline>());
      final onlinePlan = plan as PageLoadOnline;
      expect(
        onlinePlan.url,
        handoffUrl,
        reason: 'navigation must use the one-time handoff URL, never the plain target path',
      );
      expect(
        onlinePlan.targetPath,
        '/public/dashboard.php',
        reason: 'the page identity must still be the real target, for capture/storage later',
      );

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
      final handoffService = _FakeHandoffService(secureStorage)
        ..errorToThrow = Exception('ticket mint failed');

      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: handoffService,
      );

      final plan = await coordinator.plan(
        parishId: 'witosa',
        userId: '9001',
        targetPath: '/public/dashboard.php',
      );
      expect(
        plan,
        isA<PageLoadOffline>(),
        reason: 'reachability succeeding is not enough on its own — the ticket mint call itself can still fail',
      );

      await site.close(force: true);
    });

    test(
      'unreachable page with no prior snapshot plans offlineNoSnapshot',
      () async {
        fakeStore['server_url'] = 'http://127.0.0.1:1';
        final secureStorage = SecureStorageService();
        final handoffService = _FakeHandoffService(secureStorage);

        final coordinator = OfflinePageCoordinator(
          connectivityProbe: ConnectivityProbe(
            timeout: const Duration(milliseconds: 200),
          ),
          captureService: captureService,
          snapshotStore: store,
          localServer: localServer,
          handoffService: handoffService,
        );

        final plan = await coordinator.plan(
          parishId: 'witosa',
          userId: '9001',
          targetPath: '/public/dashboard.php',
        );
        expect(plan, isA<PageLoadOfflineNoSnapshot>());
      },
    );

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
        connectivityProbe: ConnectivityProbe(
          timeout: const Duration(milliseconds: 200),
        ),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: handoffService,
      );

      final plan = await coordinator.plan(
        parishId: 'witosa',
        userId: '9001',
        targetPath: '/public/dashboard.php',
      );
      expect(plan, isA<PageLoadOffline>());
      final offlinePlan = plan as PageLoadOffline;
      expect(offlinePlan.capturedAt, DateTime.utc(2026, 10, 1, 8, 42, 0));

      // The capstone proof: the URL the plan hands back is ACTUALLY
      // servable, right now, by the SAME localServer instance.
      //
      // Review round fix (test-harness bug, root-caused via the
      // dedicated diagnostic test below — NOT a LocalSnapshotServer or
      // OfflinePageCoordinator bug): this group's setUp() calls
      // TestWidgetsFlutterBinding.ensureInitialized() (needed for the
      // secure-storage MethodChannel mock), which installs
      // flutter_test's own HttpOverrides — intercepting HttpClient
      // globally and faking a 400 response instead of letting the
      // request actually reach our real, listening LocalSnapshotServer.
      // Temporarily clearing HttpOverrides.global escapes that ambient
      // mock for exactly this one real TCP round-trip (restored in
      // finally, so it never leaks into any other test in this file) —
      // the same mechanism local_snapshot_server_test.dart's tests never
      // needed because that file never calls ensureInitialized() at all.
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        final client = HttpClient();
        final response = await (await client.getUrl(offlinePlan.url)).close();
        expect(response.statusCode, 200);
        final body = await utf8.decoder.bind(response).join();
        expect(body, contains('Last known good'));
      } finally {
        HttpOverrides.global = previousHttpOverrides;
      }
    });

    test('DIAGNOSTIC: isolates the 400 reported against the offline-plan URL — prints the real response instead of guessing', () async {
      fakeStore['server_url'] = 'http://127.0.0.1:1';
      await store.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html><body>Diagnostic snapshot</body></html>',
        assets: {},
        capturedAt: DateTime.utc(2026, 10, 1, 8, 42, 0),
      );

      final secureStorage = SecureStorageService();
      final handoffService = _FakeHandoffService(secureStorage);
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(
          timeout: const Duration(milliseconds: 200),
        ),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: handoffService,
      );

      final plan = await coordinator.plan(
        parishId: 'witosa',
        userId: '9001',
        targetPath: '/public/dashboard.php',
      );
      final offlinePlan = plan as PageLoadOffline;

      // ignore: avoid_print
      print('DIAGNOSTIC offlinePlan.url = ${offlinePlan.url}');
      // ignore: avoid_print
      print(
        'DIAGNOSTIC offlinePlan.url.toString() = ${offlinePlan.url.toString()}',
      );
      // ignore: avoid_print
      print(
        'DIAGNOSTIC localServer.isRunning = ${localServer.isRunning}, port = ${localServer.port}',
      );

      // Confirmed root cause (see this file's own capstone test for
      // the full explanation): flutter_test's own ambient
      // HttpOverrides, installed by this group's
      // TestWidgetsFlutterBinding.ensureInitialized() call, faked the
      // original 400 this diagnostic test was built to isolate.
      // Escaped here too (restored in finally) so this diagnostic now
      // shows the REAL response for confirmation.
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        final client = HttpClient();
        final request = await client.getUrl(offlinePlan.url);
        // ignore: avoid_print
        print(
          'DIAGNOSTIC request.method = ${request.method}, request.uri = ${request.uri}',
        );
        final response = await request.close();
        // ignore: avoid_print
        print(
          'DIAGNOSTIC statusCode = ${response.statusCode}, reasonPhrase = ${response.reasonPhrase}',
        );
        // ignore: avoid_print
        print('DIAGNOSTIC headers = ${response.headers}');
        final body = await utf8.decoder.bind(response).join();
        // ignore: avoid_print
        print('DIAGNOSTIC body = $body');
      } finally {
        HttpOverrides.global = previousHttpOverrides;
      }

      // Deliberately no hard assertion here beyond "the request completed" —
      // this test's entire purpose is the printed output above, not a
      // pass/fail signal.
    });

    test('formatOfflineBannerText produces the exact required format', () {
      expect(
        formatOfflineBannerText(DateTime(2026, 10, 1, 8, 42)),
        'OFFLINE • ostatnia synchronizacja: 08:42',
      );
      expect(
        formatOfflineBannerText(DateTime(2026, 10, 1, 23, 5)),
        'OFFLINE • ostatnia synchronizacja: 23:05',
      );
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
        final manifest = await store.readManifestFor(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/dashboard.php',
        );
        found = manifest != null;
        if (!found) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      final dir = await store.getPageDirectoryIfReady(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
      );
      expect(
        dir,
        isNotNull,
        reason: 'captureInBackground must eventually write a real snapshot even though nothing was awaited at the call site',
      );
      final encryptedHtml = await File('${dir!.path}/snapshot.html')
          .readAsBytes();
      final decryptedHtml = utf8.decode(
        _testEncryptor.decryptBytes(encryptedHtml),
      );
      expect(decryptedHtml, contains('Freshly rendered'));
    });
  });
}
