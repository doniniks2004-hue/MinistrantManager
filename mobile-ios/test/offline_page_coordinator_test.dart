import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/offline/connectivity_probe.dart';
import 'package:ministrant_manager/core/offline/local_snapshot_server.dart';
import 'package:ministrant_manager/core/offline/offline_page_coordinator.dart';
import 'package:ministrant_manager/core/offline/page_resource_downloader.dart';
import 'package:ministrant_manager/core/offline/server_reachability.dart';
import 'package:ministrant_manager/core/offline/snapshot_capture_service.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_manifest.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/security/access_refusals.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart' show DeviceAuthState;
import 'package:ministrant_manager/features/webview/webview_handoff_service.dart';

// Real loopback sockets for tests that verify the local HTTP response. The
// Flutter binding otherwise substitutes an HTTP client that always returns 400.
class _LoopbackHttpOverrides extends HttpOverrides {}

/// P10 fix: a test double for WebviewHandoffService, which
/// OfflinePageCoordinator now requires (targetPath/handoffUrl
/// separation — see that class's own docblock for the real-Szarlej
/// finding this fixes). Overrides ONLY requestHandoffUrl(); secureStorage
/// is still the REAL field OfflinePageCoordinator reads
/// (handoffService.secureStorage.serverUrl) for its reachability check.
/// Counts what the coordinator asks the capture service to do.
class _CountingCapture extends SnapshotCaptureService {
  _CountingCapture(SnapshotStore store)
    : super(downloader: PageResourceDownloader(), store: store);

  final htmls = <String>[];
  Completer<void>? gate;
  CaptureOutcome outcome = const CaptureOutcome(CaptureStatus.saved);

  @override
  Future<CaptureOutcome> captureAndSave({
    required String parishId,
    required String userId,
    required Uri serverBaseUrl,
    required String targetPath,
    required String renderedHtml,
    int? expectedGeneration,
  }) async {
    htmls.add(renderedHtml);
    await gate?.future;
    return outcome;
  }
}

/// A server that cannot bind (e.g. no loopback), to prove warmUp never throws.
class _FailingServer extends LocalSnapshotServer {
  _FailingServer() : super(encryptor: _testEncryptor);

  @override
  Future<int> start() => Future<int>.error(const SocketException('no loopback'));
}

class _FakeHandoffService extends WebviewHandoffService {
  _FakeHandoffService(SecureStorageService secureStorage)
    : super(api: ApiClient(secureStorage), secureStorage: secureStorage);

  Uri? handoffUrlToReturn;
  Object? errorToThrow;
  int calls = 0;
  bool hang = false;

  /// If set, the request stays pending until this completes.
  Completer<void>? gate;
  Duration? lastTimeout;
  String? lastPath;

  @override
  Future<Uri> requestHandoffUrl(
    String path, {
    Duration timeout = WebviewHandoffService.defaultTimeout,
  }) async {
    calls++;
    lastTimeout = timeout;
    lastPath = path;
    if (hang) return Completer<Uri>().future;
    if (gate != null) await gate!.future;
    if (errorToThrow != null) throw errorToThrow!;
    return handoffUrlToReturn!;
  }
}

/// A handoff service whose keystore cannot give the device token (a failing read, not "not activated").
class _TokenFailsHandoff extends _FakeHandoffService {
  _TokenFailsHandoff() : super(_TokenFailsStorage()) {
    handoffUrlToReturn = Uri.parse('https://szarlej.ministrant.eu/public/mobile_handoff.php?ticket=t');
  }
}

class _TokenFailsStorage extends SecureStorageService {
  @override
  Future<String?> get deviceToken async => throw PlatformException(code: 'keystore-unavailable');
}

DioException _httpError(int status, [Object? data]) {
  final request = RequestOptions(path: '/mobile/webview/handoff');
  return DioException(
    requestOptions: request,
    type: DioExceptionType.badResponse,
    response: Response<Object?>(
      requestOptions: request,
      statusCode: status,
      data: data,
    ),
  );
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

/// A store whose manifest reads can be slow or fail, and which counts them.
class _ReadingStore extends SnapshotStore {
  _ReadingStore(Directory root) : super(encryptor: _testEncryptor, rootOverride: root);

  Duration readDelay = Duration.zero;
  Object? readFailure;
  int reads = 0;

  @override
  Future<SnapshotManifest?> readManifestFor({
    required String parishId,
    required String userId,
    required String pagePath,
  }) async {
    reads++;
    if (readDelay > Duration.zero) await Future<void>.delayed(readDelay);
    if (readFailure != null) throw readFailure!;
    return super.readManifestFor(parishId: parishId, userId: userId, pagePath: pagePath);
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
    // Failures of the keystore for the refusal records only ("refusal_*").
    var failRefusalReads = false;
    var failRefusalWrites = false;
    var failRefusalDeletes = false;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      fakeStore.clear();
      failRefusalReads = failRefusalWrites = failRefusalDeletes = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, (call) async {
            final args = call.arguments as Map?;
            final key = args?['key'] as String?;
            if (key != null && key.startsWith('refusal_')) {
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

    group('a saved copy that this install cannot read (another key, damaged, an older format)', () {
      OfflinePageCoordinator coordinatorOver(SnapshotStore withStore) => OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: SnapshotCaptureService(downloader: PageResourceDownloader(), store: withStore),
        snapshotStore: withStore,
        localServer: localServer,
        handoffService: _FakeHandoffService(SecureStorageService()),
      );

      Future<void> saveWith(SnapshotStore target, String html) => target.writeSnapshot(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/ranking.php',
        html: html,
        assets: {'public/css/style.css': utf8.encode('body{}')},
      );

      test('is read as "no copy": no exception, no loop, and the answer is the same every time', () async {
        // Saved by an install whose key is lost (a restored backup, a rotated key).
        await saveWith(SnapshotStore(encryptor: SnapshotEncryptor(hexKey: 'a' * 64), rootOverride: tempRoot), '<html>old</html>');
        final coordinator = coordinatorOver(store); // this install: _testEncryptor, another key

        for (var attempt = 0; attempt < 3; attempt++) {
          final plan = await coordinator.plan(parishId: 'p', userId: 'u', targetPath: '/public/ranking.php', forceOffline: true);
          expect(plan, isA<PageLoadOfflineNoSnapshot>(), reason: 'attempt $attempt');
          expect((plan as PageLoadOfflineNoSnapshot).timedOut, isFalse, reason: 'it is not a timeout: nothing to open');
        }
        expect(await coordinator.hasSavedCopy(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php'), isFalse);
        expect(localServer.rootDirectory, isNull, reason: 'nothing unreadable was handed to the server');
      });

      test('the next capture REPLACES it, and the new copy opens', () async {
        await saveWith(SnapshotStore(encryptor: SnapshotEncryptor(hexKey: 'a' * 64), rootOverride: tempRoot), '<html>old</html>');
        final coordinator = coordinatorOver(store);
        expect(await coordinator.plan(parishId: 'p', userId: 'u', targetPath: '/public/ranking.php', forceOffline: true), isA<PageLoadOfflineNoSnapshot>());

        await saveWith(store, '<html>new</html>');

        final plan = await coordinator.plan(parishId: 'p', userId: 'u', targetPath: '/public/ranking.php', forceOffline: true);
        expect(plan, isA<PageLoadOffline>());
        final client = HttpOverrides.runWithHttpOverrides(
          () => HttpClient(), _LoopbackHttpOverrides(),
        );
        addTearDown(() => client.close(force: true));
        final response = await (await client.getUrl((plan as PageLoadOffline).url)).close();
        final body = await response.transform(utf8.decoder).join();
        expect(response.statusCode, 200);
        expect(body, contains('new'));
      });

      test('a copy whose manifest opens but whose PAGE does not is refused by the server (500), not served and not hung', () async {
        await saveWith(store, '<html>fine</html>');
        final dir = (await store.getPageDirectoryIfReady(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php'))!;
        final page = File('${dir.path}/snapshot.html');
        final bytes = page.readAsBytesSync();
        bytes[bytes.length - 1] ^= 0xff; // a changed byte in the authentication tag
        page.writeAsBytesSync(bytes);

        final coordinator = coordinatorOver(store);
        final plan = await coordinator.plan(parishId: 'p', userId: 'u', targetPath: '/public/ranking.php', forceOffline: true);
        expect(plan, isA<PageLoadOffline>(), reason: 'the manifest is fine: it is the page that fails, when asked');

        final client = HttpOverrides.runWithHttpOverrides(
          () => HttpClient(), _LoopbackHttpOverrides(),
        );
        addTearDown(() => client.close(force: true));
        final response = await (await client.getUrl((plan as PageLoadOffline).url)).close().timeout(const Duration(seconds: 5));
        await response.drain<void>();
        expect(response.statusCode, 500, reason: 'integrity failure: refused, never served');
        expect(localServer.isRunning, isTrue, reason: 'one bad file does not take the server down');
      });
    });

    test('an offline plan after the app was away: the dead listener is replaced, the URL answers', () async {
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
      await localServer.start();
      await localServer.debugKillListenerForTest(); // reclaimed while in the background

      final plan = await coordinator.plan(
        parishId: 'p',
        userId: 'u',
        targetPath: '/public/ranking.php',
        forceOffline: true,
      );

      expect(plan, isA<PageLoadOffline>());
      final url = (plan as PageLoadOffline).url;
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        url.port,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy(); // the plan's address is a live one
    });

    test('a plan with no copy carries WHY the live page could not be had (not always "no network")', () async {
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: _FakeHandoffService(SecureStorageService()),
      );
      for (final reason in OfflineReason.values) {
        final plan = await coordinator.plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/never-saved.php',
          forceOffline: true,
          offlineReason: reason,
        );
        expect((plan as PageLoadOfflineNoSnapshot).reason, reason);
      }
    });

    group('what is known about the saved copy, and the start budget shared with the handoff', () {
      OfflinePageCoordinator make(SnapshotStore st, _FakeHandoffService handoff, {Duration plan = const Duration(milliseconds: 100)}) =>
          OfflinePageCoordinator(
            connectivityProbe: ConnectivityProbe(),
            captureService: SnapshotCaptureService(downloader: PageResourceDownloader(), store: st),
            snapshotStore: st,
            localServer: localServer,
            handoffService: handoff,
            offlinePlanTimeout: plan,
          );

      test('the handoff gets: little time with a copy, a first handoff\'s time with none, what is left when unknown', () {
        final c = make(store, _FakeHandoffService(SecureStorageService()));
        expect(c.handoffBudgetFor(SavedCopyFact.exists), c.onlineTimeout);
        expect(c.handoffBudgetFor(SavedCopyFact.exists, spent: const Duration(seconds: 2)), c.onlineTimeout);
        expect(c.handoffBudgetFor(SavedCopyFact.absent), c.firstOnlineTimeout);
        expect(c.handoffBudgetFor(SavedCopyFact.unknown, spent: const Duration(milliseconds: 400)),
            c.firstOnlineTimeout - const Duration(milliseconds: 400));
        expect(c.handoffBudgetFor(SavedCopyFact.unchecked, spent: const Duration(milliseconds: 400)),
            c.firstOnlineTimeout - const Duration(milliseconds: 400));
        expect(c.handoffBudgetFor(SavedCopyFact.unknown, spent: const Duration(seconds: 10)), c.onlineTimeout,
            reason: 'never less than the ordinary handoff time');
        expect(c.handoffBudgetFor(SavedCopyFact.unknown), c.firstOnlineTimeout);
      });

      test('savedCopyFact: a manifest is "exists", none is "absent", a slow or failing read is "unknown" and never "absent"', () async {
        final reading = _ReadingStore(tempRoot);
        final c = make(reading, _FakeHandoffService(SecureStorageService()));
        await reading.writeSnapshot(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php', html: '<html>R</html>', assets: {});
        expect(await c.savedCopyFact(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php'), SavedCopyFact.exists);
        expect(await c.savedCopyFact(parishId: 'p', userId: 'u', pagePath: '/public/never.php'), SavedCopyFact.absent);
        reading.readDelay = const Duration(milliseconds: 400); // over the 100 ms plan limit
        expect(await c.savedCopyFact(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php'), SavedCopyFact.unknown);
        reading.readDelay = Duration.zero;
        reading.readFailure = StateError('manifest unreadable');
        expect(await c.savedCopyFact(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php'), SavedCopyFact.unknown);
        // and hasSavedCopy keeps its meaning for the screens that use it (a failed read is not a copy)
        expect(await c.hasSavedCopy(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php'), isFalse);
      });

      test('REGRESSION: the system said "no network", the copy read was slow, the server IS reachable: the live page is the result', () async {
        final reading = _ReadingStore(tempRoot)..readDelay = const Duration(milliseconds: 400);
        final handoff = _FakeHandoffService(SecureStorageService())
          ..handoffUrlToReturn = Uri.parse('https://szarlej.ministrant.eu/public/mobile_handoff.php?ticket=t');
        final c = make(reading, handoff);
        final plan = await c.plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/dashboard.php',
          copyFact: SavedCopyFact.unknown,
          alreadySpent: const Duration(milliseconds: 400),
        );
        expect(plan, isA<PageLoadOnline>());
        expect(handoff.calls, 1);
        expect(reading.reads, 0, reason: 'the manifest the caller could not read in time is NOT read again, with a timeout of its own');
        expect(handoff.lastTimeout, c.firstOnlineTimeout - const Duration(milliseconds: 400));
      });

      test('a plan asked to find out itself spends that time out of the handoff\'s, not on top of it', () async {
        final reading = _ReadingStore(tempRoot)..readDelay = const Duration(milliseconds: 400);
        final handoff = _FakeHandoffService(SecureStorageService())
          ..handoffUrlToReturn = Uri.parse('https://szarlej.ministrant.eu/public/mobile_handoff.php?ticket=t');
        final c = make(reading, handoff);
        await c.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php');
        expect(reading.reads, 1);
        expect(handoff.lastTimeout!, lessThan(c.firstOnlineTimeout), reason: 'the 100 ms the unfinished read used came off the budget');
        expect(handoff.lastTimeout!, greaterThanOrEqualTo(c.onlineTimeout));
      });

      test('a copy the caller already knows to exist is not looked for again before the handoff', () async {
        final reading = _ReadingStore(tempRoot);
        await reading.writeSnapshot(parishId: 'p', userId: 'u', pagePath: '/public/dashboard.php', html: '<html>D</html>', assets: {});
        Future<int> readsFor(SavedCopyFact fact) async {
          reading.reads = 0;
          final handoff = _FakeHandoffService(SecureStorageService())..errorToThrow = DioException(
            requestOptions: RequestOptions(path: '/x'),
            type: DioExceptionType.connectionError,
          );
          final c = make(reading, handoff, plan: const Duration(seconds: 2));
          final plan = await c.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php', copyFact: fact);
          expect(plan, isA<PageLoadOffline>(), reason: 'the handoff failed, the copy is shown');
          return reading.reads;
        }
        final known = await readsFor(SavedCopyFact.exists);
        final asked = await readsFor(SavedCopyFact.unchecked);
        expect(asked, known + 1, reason: 'exactly the one read the caller had already done');
      });

      test('when the server is NOT reachable the copy is still shown, with the failure\'s own reason, not a store timeout', () async {
        final reading = _ReadingStore(tempRoot);
        await reading.writeSnapshot(parishId: 'p', userId: 'u', pagePath: '/public/dashboard.php', html: '<html>D</html>', assets: {});
        final handoff = _FakeHandoffService(SecureStorageService())..errorToThrow = _httpError(503);
        final c = make(reading, handoff, plan: const Duration(seconds: 2));
        final plan = await c.plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/dashboard.php',
          copyFact: SavedCopyFact.unknown,
          alreadySpent: const Duration(milliseconds: 400),
        );
        expect(plan, isA<PageLoadOffline>());
        expect((plan as PageLoadOffline).reason, OfflineReason.serverUnavailable);
      });
    });

    group('a refusal the server gave is not bypassed by the saved copy', () {
      late _ReadingStore reading;
      late _FakeHandoffService handoff;
      late OfflinePageCoordinator c;

      Future<void> save(String page, {String user = 'u'}) =>
          reading.writeSnapshot(parishId: 'p', userId: user, pagePath: page, html: '<html>$page</html>', assets: {});

      setUp(() async {
        fakeStore['device_token'] = 'device-token-A';
        reading = _ReadingStore(tempRoot);
        handoff = _FakeHandoffService(SecureStorageService())
          ..handoffUrlToReturn = Uri.parse('https://szarlej.ministrant.eu/public/mobile_handoff.php?ticket=t');
        c = OfflinePageCoordinator(
          connectivityProbe: ConnectivityProbe(),
          captureService: SnapshotCaptureService(downloader: PageResourceDownloader(), store: reading),
          snapshotStore: reading,
          localServer: localServer,
          handoffService: handoff,
        );
        await save('/public/dashboard.php');
        await save('/public/ranking.php');
      });

      Future<PageLoadPlan> online(String page, {String user = 'u'}) =>
          c.plan(parishId: 'p', userId: user, targetPath: page);
      Future<PageLoadPlan> offlineOnly(String page, {String user = 'u'}) =>
          c.plan(parishId: 'p', userId: user, targetPath: page, forceOffline: true);

      // ---- 403 forbidden: the user's role has no access to the module

      test('403 forbidden blocks THAT module: the reply says so and offers no copy, even though one exists', () async {
        handoff.errorToThrow = _httpError(403, {'error': 'forbidden', 'message': 'Brak uprawnień do tego modułu.'});
        final plan = await online('/public/ranking.php');
        expect(plan, isA<PageLoadServerError>());
        final e = plan as PageLoadServerError;
        expect(e.refusal, HandoffRefusal.module);
        expect(e.hasSnapshot, isFalse);
        expect(e.remembered, isFalse);
      });

      test('a LATER start with no connection does not open that module\'s copy (direct entry, not only a hidden button)', () async {
        handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
        await online('/public/ranking.php');
        final offlinePlan = await offlineOnly('/public/ranking.php');
        expect(offlinePlan, isA<PageLoadServerError>(), reason: 'was PageLoadOffline before the refusal');
        expect((offlinePlan as PageLoadServerError).remembered, isTrue);
        expect(offlinePlan.refusal, HandoffRefusal.module);
        expect(localServer.rootDirectory, isNull, reason: 'nothing is being served');
        expect(await c.hasSavedCopy(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php'), isFalse);
        expect(await c.savedCopyFact(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php'), SavedCopyFact.absent);
      });

      test('the refusal survives a restart: a coordinator built afterwards on the same storage still refuses', () async {
        handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
        await online('/public/ranking.php');
        final restarted = OfflinePageCoordinator(
          connectivityProbe: ConnectivityProbe(),
          captureService: SnapshotCaptureService(downloader: PageResourceDownloader(), store: reading),
          snapshotStore: reading,
          localServer: localServer,
          handoffService: _FakeHandoffService(SecureStorageService()),
        );
        final plan = await restarted.plan(parishId: 'p', userId: 'u', targetPath: '/public/ranking.php', forceOffline: true);
        expect(plan, isA<PageLoadServerError>());
      });

      test('other modules of the same user keep working offline', () async {
        handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
        await online('/public/ranking.php');
        expect(await offlineOnly('/public/dashboard.php'), isA<PageLoadOffline>());
      });

      test('another user of the same parish is not affected', () async {
        await save('/public/ranking.php', user: 'other');
        handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
        await online('/public/ranking.php');
        expect(await offlineOnly('/public/ranking.php', user: 'other'), isA<PageLoadOffline>());
      });

      test('a page opened THROUGH the blocked module (another page, entry = the module) is refused too', () async {
        await save('/public/ranking_detail.php');
        handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
        await c.plan(parishId: 'p', userId: 'u', targetPath: '/public/ranking_detail.php', handoffPath: '/public/ranking.php');
        final viaEntry = await c.plan(
          parishId: 'p', userId: 'u', targetPath: '/public/ranking_detail.php', handoffPath: '/public/ranking.php', forceOffline: true,
        );
        expect(viaEntry, isA<PageLoadServerError>());
      });

      test('it is lifted ONLY by the server accepting a handoff for that module', () async {
        handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
        await online('/public/ranking.php');
        expect(await offlineOnly('/public/ranking.php'), isA<PageLoadServerError>());

        handoff.errorToThrow = null; // the role was granted: the handoff is accepted
        expect(await online('/public/ranking.php'), isA<PageLoadOnline>());
        await Future<void>.delayed(Duration.zero);
        expect(await offlineOnly('/public/ranking.php'), isA<PageLoadOffline>());
      });

      test('a confirmed device (central ACTIVE) is not a lifted module: the refusal stands without any handoff', () async {
        handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
        await online('/public/ranking.php');
        // (SyncEngine.liftDevice touches only the device record: see access_refusals_test)
        expect(await offlineOnly('/public/ranking.php'), isA<PageLoadServerError>());
      });

      test('a 403 WITHOUT the module code (a firewall page, an unknown reason) blocks nothing and the copy is offered as before', () async {
        handoff.errorToThrow = _httpError(403, '<html>blocked by firewall</html>');
        final plan = await online('/public/ranking.php') as PageLoadServerError;
        expect(plan.refusal, isNull);
        expect(plan.hasSnapshot, isTrue);
        expect(await offlineOnly('/public/ranking.php'), isA<PageLoadOffline>());
      });

      test('400 invalid_path (a module the server does not know) blocks nothing', () async {
        handoff.errorToThrow = _httpError(400, {'error': 'invalid_path'});
        final plan = await online('/public/ranking.php') as PageLoadServerError;
        expect(plan.refusal, isNull);
        expect(await offlineOnly('/public/ranking.php'), isA<PageLoadOffline>());
      });

      // ---- device_not_authorized

      test('device_not_authorized + revoked: the DEVICE is refused, no copy is offered, and nothing is erased', () async {
        handoff.errorToThrow = _httpError(403, {'error': 'device_not_authorized', 'device_state': 'revoked'});
        final plan = await online('/public/dashboard.php') as PageLoadServerError;
        expect(plan.refusal, HandoffRefusal.device);
        expect(plan.hasSnapshot, isFalse);
        expect(plan.deviceState, 'revoked');
        expect(await reading.getPageDirectoryIfReady(parishId: 'p', userId: 'u', pagePath: '/public/dashboard.php'), isNotNull,
            reason: 'refusing is not erasing: erasing is the central server\'s own DEVICE_REVOKED');
      });

      test('every state that says "no" refuses every page of the device afterwards, offline too', () async {
        for (final state in ['revoked', 'parish_disabled', 'not_found', 'parish_mismatch']) {
          fakeStore.remove('refusal_device');
          handoff.errorToThrow = _httpError(403, {'error': 'device_not_authorized', 'device_state': state});
          await online('/public/dashboard.php');
          for (final page in ['/public/dashboard.php', '/public/ranking.php']) {
            final plan = await offlineOnly(page);
            expect(plan, isA<PageLoadServerError>(), reason: '$state / $page');
            expect((plan as PageLoadServerError).refusal, HandoffRefusal.device);
          }
        }
      });

      test('the record holds no token', () async {
        handoff.errorToThrow = _httpError(403, {'error': 'device_not_authorized', 'device_state': 'revoked'});
        await online('/public/dashboard.php');
        expect(fakeStore['refusal_device'], isNotNull);
        expect(fakeStore['refusal_device'], isNot(contains('device-token-A')));
      });

      test('an UNKNOWN device_state is not a revocation: nothing is remembered, no copy is offered this time', () async {
        handoff.errorToThrow = _httpError(403, {'error': 'device_not_authorized', 'device_state': 'something_new'});
        final plan = await online('/public/dashboard.php') as PageLoadServerError;
        expect(plan.refusal, isNull);
        expect(plan.hasSnapshot, isFalse, reason: 'the server said "not authorized": a copy is not offered on top of that');
        expect(fakeStore.containsKey('refusal_device'), isFalse);
        expect(await offlineOnly('/public/dashboard.php'), isA<PageLoadOffline>(), reason: 'and nothing stands in the way of the next start');
      });

      test('a missing device_state likewise', () async {
        handoff.errorToThrow = _httpError(403, {'error': 'device_not_authorized'});
        final plan = await online('/public/dashboard.php') as PageLoadServerError;
        expect(plan.refusal, isNull);
        expect(fakeStore.containsKey('refusal_device'), isFalse);
      });

      test('central_unavailable (503) is "could not check": the copy is shown, nothing is remembered', () async {
        handoff.errorToThrow = _httpError(503, {'error': 'device_not_authorized', 'device_state': 'central_unavailable'});
        final plan = await online('/public/dashboard.php');
        expect(plan, isA<PageLoadOffline>());
        expect((plan as PageLoadOffline).reason, OfflineReason.serverUnavailable);
        expect(fakeStore.containsKey('refusal_device'), isFalse);
      });

      test('a 401 of the handoff (the user\'s session) is not a refusal of the device or the module', () async {
        handoff.errorToThrow = _httpError(401, {'error': 'invalid_token'});
        final plan = await online('/public/dashboard.php') as PageLoadServerError;
        expect(plan.refusal, isNull);
        expect(fakeStore.keys.where((k) => k.startsWith('refusal_')), isEmpty);
      });

      // ---- the background probe (a copy is on screen)

      test('the probe that meets 403 forbidden reports an unambiguous refusal and blocks the module; an accepted probe lifts it', () async {
        handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
        final rejected = await c.probeOnline(parishId: 'p', userId: 'u', targetPath: '/public/ranking.php');
        expect(rejected, isA<OnlineProbeRejected>());
        expect((rejected as OnlineProbeRejected).error.refusal, HandoffRefusal.module);
        expect(await offlineOnly('/public/ranking.php'), isA<PageLoadServerError>());

        handoff.errorToThrow = null;
        expect(await c.probeOnline(parishId: 'p', userId: 'u', targetPath: '/public/ranking.php'), isA<OnlineProbeRecovered>());
        await Future<void>.delayed(Duration.zero);
        expect(await offlineOnly('/public/ranking.php'), isA<PageLoadOffline>());
      });


      // ---- a record that cannot be read is NOT "no refusal"

      group('a refusal that cannot be READ keeps the saved copy shut', () {
        // A coordinator with nothing in memory (a new process), over the same keystore.
        OfflinePageCoordinator restarted() => OfflinePageCoordinator(
              connectivityProbe: ConnectivityProbe(),
              captureService: SnapshotCaptureService(downloader: PageResourceDownloader(), store: reading),
              snapshotStore: reading,
              localServer: localServer,
              handoffService: handoff,
            );

        test('an unreadable device record: the copy is not opened, the plan says "cannot tell", nothing is erased', () async {
          failRefusalReads = true;
          final plan = await restarted().plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php', forceOffline: true);
          expect(plan, isA<PageLoadServerError>(), reason: 'was PageLoadOffline: the bug');
          final e = plan as PageLoadServerError;
          expect(e.refusal, HandoffRefusal.unknown);
          expect(e.hasSnapshot, isFalse);
          expect(e.statusCode, isNull, reason: 'it is not a reply of the server');
          expect(localServer.rootDirectory, isNull);
          expect(await reading.getPageDirectoryIfReady(parishId: 'p', userId: 'u', pagePath: '/public/dashboard.php'), isNotNull,
              reason: 'nothing is erased');
        });

        test('damaged text in the device record, or in the module record, is the same', () async {
          fakeStore['refusal_device'] = '{not json';
          var plan = await restarted().plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php', forceOffline: true);
          expect((plan as PageLoadServerError).refusal, HandoffRefusal.unknown);
          fakeStore.remove('refusal_device');
          fakeStore['refusal_modules'] = 'garbage';
          plan = await restarted().plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php', forceOffline: true);
          expect((plan as PageLoadServerError).refusal, HandoffRefusal.unknown);
        });

        test('a device token that cannot be read is "cannot tell" too (not "not activated")', () async {
          final broken = _TokenFailsHandoff();
          final plan = await OfflinePageCoordinator(
            connectivityProbe: ConnectivityProbe(),
            captureService: SnapshotCaptureService(downloader: PageResourceDownloader(), store: reading),
            snapshotStore: reading,
            localServer: localServer,
            handoffService: broken,
          ).plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php', forceOffline: true);
          expect((plan as PageLoadServerError).refusal, HandoffRefusal.unknown);
        });

        test('hasSavedCopy is false and savedCopyFact is unknown (the server decides), never "exists"', () async {
          failRefusalReads = true;
          final r = restarted();
          expect(await r.hasSavedCopy(parishId: 'p', userId: 'u', pagePath: '/public/dashboard.php'), isFalse);
          expect(await r.savedCopyFact(parishId: 'p', userId: 'u', pagePath: '/public/dashboard.php'), SavedCopyFact.unknown);
        });

        test('with a server that answers and accepts, the page opens online: the server is the authority', () async {
          failRefusalReads = true;
          final plan = await restarted().plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php');
          expect(plan, isA<PageLoadOnline>());
        });

        test('with no answer from the server the copy still stays shut (a failed handoff falls back to "cannot tell")', () async {
          failRefusalReads = true;
          handoff.errorToThrow = DioException(requestOptions: RequestOptions(path: '/x'), type: DioExceptionType.connectionError);
          final plan = await restarted().plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php');
          expect((plan as PageLoadServerError).refusal, HandoffRefusal.unknown);
        });

        test('it is a retry, not a verdict: once the keystore reads again the copy opens', () async {
          failRefusalReads = true;
          final r = restarted();
          expect(await r.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php', forceOffline: true), isA<PageLoadServerError>());
          failRefusalReads = false;
          expect(await r.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php', forceOffline: true), isA<PageLoadOffline>());
        });

        test('a standing refusal is reported as the refusal, not as "cannot tell", when both are possible', () async {
          handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
          await online('/public/ranking.php');
          fakeStore['refusal_device'] = 'garbage'; // the other record is damaged
          final plan = await offlineOnly('/public/ranking.php');
          expect((plan as PageLoadServerError).refusal, HandoffRefusal.module);
        });
      });

      // ---- a refusal that cannot be WRITTEN, or REMOVED

      group('a refusal that cannot be written still blocks in this process; one that cannot be removed is not lifted', () {
        test('device: the write fails, the block stands for the next attempts, offline, even with the keystore unreadable', () async {
          failRefusalWrites = true;
          handoff.errorToThrow = _httpError(403, {'error': 'device_not_authorized', 'device_state': 'revoked'});
          final first = await online('/public/dashboard.php') as PageLoadServerError;
          expect(first.refusal, HandoffRefusal.device);
          expect(fakeStore.containsKey('refusal_device'), isFalse, reason: 'nothing was stored');
          expect((await offlineOnly('/public/ranking.php') as PageLoadServerError).refusal, HandoffRefusal.device);
          failRefusalReads = true;
          expect((await offlineOnly('/public/ranking.php') as PageLoadServerError).refusal, HandoffRefusal.device);
        });

        test('device: no readable token at the time: the refusal still stands for this process', () async {
          final broken = _TokenFailsHandoff()
            ..errorToThrow = _httpError(403, {'error': 'device_not_authorized', 'device_state': 'revoked'});
          final cc = OfflinePageCoordinator(
            connectivityProbe: ConnectivityProbe(),
            captureService: SnapshotCaptureService(downloader: PageResourceDownloader(), store: reading),
            snapshotStore: reading,
            localServer: localServer,
            handoffService: broken,
          );
          final first = await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php') as PageLoadServerError;
          expect(first.refusal, HandoffRefusal.device);
          broken.errorToThrow = null;
          final later = await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php', forceOffline: true);
          expect((later as PageLoadServerError).refusal, HandoffRefusal.device);
        });

        test('module: the write fails, the block stands for the later attempts', () async {
          failRefusalWrites = true;
          handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
          expect((await online('/public/ranking.php') as PageLoadServerError).refusal, HandoffRefusal.module);
          expect((await offlineOnly('/public/ranking.php') as PageLoadServerError).refusal, HandoffRefusal.module);
          expect(await offlineOnly('/public/dashboard.php'), isA<PageLoadOffline>(), reason: 'other modules are not affected');
        });

        test('module: an accepted handoff whose lift FAILS leaves the block standing; the next accepted one lifts it', () async {
          handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
          await online('/public/ranking.php');
          handoff.errorToThrow = null; // accepted now
          failRefusalDeletes = true;
          expect(await online('/public/ranking.php'), isA<PageLoadOnline>());
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(await offlineOnly('/public/ranking.php'), isA<PageLoadServerError>(), reason: 'not lifted, and not reported as lifted');

          failRefusalDeletes = false;
          expect(await online('/public/ranking.php'), isA<PageLoadOnline>());
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(await offlineOnly('/public/ranking.php'), isA<PageLoadOffline>());
        });
      });

      // ---- the parish says no, the central server says ACTIVE (an old answer from the relay's cache)

      group('the parish refusal is checked against the central server before it becomes a block', () {
        OfflinePageCoordinator withVerifier(Future<DeviceAuthState?> Function() verify, {Duration timeout = const Duration(seconds: 3)}) =>
            OfflinePageCoordinator(
              connectivityProbe: ConnectivityProbe(),
              captureService: SnapshotCaptureService(downloader: PageResourceDownloader(), store: reading),
              snapshotStore: reading,
              localServer: localServer,
              handoffService: handoff,
              reverifyDevice: verify,
              reverifyTimeout: timeout,
            );

        void parishSaysRevoked() =>
            handoff.errorToThrow = _httpError(403, {'error': 'device_not_authorized', 'device_state': 'revoked'});

        test('central ACTIVE after the parish said "revoked": not blocked, no copy offered on that reply, and it says why', () async {
          final cc = withVerifier(() async => DeviceAuthState.active);
          parishSaysRevoked();
          final plan = await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php') as PageLoadServerError;
          expect(plan.refusal, isNull);
          expect(plan.staleParishAnswer, isTrue);
          expect(plan.hasSnapshot, isFalse, reason: 'the parish said "not authorized": a copy is not offered on top of that');
          expect(fakeStore.containsKey('refusal_device'), isFalse, reason: 'nothing was stored');
        });

        test('and it does not block the NEXT start either: the copy opens offline', () async {
          final cc = withVerifier(() async => DeviceAuthState.active);
          parishSaysRevoked();
          await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php');
          expect(await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php', forceOffline: true), isA<PageLoadOffline>());
        });

        test('every answer that is not ACTIVE leaves the refusal standing (a real, new refusal is never set aside)', () async {
          for (final answer in [DeviceAuthState.revoked, DeviceAuthState.parishDisabled, DeviceAuthState.tokenRejected,
              DeviceAuthState.refusalUnknown, DeviceAuthState.authError, DeviceAuthState.updateRequired,
              DeviceAuthState.offlineWithinLease, DeviceAuthState.offlineLeaseExpired, null]) {
            fakeStore.remove('refusal_device');
            final cc = withVerifier(() async => answer);
            parishSaysRevoked();
            final plan = await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php') as PageLoadServerError;
            expect(plan.refusal, HandoffRefusal.device, reason: '$answer');
            expect(plan.staleParishAnswer, isFalse, reason: '$answer');
            expect(fakeStore['refusal_device'], isNotNull, reason: '$answer');
          }
        });

        test('a verification that fails or does not answer in time leaves the refusal standing', () async {
          for (final verify in <Future<DeviceAuthState?> Function()>[
            () async => throw StateError('no network'),
            () => Completer<DeviceAuthState?>().future,
          ]) {
            fakeStore.remove('refusal_device');
            final cc = withVerifier(verify, timeout: const Duration(milliseconds: 50));
            parishSaysRevoked();
            final plan = await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php') as PageLoadServerError;
            expect(plan.refusal, HandoffRefusal.device);
          }
        });

        test('no way to verify (no verifier): the refusal stands, as before', () async {
          parishSaysRevoked();
          expect((await online('/public/dashboard.php') as PageLoadServerError).refusal, HandoffRefusal.device);
        });

        test('ORDER: refused, then lifted by a central ACTIVE, then the relay repeats its old answer: not blocked again; a real refusal after that blocks', () async {
          var central = DeviceAuthState.revoked;
          final cc = withVerifier(() async => central);
          parishSaysRevoked();
          expect((await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php') as PageLoadServerError).refusal,
              HandoffRefusal.device);
          // The central server now says ACTIVE (SyncEngine lifts the record).
          expect(await cc.refusals.liftDevice(deviceToken: 'device-token-A'), LiftResult.done);
          central = DeviceAuthState.active;
          // The relay still serves its cached "revoked".
          final again = await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php') as PageLoadServerError;
          expect(again.refusal, isNull);
          expect(again.staleParishAnswer, isTrue);
          expect(await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php', forceOffline: true), isA<PageLoadOffline>());
          // Then the central server really does refuse: the next parish refusal blocks.
          central = DeviceAuthState.tokenRejected;
          expect((await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php') as PageLoadServerError).refusal,
              HandoffRefusal.device);
        });

        test('a MODULE refusal is not put to the central server: ACTIVE says nothing about the user\'s role', () async {
          var asked = 0;
          final cc = withVerifier(() async {
            asked++;
            return DeviceAuthState.active;
          });
          handoff.errorToThrow = _httpError(403, {'error': 'forbidden'});
          expect((await cc.plan(parishId: 'p', userId: 'u', targetPath: '/public/ranking.php') as PageLoadServerError).refusal,
              HandoffRefusal.module);
          expect(asked, 0);
        });

        test('the probe goes through the same check', () async {
          final cc = withVerifier(() async => DeviceAuthState.active);
          parishSaysRevoked();
          final rejected = await cc.probeOnline(parishId: 'p', userId: 'u', targetPath: '/public/dashboard.php');
          expect((rejected as OnlineProbeRejected).error.staleParishAnswer, isTrue);
          expect(rejected.error.refusal, isNull);
        });
      });

      test('HandoffFailure keeps the device_state only when it is a short machine code', () {
        DioException withBody(Object body) => _httpError(403, body);
        expect(HandoffFailure.of(withBody({'error': 'device_not_authorized', 'device_state': 'revoked'})).deviceState, 'revoked');
        expect(HandoffFailure.of(withBody({'error': 'device_not_authorized', 'device_state': 'Revoked <b>'})).deviceState, isNull);
        expect(HandoffFailure.of(withBody({'error': 'x', 'device_state': 42})).deviceState, isNull);
        expect(HandoffFailure.of(withBody('plain')).deviceState, isNull);
      });
    });

    test('a plan that finds NO copy is NOT marked as timed out', () async {
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: _FakeHandoffService(SecureStorageService()),
      );
      final plan = await coordinator.plan(
        parishId: 'p',
        userId: 'u',
        targetPath: '/public/never-saved.php',
        forceOffline: true,
      );
      expect(plan, isA<PageLoadOfflineNoSnapshot>());
      expect((plan as PageLoadOfflineNoSnapshot).timedOut, isFalse);
    });

    test('REGRESSION: a listener that is dead and SLOW to refuse still yields the saved view inside the plan budget', () async {
      // Silent death: no end-of-stream, and the probe never answers (what a
      // connection to a dead port can look like on Windows). The repair is bounded,
      // so the plan (1.5 s in all) returns the copy and not "no saved copy".
      final slowServer = LocalSnapshotServer(
        encryptor: _testEncryptor,
        healthProbe: (_) => Completer<bool>().future,
      );
      addTearDown(slowServer.stop);
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: slowServer,
        handoffService: _FakeHandoffService(SecureStorageService()),
      );
      await store.writeSnapshot(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/ranking.php',
        html: '<html>Ranking</html>',
        assets: {},
      );
      await slowServer.start();

      final watch = Stopwatch()..start();
      final plan = await coordinator.plan(
        parishId: 'p',
        userId: 'u',
        targetPath: '/public/ranking.php',
        forceOffline: true,
      );

      expect(plan, isA<PageLoadOffline>(), reason: 'the copy exists; a slow repair must not turn it into "no copy"');
      expect(watch.elapsedMilliseconds, lessThan(1500));
    });

    test('warmUp starts the loopback server once, however many callers and however early', () async {
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: _FakeHandoffService(SecureStorageService()),
      );
      expect(localServer.isRunning, isFalse);
      await Future.wait([coordinator.warmUp(), coordinator.warmUp(), coordinator.warmUp()]);
      expect(localServer.isRunning, isTrue);
      final port = localServer.port;

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
      expect(localServer.port, port, reason: 'the plan reuses the warmed server');
      expect((plan as PageLoadOffline).url.port, port);
    });

    test('a failing warmUp never throws: the plan reports a real failure where it can be handled', () async {
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: _FailingServer(),
        handoffService: _FakeHandoffService(SecureStorageService()),
      );
      await coordinator.warmUp(); // completes normally
    });

    test('checkReachability asks the injected check about the given host', () async {
      String? asked;
      final coordinator = OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: captureService,
        snapshotStore: store,
        localServer: localServer,
        handoffService: _FakeHandoffService(SecureStorageService()),
        reachability: ServerReachability(
          connect: (host, port, {timeout}) {
            asked = '$host:$port';
            return Future<Socket>.error(
              SocketException('x', osError: OSError('Network is unreachable', 101)),
            );
          },
        ),
      );
      expect(await coordinator.checkReachability('szarlej.ministrant.eu'), Reachability.noRoute);
      expect(asked, 'szarlej.ministrant.eu:443');
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
        firstOnlineTimeout: const Duration(milliseconds: 100),
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
        expect((plan as PageLoadOfflineNoSnapshot).timedOut, isTrue, reason: 'it ran out of time: that is not "no copy"');
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

    group('a ticket is requested for the entry page, not for the page being opened', () {
      late _FakeHandoffService handoff;
      late OfflinePageCoordinator coordinator;

      setUp(() {
        handoff = _FakeHandoffService(SecureStorageService())
          ..handoffUrlToReturn = Uri.parse(
            'https://szarlej.ministrant.eu/public/mobile_handoff.php?ticket=t',
          );
        coordinator = OfflinePageCoordinator(
          connectivityProbe: ConnectivityProbe(),
          captureService: captureService,
          snapshotStore: store,
          localServer: localServer,
          handoffService: handoff,
        );
      });

      test('the server is asked about the entry page; the plan is for the page the user is opening', () async {
        final plan = await coordinator.plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/schedule.php?month=11',
          handoffPath: '/public/dashboard.php',
        );

        // schedule.php is linked from the panel but not in the server's
        // handoff allowlist; asking for a ticket for it is a 400.
        expect(handoff.lastPath, '/public/dashboard.php');
        expect(plan, isA<PageLoadOnline>());
        expect((plan as PageLoadOnline).targetPath, '/public/schedule.php?month=11');
      });

      test('without handoffPath the page itself is requested, as before', () async {
        await coordinator.plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/ranking.php',
        );
        expect(handoff.lastPath, '/public/ranking.php');
      });

      test('an unusable handoffPath falls back to the page itself instead of failing', () async {
        await coordinator.plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/ranking.php',
          handoffPath: '/public/login.php',
        );
        expect(handoff.lastPath, '/public/ranking.php');
      });

      test('offline, the copy of the page being opened is used - not the entry page\'s', () async {
        for (final page in ['/public/dashboard.php', '/public/schedule.php']) {
          await store.writeSnapshot(
            parishId: 'p',
            userId: 'u',
            pagePath: page,
            html: '<html>$page</html>',
            assets: {},
          );
        }
        handoff.errorToThrow = TimeoutException('down');

        final plan = await coordinator.plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/schedule.php',
          handoffPath: '/public/dashboard.php',
        );

        expect(plan, isA<PageLoadOffline>());
        final scheduleDir = await store.getPageDirectoryIfReady(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/schedule.php',
        );
        expect(localServer.rootDirectory?.path, scheduleDir!.path);
      });

      test('a refusal names the path that was actually requested', () async {
        handoff.errorToThrow = _httpError(400, {'error': 'invalid_path'});

        final plan = await coordinator.plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/schedule.php',
          handoffPath: '/public/dashboard.php',
        );

        expect(plan, isA<PageLoadServerError>());
        expect((plan as PageLoadServerError).path, '/public/dashboard.php');
      });
    });

    group('probeOnline (background check that the connection is back)', () {
      late _FakeHandoffService handoff;
      late OfflinePageCoordinator coordinator;

      setUp(() {
        handoff = _FakeHandoffService(SecureStorageService());
        coordinator = OfflinePageCoordinator(
          connectivityProbe: ConnectivityProbe(),
          captureService: captureService,
          snapshotStore: store,
          localServer: localServer,
          handoffService: handoff,
        );
      });

      Future<OnlineProbeResult> probe({Duration? timeout}) =>
          coordinator.probeOnline(
            parishId: 'p',
            userId: 'u',
            targetPath: '/public/dashboard.php',
            timeout: timeout ?? const Duration(seconds: 6),
          );

      test('a ticket means recovered, and it uses the longer limit, not the opening one', () async {
        handoff.handoffUrlToReturn = Uri.parse(
          'https://szarlej.ministrant.eu/public/mobile_handoff.php?ticket=t',
        );
        final result = await probe();

        expect(result, isA<OnlineProbeRecovered>());
        final plan = (result as OnlineProbeRecovered).plan;
        expect(plan.targetPath, '/public/dashboard.php');
        expect(handoff.lastTimeout, const Duration(seconds: 6));
        expect(
          handoff.lastTimeout,
          greaterThan(WebviewHandoffService.defaultTimeout),
          reason: 'a slow server must be told apart from a missing one',
        );
      });

      test('no answer and transient server problems mean "try later", never a refusal', () async {
        final request = RequestOptions(path: '/x');
        for (final error in <Object>[
          DioException(requestOptions: request, type: DioExceptionType.connectionError),
          TimeoutException('slow'),
          _httpError(503),
          _httpError(429),
        ]) {
          handoff.errorToThrow = error;
          expect(await probe(), isA<OnlineProbeUnavailable>(), reason: '$error');
        }
      });

      test('a refusal is reported as one, with the sanitized facts and whether a copy exists', () async {
        await store.writeSnapshot(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/dashboard.php',
          html: '<html>Saved</html>',
          assets: {},
        );
        handoff.errorToThrow = _httpError(401, {'error': 'session_expired'});

        final result = await probe();

        expect(result, isA<OnlineProbeRejected>());
        final error = (result as OnlineProbeRejected).error;
        expect(error.statusCode, 401);
        expect(error.errorCode, 'session_expired');
        expect(error.hasSnapshot, isTrue);
      });

      test('a request that never answers still ends, after the limit', () async {
        handoff.hang = true;
        final clock = Stopwatch()..start();
        final result = await probe(timeout: const Duration(milliseconds: 100));
        expect(result, isA<OnlineProbeUnavailable>());
        expect(clock.elapsedMilliseconds, lessThan(1500));
      });

      test('concurrent checks for the same page share ONE request', () async {
        handoff.handoffUrlToReturn = Uri.parse(
          'https://szarlej.ministrant.eu/public/mobile_handoff.php?ticket=t',
        );
        handoff.gate = Completer<void>();

        final a = probe();
        final b = probe();
        final c = probe();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(handoff.calls, 1, reason: 'three callers, one request');

        handoff.gate!.complete();
        final results = await Future.wait([a, b, c]);
        expect(results.every((r) => r is OnlineProbeRecovered), isTrue);
        expect(handoff.calls, 1);

        // Once it has finished, the next check is a fresh request.
        handoff.gate = null;
        await probe();
        expect(handoff.calls, 2);
      });

      test('a page the app cannot identify is "unavailable", not a request', () async {
        final result = await coordinator.probeOnline(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/login.php',
        );
        expect(result, isA<OnlineProbeUnavailable>());
        expect(handoff.calls, 0);
      });
    });

    group('handoff failure classes', () {
      OfflinePageCoordinator coordinatorFailingWith(Object error) {
        final handoff = _FakeHandoffService(SecureStorageService())
          ..errorToThrow = error;
        return OfflinePageCoordinator(
          connectivityProbe: ConnectivityProbe(),
          captureService: captureService,
          snapshotStore: store,
          localServer: localServer,
          handoffService: handoff,
        );
      }

      // The snapshot key includes the query, so tests that expect a saved
      // copy use the plain path; the query-stripping test passes its own.
      Future<PageLoadPlan> plan(
        OfflinePageCoordinator c, {
        String target = '/public/dashboard.php',
      }) => c.plan(parishId: 'p', userId: 'u', targetPath: target);

      Future<void> saveDashboard() => store.writeSnapshot(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/dashboard.php',
        html: '<html>Saved</html>',
        assets: {},
      );

      test('a server that ANSWERED 400 is a server error, not "offline" - the refused path and code survive', () async {
        final result = await plan(
          coordinatorFailingWith(
            _httpError(400, {
              'error': 'invalid_path',
              'message': 'Nieznana lub niedozwolona ścieżka modułu.',
            }),
          ),
          target: '/public/dashboard.php?month=10',
        );

        expect(result, isA<PageLoadServerError>());
        final error = result as PageLoadServerError;
        expect(error.statusCode, 400);
        expect(error.errorCode, 'invalid_path');
        // The page path only: no query (it can carry filters/ids).
        expect(error.path, '/public/dashboard.php');
        expect(error.hasSnapshot, isFalse);
        expect(localServer.isRunning, isFalse, reason: 'no snapshot was served');
      });

      test('with a saved copy it is STILL a server error, and says a copy exists', () async {
        await saveDashboard();
        final result = await plan(
          coordinatorFailingWith(_httpError(400, {'error': 'invalid_path'})),
        );

        expect(result, isA<PageLoadServerError>());
        expect((result as PageLoadServerError).hasSnapshot, isTrue);
      });

      test('401 and 403 are server errors that keep their status', () async {
        for (final status in [401, 403, 404, 422]) {
          final result = await plan(coordinatorFailingWith(_httpError(status)));
          expect(result, isA<PageLoadServerError>(), reason: '$status');
          expect((result as PageLoadServerError).statusCode, status);
        }
      });

      test('only a short machine code is kept - never a message, markup or a long string', () async {
        for (final hostile in <Object?>[
          '<script>alert(1)</script>',
          'Ticket abc123 for user 42',
          'a' * 100,
          'Invalid_Path',
          '',
          42,
          null,
        ]) {
          final result = await plan(
            coordinatorFailingWith(
              _httpError(400, {
                'error': hostile,
                'message': 'secret message that must not surface',
              }),
            ),
          ) as PageLoadServerError;
          expect(result.errorCode, isNull, reason: '$hostile');
          expect(result.statusCode, 400);
        }
        // A body that is not JSON at all (an HTML error page).
        final html = await plan(
          coordinatorFailingWith(_httpError(400, '<html>Bad gateway</html>')),
        ) as PageLoadServerError;
        expect(html.errorCode, isNull);
      });

      test('a reply that is not a handoff reply at all is a server error, not "offline"', () async {
        final result = await plan(
          coordinatorFailingWith(const FormatException('Invalid handoff response.')),
        ) as PageLoadServerError;
        expect(result.statusCode, isNull);
        expect(result.errorCode, 'invalid_response');
      });

      test('a defect in this app (TypeError) is never presented as the server refusing', () async {
        await saveDashboard();
        // Produced the way they occur for real, not by constructing them.
        Object failedCast() {
          try {
            final Object? value = 5;
            return value as String;
          } catch (e) {
            return e;
          }
        }

        Object missingMethod() {
          try {
            final dynamic value = 5;
            return value.noSuchMethodHere();
          } catch (e) {
            return e;
          }
        }

        for (final error in <Object>[
          failedCast(),
          missingMethod(),
          StateError('not activated'),
        ]) {
          final result = await plan(coordinatorFailingWith(error));
          expect(result, isA<PageLoadOffline>(), reason: '${error.runtimeType}');
        }
      });

      test('5xx / 408 / 429 fall back to the saved copy, labelled as a server problem', () async {
        await saveDashboard();
        for (final status in [500, 502, 503, 408, 429]) {
          final result = await plan(coordinatorFailingWith(_httpError(status)));
          expect(result, isA<PageLoadOffline>(), reason: '$status');
          expect(
            (result as PageLoadOffline).reason,
            OfflineReason.serverUnavailable,
            reason: '$status',
          );
        }
      });

      test('5xx with no saved copy is the ordinary "no saved copy" state', () async {
        final result = await plan(coordinatorFailingWith(_httpError(503)));
        expect(result, isA<PageLoadOfflineNoSnapshot>());
      });

      test('no answer at all (connection, timeout, socket) is "no network"', () async {
        await saveDashboard();
        final request = RequestOptions(path: '/mobile/webview/handoff');
        for (final error in <Object>[
          DioException(requestOptions: request, type: DioExceptionType.connectionError),
          DioException(requestOptions: request, type: DioExceptionType.connectionTimeout),
          DioException(requestOptions: request, type: DioExceptionType.cancel),
          TimeoutException('handoff'),
          const SocketException('Failed host lookup'),
        ]) {
          final result = await plan(coordinatorFailingWith(error));
          expect(result, isA<PageLoadOffline>(), reason: '$error');
          expect(
            (result as PageLoadOffline).reason,
            OfflineReason.noNetwork,
            reason: '$error',
          );
        }
      });

      test('a forced fallback keeps the reason its caller gives (a slow page is not "offline")', () async {
        await saveDashboard();
        final result = await coordinatorFailingWith(Exception('unused')).plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/dashboard.php',
          forceOffline: true,
          offlineReason: OfflineReason.slowServer,
        );
        expect(result, isA<PageLoadOffline>());
        expect((result as PageLoadOffline).reason, OfflineReason.slowServer);
      });

      test('a reason handed in does not survive a fresh failure of another kind', () async {
        await saveDashboard();
        final request = RequestOptions(path: '/x');
        final noAnswer = await coordinatorFailingWith(
          DioException(requestOptions: request, type: DioExceptionType.connectionError),
        ).plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/dashboard.php',
          offlineReason: OfflineReason.slowServer,
        );
        expect((noAnswer as PageLoadOffline).reason, OfflineReason.noNetwork);

        final serverDown = await coordinatorFailingWith(_httpError(503)).plan(
          parishId: 'p',
          userId: 'u',
          targetPath: '/public/dashboard.php',
          offlineReason: OfflineReason.noNetwork,
        );
        expect((serverDown as PageLoadOffline).reason, OfflineReason.serverUnavailable);
      });

      test('the banner says SERWER NIEDOSTĘPNY for a server problem and OFFLINE otherwise', () {
        expect(
          formatOfflineBannerText(
            DateTime.utc(2026, 10, 1, 8, 42),
            reason: OfflineReason.slowServer,
          ),
          startsWith('SERWER ODPOWIADA ZBYT WOLNO • ostatnia synchronizacja: '),
        );
        final captured = DateTime.utc(2026, 10, 1, 8, 42);
        expect(
          formatOfflineBannerText(captured, reason: OfflineReason.serverUnavailable),
          startsWith('SERWER NIEDOSTĘPNY • ostatnia synchronizacja: '),
        );
        expect(
          formatOfflineBannerText(captured),
          startsWith('OFFLINE • ostatnia synchronizacja: '),
        );
      });
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

    group('the saved copy is decrypted ahead of time', () {
      late OfflinePageCoordinator coordinator;

      setUp(() {
        coordinator = OfflinePageCoordinator(
          connectivityProbe: ConnectivityProbe(),
          captureService: captureService,
          snapshotStore: store,
          localServer: localServer,
          handoffService: _FakeHandoffService(SecureStorageService()),
        );
      });

      test('prewarmPage puts every file of the page into the server\'s memory', () async {
        await store.writeSnapshot(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/ranking.php',
          html: '<html>Ranking</html>',
          assets: {'public/css/style.css': utf8.encode('body{}')},
        );
        final dir = await store.getPageDirectoryIfReady(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php');

        await coordinator.prewarmPage(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php');

        expect(localServer.hasDecrypted(File('${dir!.path}/snapshot.html')), isTrue);
        expect(localServer.hasDecrypted(File('${dir.path}/assets/public/css/style.css')), isTrue);
      });

      test('WRITE-THROUGH is wired: a page that was just captured is already in memory, nothing prewarmed it', () async {
        await store.writeSnapshot(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/ranking.php',
          html: '<html>Ranking</html>',
          assets: {'public/css/style.css': utf8.encode('body{}')},
        );
        final dir = await store.getPageDirectoryIfReady(parishId: 'p', userId: 'u', pagePath: '/public/ranking.php');
        await Future<void>.delayed(const Duration(milliseconds: 100)); // remember() is not awaited by the store

        expect(localServer.hasDecrypted(File('${dir!.path}/snapshot.html')), isTrue);
        expect(localServer.hasDecrypted(File('${dir.path}/assets/public/css/style.css')), isTrue);
      });

      test('prewarmEntryPage before any activation or sign-in does nothing and does not throw', () async {
        await coordinator.prewarmEntryPage();
      });

      test('prewarmPage for a page that was never saved is silent', () async {
        await coordinator.prewarmPage(parishId: 'p', userId: 'u', pagePath: '/public/never-saved.php');
      });

      test('planning the offline view decrypts nothing: that happens when the page is requested', () async {
        await store.writeSnapshot(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/ranking.php',
          html: '<html>Ranking</html>',
          assets: {},
        );
        final lines = <String>[];
        localServer.trace = lines.add;
        await coordinator.plan(parishId: 'p', userId: 'u', targetPath: '/public/ranking.php', forceOffline: true);
        expect(lines, isEmpty, reason: 'the server served and decrypted nothing during planning');
      });
    });

    group('captures of one page do not pile up (F8)', () {
      late _CountingCapture counting;
      late OfflinePageCoordinator coordinator;

      setUp(() {
        fakeStore['server_url'] = 'https://szarlej.ministrant.eu';
        counting = _CountingCapture(store);
        coordinator = OfflinePageCoordinator(
          connectivityProbe: ConnectivityProbe(),
          captureService: counting,
          snapshotStore: store,
          localServer: localServer,
          handoffService: _FakeHandoffService(SecureStorageService()),
        );
      });

      void capture(String html, {String path = '/public/dashboard.php'}) =>
          coordinator.captureInBackground(
            parishId: 'p',
            userId: 'u',
            targetPath: path,
            renderedHtml: html,
          );

      test('captures of the same page queued together: only the NEWEST runs', () async {
        capture('first');
        capture('second');
        capture('third');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(counting.htmls, ['third']);
      });

      test('one that is already RUNNING finishes; the newer one waits, the middle one is skipped', () async {
        counting.gate = Completer<void>();
        capture('first');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(counting.htmls, ['first'], reason: 'running, held at the gate');

        capture('second');
        capture('third');
        counting.gate!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(counting.htmls, ['first', 'third']);
      });

      test('different pages are never merged', () async {
        capture('a', path: '/public/dashboard.php');
        capture('b', path: '/public/ranking.php');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(counting.htmls, ['a', 'b']);
      });

      test('how a capture ended is published, and kept', () async {
        counting.outcome = const CaptureOutcome(
          CaptureStatus.rejectedIncomplete,
          missingCritical: ['public/css/style.css'],
        );
        final published = coordinator.captureOutcomes.first;
        capture('x');
        final outcome = await published.timeout(const Duration(seconds: 2));
        expect(outcome.status, CaptureStatus.rejectedIncomplete);
        expect(outcome.missingCritical, ['public/css/style.css']);
        expect(coordinator.lastCaptureOutcome, same(outcome));
      });
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
