import 'package:flutter/material.dart';
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
import 'package:ministrant_manager/features/webview/offline_aware_page_screen.dart';
import 'package:ministrant_manager/features/webview/webview_handoff_service.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewWidget;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Screen-LOGIC tests only. A fake WebViewPlatform replaces Chromium /
/// WKWebView, so these check what OfflineAwarePageScreen decides and when
/// (timers, overlay, mounting, stale results) — NOT that a real browser
/// engine renders anything. Real rendering, cold start with the radios
/// off, and the 2 s target still need a device.

// ---------------------------------------------------------------------------
// Fake platform (signatures taken from webview_flutter_platform_interface
// 2.15.1, the version pinned in pubspec.lock).
// ---------------------------------------------------------------------------

class _FakePlatform extends WebViewPlatform {
  final controllers = <_FakeController>[];
  final delegates = <_FakeDelegate>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _FakeController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    final delegate = _FakeDelegate(params);
    delegates.add(delegate);
    return delegate;
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWidget(params);
}

class _FakeController extends PlatformWebViewController {
  _FakeController(PlatformWebViewControllerCreationParams params)
    : super.implementation(params);

  /// Whether the web view widget was already part of the tree.
  bool attached = false;

  /// For every loadRequest: was the widget attached at that moment?
  final attachedAtLoad = <bool>[];
  final loaded = <Uri>[];

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    attachedAtLoad.add(attached);
    loaded.add(params.uri);
  }

  /// Every script the screen ran (to see e.g. that a page capture was asked for).
  final scripts = <String>[];

  @override
  Future<void> runJavaScript(String javaScript) async {
    scripts.add(javaScript);
  }

  /// What the "unsaved input" check on the page answers; [jsThrows] makes
  /// the check itself fail.
  Object jsResult = false;
  bool jsThrows = false;
  int jsChecks = 0;

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    jsChecks++;
    if (jsThrows) throw StateError('no page');
    return jsResult;
  }

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<void> goBack() async {}

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {}

  @override
  Future<void> clearCache() async {}

  @override
  Future<void> clearLocalStorage() async {}
}

class _FakeDelegate extends PlatformNavigationDelegate {
  _FakeDelegate(PlatformNavigationDelegateCreationParams params)
    : super.implementation(params);

  PageEventCallback? onPageFinished;
  NavigationRequestCallback? onNavigationRequest;
  WebResourceErrorCallback? onWebResourceError;
  HttpResponseErrorCallback? onHttpError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    this.onNavigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {
    this.onHttpError = onHttpError;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {
    this.onWebResourceError = onWebResourceError;
  }
}

class _FakeWidget extends PlatformWebViewWidget {
  _FakeWidget(PlatformWebViewWidgetCreationParams params)
    : super.implementation(params);

  @override
  Widget build(BuildContext context) {
    (params.controller as _FakeController).attached = true;
    return const SizedBox.expand(key: Key('fake-web-view'));
  }
}

// ---------------------------------------------------------------------------
// Coordinator whose plan() is scripted; everything else is the real class
// (never touched: nothing here reads the store or starts the server).
// ---------------------------------------------------------------------------

final _encryptor = SnapshotEncryptor(hexKey: 'a' * 64);

/// Owns every fake loopback URL, as the real server does while its root is
/// unchanged. Without it the screen would drop ALL offline callbacks and
/// the late-callback tests below would pass vacuously.
class _OwnedServer extends LocalSnapshotServer {
  _OwnedServer() : super(encryptor: _encryptor);

  @override
  bool ownsUrl(Uri uri) =>
      uri.scheme == 'http' &&
      uri.host == '127.0.0.1' &&
      uri.path.startsWith('/token/');
}

class _ScriptedCoordinator extends OfflinePageCoordinator {
  factory _ScriptedCoordinator(
    Future<PageLoadPlan> Function(bool forceOffline) script, {
    Future<OnlineProbeResult> Function(int call)? probe,
  }) => _ScriptedCoordinator._(
    SnapshotStore(encryptor: _encryptor),
    script,
    probe ?? (_) async => const OnlineProbeUnavailable(),
  );

  _ScriptedCoordinator._(SnapshotStore store, this.script, this.probeScript)
    : super(
        connectivityProbe: ConnectivityProbe(),
        captureService: SnapshotCaptureService(
          downloader: PageResourceDownloader(),
          store: store,
        ),
        snapshotStore: store,
        localServer: _OwnedServer(),
        handoffService: WebviewHandoffService(
          api: ApiClient(SecureStorageService()),
          secureStorage: SecureStorageService(),
        ),
      );

  final Future<PageLoadPlan> Function(bool forceOffline) script;
  final Future<OnlineProbeResult> Function(int call) probeScript;
  int planCalls = 0;
  int probeCalls = 0;
  final probeTargets = <String>[];

  @override
  Future<OnlineProbeResult> probeOnline({
    required String parishId,
    required String userId,
    required String targetPath,
    Duration timeout = const Duration(seconds: 6),
  }) {
    probeCalls++;
    probeTargets.add(targetPath);
    return probeScript(probeCalls);
  }

  /// (page being opened, page a ticket was requested for) per plan() call.
  final planRequests = <(String, String?)>[];
  final planReasons = <OfflineReason>[];

  @override
  Future<PageLoadPlan> plan({
    required String parishId,
    required String userId,
    required String targetPath,
    String? handoffPath,
    bool forceOffline = false,
    OfflineReason offlineReason = OfflineReason.noNetwork,
  }) {
    planCalls++;
    planRequests.add((targetPath, handoffPath));
    planReasons.add(offlineReason);
    // Like the real coordinator: a forced fallback carries the reason the
    // caller gave, so the screen's own bookkeeping of it can be observed.
    return script(forceOffline).then(
      (plan) => plan is PageLoadOffline && forceOffline
          ? PageLoadOffline(
              url: plan.url,
              capturedAt: plan.capturedAt,
              reason: offlineReason,
            )
          : plan,
    );
  }
}

final _localUrl = Uri.parse('http://127.0.0.1:1/token/snapshot.html');
final _ticketUrl = Uri.parse(
  'https://szarlej.ministrant.eu/public/mobile_handoff.php?ticket=t',
);

/// What the real server does: every offline plan gets a fresh access token,
/// which is part of the document URL's PATH.
Uri _localUrlN(int n) => Uri.parse('http://127.0.0.1:1/token/$n/snapshot.html');

PageLoadOffline _offlinePlan([Uri? url]) => PageLoadOffline(
  url: url ?? _localUrl,
  capturedAt: DateTime.utc(2026, 10, 1, 8),
);

PageLoadOnline _onlinePlan() =>
    PageLoadOnline(url: _ticketUrl, targetPath: '/public/dashboard.php');

Widget _host(
  OfflinePageCoordinator coordinator, {
  Future<void> Function()? onLogout,
  bool forceOffline = false,
}) => MaterialApp(
  home: OfflineAwarePageScreen(
    title: 'Panel',
    targetPath: '/public/dashboard.php',
    allowedHost: 'szarlej.ministrant.eu',
    parishId: 'p',
    userId: 'u',
    coordinator: coordinator,
    onLogout: onLogout,
    forceOffline: forceOffline,
  ),
);

PageLoadServerError _serverError(
  int? status, {
  String? code = 'invalid_path',
  bool hasSnapshot = false,
}) => PageLoadServerError(
  statusCode: status,
  errorCode: code,
  path: '/public/dashboard.php',
  hasSnapshot: hasSnapshot,
);

Future<OnlineProbeResult> _after5s(OnlineProbeResult result) async {
  await Future<void>.delayed(const Duration(seconds: 5));
  return result;
}

Future<OnlineProbeResult> _after3s(OnlineProbeResult result) async {
  await Future<void>.delayed(const Duration(seconds: 3));
  return result;
}

Future<OnlineProbeResult> _after20s() async {
  await Future<void>.delayed(const Duration(seconds: 20));
  return const OnlineProbeUnavailable();
}

Future<PageLoadPlan> _after(Duration delay, PageLoadPlan plan) async {
  await Future<void>.delayed(delay);
  return plan;
}

void main() {
  late _FakePlatform platform;

  setUp(() {
    platform = _FakePlatform();
    WebViewPlatform.instance = platform;
  });

  const spinner = CircularProgressIndicator;

  testWidgets('the web view is attached BEFORE the first navigation', (
    tester,
  ) async {
    final coordinator = _ScriptedCoordinator((_) async => _offlinePlan());
    await tester.pumpWidget(_host(coordinator));
    await tester.pump(const Duration(milliseconds: 1));

    final controller = platform.controllers.single;
    expect(controller.loaded, [_localUrl]);
    expect(
      controller.attachedAtLoad,
      [true],
      reason: 'loadRequest must run against a mounted web view',
    );
  });

  testWidgets('the web view stays mounted while loading and on error', (
    tester,
  ) async {
    final coordinator = _ScriptedCoordinator(
      (_) => _after(const Duration(milliseconds: 100), _offlinePlan()),
    );
    await tester.pumpWidget(_host(coordinator));

    expect(find.byType(spinner), findsOneWidget);
    expect(find.byType(WebViewWidget), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2001));
    expect(find.byType(spinner), findsNothing);
    expect(find.text('SPRÓBUJ PONOWNIE'), findsOneWidget);
    expect(find.byType(WebViewWidget), findsOneWidget);
  });

  testWidgets(
    'offline total deadline is absolute: 1400 ms of planning leaves no spinner at 2001 ms',
    (tester) async {
      final coordinator = _ScriptedCoordinator(
        (_) => _after(const Duration(milliseconds: 1400), _offlinePlan()),
      );
      await tester.pumpWidget(_host(coordinator));

      await tester.pump(const Duration(milliseconds: 1400));
      expect(
        find.byType(spinner),
        findsOneWidget,
        reason: 'plan finished, the local page has not reported finished yet',
      );
      expect(platform.controllers.single.loaded, [_localUrl]);

      await tester.pump(const Duration(milliseconds: 601)); // t = 2001 ms
      expect(find.byType(spinner), findsNothing);
      expect(find.textContaining('nie otworzyła się na czas'), findsOneWidget);
    },
  );

  testWidgets(
    'a plan that completes AFTER the deadline cannot bring the abandoned load back',
    (tester) async {
      final coordinator = _ScriptedCoordinator(
        (_) => _after(const Duration(milliseconds: 2500), _offlinePlan()),
      );
      await tester.pumpWidget(_host(coordinator));

      await tester.pump(const Duration(milliseconds: 2001));
      expect(find.textContaining('nie otworzyła się na czas'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 600)); // plan resolves
      expect(
        platform.controllers.single.loaded,
        isEmpty,
        reason: 'the late plan must not start a navigation',
      );
      expect(find.textContaining('nie otworzyła się na czas'), findsOneWidget);
      expect(find.byType(spinner), findsNothing);
    },
  );

  testWidgets(
    'once a handoff ticket exists the 2 s offline budget no longer applies; the page gets its own budget, then falls back',
    (tester) async {
      final coordinator = _ScriptedCoordinator(
        (forceOffline) async =>
            forceOffline ? const PageLoadOfflineNoSnapshot() : _onlinePlan(),
      );
      await tester.pumpWidget(_host(coordinator));
      await tester.pump(const Duration(milliseconds: 1));
      expect(platform.controllers.single.loaded, [_ticketUrl]);

      await tester.pump(const Duration(seconds: 3));
      expect(
        find.byType(spinner),
        findsOneWidget,
        reason: 'a slow but reachable page is not "offline"',
      );

      await tester.pump(const Duration(seconds: 5, milliseconds: 1)); // > 8 s
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(spinner), findsNothing);
      expect(find.textContaining('Brak zapisanej wersji'), findsOneWidget);
      expect(coordinator.planCalls, 2, reason: 'online attempt + offline fallback');
    },
  );

  testWidgets(
    'a late offline page-finished callback cannot revive an expired load',
    (tester) async {
      final coordinator = _ScriptedCoordinator((_) async => _offlinePlan());
      await tester.pumpWidget(_host(coordinator));
      await tester.pump(const Duration(milliseconds: 1));
      expect(platform.controllers.single.loaded, [_localUrl]);

      await tester.pump(const Duration(milliseconds: 2001));
      expect(find.textContaining('nie otworzyła się na czas'), findsOneWidget);

      platform.delegates.single.onPageFinished!(_localUrl.toString());
      await tester.pump();

      expect(
        find.textContaining('nie otworzyła się na czas'),
        findsOneWidget,
        reason: 'An expired navigation must not return to ready on a late callback',
      );
      expect(find.byType(spinner), findsNothing);
    },
  );

  testWidgets('retry after an expired load opens the page when it finishes', (
    tester,
  ) async {
    final coordinator = _ScriptedCoordinator((_) async => _offlinePlan());
    await tester.pumpWidget(_host(coordinator));
    await tester.pump(const Duration(milliseconds: 2002));
    expect(find.text('SPRÓBUJ PONOWNIE'), findsOneWidget);

    await tester.tap(find.text('SPRÓBUJ PONOWNIE'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(platform.controllers.single.loaded, [_localUrl, _localUrl]);
    expect(find.byType(spinner), findsOneWidget);

    platform.delegates.single.onPageFinished!(_localUrl.toString());
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.byType(spinner), findsNothing);
    expect(find.text('SPRÓBUJ PONOWNIE'), findsNothing);
    // The retry's own deadline is gone: nothing flips the page afterwards.
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('SPRÓBUJ PONOWNIE'), findsNothing);
  });

  testWidgets(
    "the screen itself rejects a late callback from the PRECEDING navigation (not only ownsUrl)",
    (tester) async {
      var plans = 0;
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(_localUrlN(++plans)),
      );
      await tester.pumpWidget(_host(coordinator));
      await tester.pump(const Duration(milliseconds: 2002)); // load #1 expired
      expect(find.text('SPRÓBUJ PONOWNIE'), findsOneWidget);

      await tester.tap(find.text('SPRÓBUJ PONOWNIE'));
      await tester.pump(const Duration(milliseconds: 1)); // load #2 started
      expect(platform.controllers.single.loaded, [
        _localUrlN(1),
        _localUrlN(2),
      ]);

      // The engine finally finishes the navigation the screen abandoned.
      platform.delegates.single.onPageFinished!(_localUrlN(1).toString());
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        find.byType(spinner),
        findsOneWidget,
        reason: 'load #2 is still pending; load #1 finishing is not its result',
      );

      // Load #2's own callback does finish it.
      platform.delegates.single.onPageFinished!(_localUrlN(2).toString());
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(spinner), findsNothing);
      expect(find.text('SPRÓBUJ PONOWNIE'), findsNothing);
    },
  );

  testWidgets(
    'an online page the screen already gave up on cannot finish during the offline fallback',
    (tester) async {
      final coordinator = _ScriptedCoordinator(
        (forceOffline) => forceOffline
            ? _after(
                const Duration(milliseconds: 500),
                const PageLoadOfflineNoSnapshot(),
              )
            : Future.value(_onlinePlan()),
      );
      await tester.pumpWidget(_host(coordinator));
      await tester.pump(const Duration(milliseconds: 1)); // ticket, loading
      await tester.pump(const Duration(seconds: 8, milliseconds: 10));
      // The 8 s page budget expired; the offline fallback is now planning.
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(spinner), findsOneWidget);

      // The slow online page finally finishes — it was already abandoned.
      platform.delegates.single.onPageFinished!(
        'https://szarlej.ministrant.eu/public/dashboard.php',
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        find.byType(spinner),
        findsOneWidget,
        reason: 'must not flip to ready while the fallback plan is running',
      );

      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('Brak zapisanej wersji'), findsOneWidget);
    },
  );

  testWidgets(
    'a server that answered shows what it said - not the offline screen, and nothing keeps running',
    (tester) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _serverError(400),
      );
      await tester.pumpWidget(_host(coordinator));
      await tester.pump(const Duration(milliseconds: 1));

      expect(find.byType(spinner), findsNothing);
      expect(
        find.textContaining('Połączenie z serwerem działa'),
        findsOneWidget,
      );
      expect(
        find.textContaining('HTTP 400 · invalid_path · /public/dashboard.php'),
        findsOneWidget,
      );
      // A Wi-Fi-off icon and an OFFLINE banner would contradict the message.
      expect(find.byIcon(Icons.wifi_off), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.textContaining('OFFLINE'), findsNothing);
      expect(platform.controllers.single.loaded, isEmpty);
      expect(find.text('OTWÓRZ ZAPISANĄ KOPIĘ'), findsNothing);
      expect(find.text('ZALOGUJ PONOWNIE'), findsNothing);

      // No deadline from the abandoned wait may flip this later.
      await tester.pump(const Duration(seconds: 10));
      expect(find.textContaining('nie otworzyła się na czas'), findsNothing);
      expect(find.textContaining('Połączenie z serwerem działa'), findsOneWidget);
    },
  );

  testWidgets(
    'with a saved copy the user can open it explicitly, labelled OFFLINE only then',
    (tester) async {
      final coordinator = _ScriptedCoordinator(
        (forceOffline) async =>
            forceOffline ? _offlinePlan() : _serverError(400, hasSnapshot: true),
      );
      await tester.pumpWidget(_host(coordinator));
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('OTWÓRZ ZAPISANĄ KOPIĘ'), findsOneWidget);
      expect(find.textContaining('OFFLINE'), findsNothing);

      await tester.tap(find.text('OTWÓRZ ZAPISANĄ KOPIĘ'));
      await tester.pump(const Duration(milliseconds: 1));

      expect(platform.controllers.single.loaded, [_localUrl]);
      expect(find.textContaining('OFFLINE • ostatnia synchronizacja'), findsOneWidget);
      expect(find.textContaining('Połączenie z serwerem działa'), findsNothing);
    },
  );

  testWidgets('401 offers signing in again and says the session was refused', (
    tester,
  ) async {
    var logouts = 0;
    final coordinator = _ScriptedCoordinator(
      (_) async => _serverError(401, code: null),
    );
    await tester.pumpWidget(
      _host(
        coordinator,
        onLogout: () async {
          logouts++;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.textContaining('Sesja wygasła'), findsOneWidget);
    expect(find.textContaining('HTTP 401 · /public/dashboard.php'), findsOneWidget);

    await tester.tap(find.text('ZALOGUJ PONOWNIE'));
    await tester.pump();
    expect(logouts, 1);
  });

  testWidgets('403 says access was refused', (tester) async {
    final coordinator = _ScriptedCoordinator(
      (_) async => _serverError(403, code: 'forbidden'),
    );
    await tester.pumpWidget(_host(coordinator));
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.textContaining('odmówił dostępu'), findsOneWidget);
    expect(find.text('ZALOGUJ PONOWNIE'), findsNothing);
  });

  testWidgets('a saved copy shown because the SERVER was unavailable is labelled as such', (
    tester,
  ) async {
    final coordinator = _ScriptedCoordinator(
      (_) async => PageLoadOffline(
        url: _localUrl,
        capturedAt: DateTime.utc(2026, 10, 1, 8),
        reason: OfflineReason.serverUnavailable,
      ),
    );
    await tester.pumpWidget(_host(coordinator));
    await tester.pump(const Duration(milliseconds: 1));
    // The banner is part of the loaded page's screen, so it appears when the
    // saved copy has finished loading — exactly as in the real flow.
    platform.delegates.single.onPageFinished!(_localUrl.toString());
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.textContaining('SERWER NIEDOSTĘPNY • ostatnia synchronizacja'), findsOneWidget);
    expect(find.textContaining('OFFLINE •'), findsNothing);
  });

  group('automatic return to the live page', () {
    const dashboardUrl = 'https://szarlej.ministrant.eu/public/dashboard.php';
    final rankingUrl = Uri.parse('https://szarlej.ministrant.eu/public/ranking.php');

    OnlineProbeRecovered recovered() => OnlineProbeRecovered(_onlinePlan());

    /// The saved copy is on screen (plan done, page finished). The first
    /// reconnect attempt is due 2 s after the plan, i.e. at ~2000 ms.
    Future<void> readyOffline(WidgetTester tester, _FakePlatform platform) async {
      await tester.pump(const Duration(milliseconds: 1));
      platform.delegates.single.onPageFinished!(_localUrl.toString());
      await tester.pump(const Duration(milliseconds: 1));
    }

    Future<void> ms(WidgetTester tester, int millis) =>
        tester.pump(Duration(milliseconds: millis));

    testWidgets('when the server answers again the page opens online by itself', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(),
        probe: (_) async => recovered(),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);
      expect(find.textContaining('OFFLINE •'), findsOneWidget);
      expect(coordinator.probeCalls, 0);

      await ms(tester, 2100);
      await ms(tester, 10);

      expect(coordinator.probeCalls, 1);
      expect(platform.controllers.single.loaded, [_localUrl, _ticketUrl]);
      expect(find.textContaining('OFFLINE'), findsNothing);
      expect(coordinator.planCalls, 1, reason: 'the ticket from the check was used, not a second one');

      platform.delegates.single.onPageFinished!(dashboardUrl);
      await ms(tester, 10);
      expect(find.byType(spinner), findsNothing);

      // Online and stable: nothing keeps asking.
      await tester.pump(const Duration(minutes: 2));
      expect(coordinator.probeCalls, 1);
    });

    testWidgets('a slow server is waited for in the background and still wins', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(),
        probe: (_) => _after5s(recovered()),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);

      await ms(tester, 2100);
      expect(coordinator.probeCalls, 1);
      expect(platform.controllers.single.loaded, [_localUrl], reason: 'still waiting');
      expect(find.textContaining('OFFLINE •'), findsOneWidget, reason: 'the copy stays usable meanwhile');

      await ms(tester, 5000);
      await ms(tester, 10);
      expect(platform.controllers.single.loaded, [_localUrl, _ticketUrl]);
    });

    testWidgets('retries back off 2, 4, 8, 15, 30, 30 seconds', (tester) async {
      final coordinator = _ScriptedCoordinator((_) async => _offlinePlan());
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);

      // Attempts start at ~2000, 6000, 14000, 29000, 59000, 89000 ms.
      final steps = <(int, int)>[
        (1900, 0), (200, 1),
        (3700, 1), (400, 2),
        (7600, 2), (400, 3),
        (14500, 3), (600, 4),
        (29200, 4), (800, 5),
        (29000, 5), (1000, 6),
      ];
      for (final (advance, expectedCalls) in steps) {
        await ms(tester, advance);
        expect(coordinator.probeCalls, expectedCalls, reason: 'after +$advance ms');
      }
      expect(platform.controllers.single.loaded, [_localUrl], reason: 'never left the copy');
    });

    testWidgets('never two checks at once, even when the app is resumed meanwhile', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(),
        probe: (_) => _after20s(),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);

      await ms(tester, 2100);
      expect(coordinator.probeCalls, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await ms(tester, 100);
      expect(coordinator.probeCalls, 1, reason: 'one is already running');

      await ms(tester, 20000); // it ends; the next one is scheduled, not started
      expect(coordinator.probeCalls, 1);
    });

    testWidgets('in the background it stops asking; on resume it asks at once', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator((_) async => _offlinePlan());
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 20));
      expect(coordinator.probeCalls, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await ms(tester, 10);
      expect(coordinator.probeCalls, 1, reason: 'no waiting out the old delay');
    });

    testWidgets('unsaved input defers the switch; the user decides', (tester) async {
      var plans = 0;
      final coordinator = _ScriptedCoordinator(
        (_) async => ++plans == 1 ? _offlinePlan() : _onlinePlan(),
        probe: (_) async => recovered(),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);
      platform.controllers.single.jsResult = true; // a field was edited

      await ms(tester, 2100);
      await ms(tester, 10);

      expect(platform.controllers.single.loaded, [_localUrl], reason: 'must not switch');
      expect(find.textContaining('Połączenie wróciło'), findsOneWidget);
      expect(find.text('WRÓĆ ONLINE'), findsOneWidget);
      expect(find.textContaining('OFFLINE •'), findsOneWidget, reason: 'the copy is still there');

      await tester.pump(const Duration(minutes: 1));
      expect(coordinator.probeCalls, 1, reason: 'deferral stops the probing');

      await tester.tap(find.text('WRÓĆ ONLINE'));
      await ms(tester, 10);
      expect(platform.controllers.single.loaded.last, _ticketUrl);
      expect(find.textContaining('Połączenie wróciło'), findsNothing);
    });

    testWidgets('if the page cannot be inspected the switch is deferred, not risked', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(),
        probe: (_) async => recovered(),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);
      platform.controllers.single.jsThrows = true;

      await ms(tester, 2100);
      await ms(tester, 10);

      expect(platform.controllers.single.loaded, [_localUrl]);
      expect(find.text('WRÓĆ ONLINE'), findsOneWidget);
    });

    testWidgets('an auth-driven offline state never tries to go online', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(),
        probe: (_) async => recovered(),
      );
      await tester.pumpWidget(_host(coordinator, forceOffline: true));
      await readyOffline(tester, platform);

      await tester.pump(const Duration(minutes: 3));

      expect(coordinator.probeCalls, 0);
      expect(platform.controllers.single.loaded, [_localUrl]);
    });

    testWidgets('a refusal from the server stops the asking and says so, keeping the copy', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(),
        probe: (_) async => OnlineProbeRejected(
          PageLoadServerError(
            statusCode: 401,
            errorCode: 'session_expired',
            path: '/public/dashboard.php',
            hasSnapshot: true,
          ),
        ),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);

      await ms(tester, 2100);
      await ms(tester, 10);

      expect(
        find.textContaining('Serwer odrzucił otwarcie strony • HTTP 401 · session_expired'),
        findsOneWidget,
      );
      expect(find.textContaining('OFFLINE •'), findsOneWidget);
      expect(find.byType(spinner), findsNothing);

      await tester.pump(const Duration(minutes: 3));
      expect(coordinator.probeCalls, 1, reason: 'asking again cannot fix a refusal');
      expect(platform.controllers.single.loaded, [_localUrl]);
    });

    testWidgets('an answer to a check for a page the user already left is ignored, and the next one returns to the CURRENT page', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(),
        probe: (call) => call == 1 ? _after3s(recovered()) : Future.value(recovered()),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);

      await ms(tester, 2100); // check #1 starts (answers at ~5000)
      expect(coordinator.probeCalls, 1);

      await ms(tester, 900); // ~3000: the user taps a link to another page
      await platform.delegates.single.onNavigationRequest!(
        NavigationRequest(url: rankingUrl.toString(), isMainFrame: true),
      );
      await ms(tester, 10);
      platform.delegates.single.onPageFinished!(_localUrl.toString());
      await ms(tester, 10);
      final loadedBefore = platform.controllers.single.loaded.length;

      await ms(tester, 2200); // ~5200: check #1's answer has arrived
      expect(
        platform.controllers.single.loaded.where((u) => u == _ticketUrl),
        isEmpty,
        reason: 'the late answer belongs to a load that is gone',
      );
      expect(platform.controllers.single.loaded.length, loadedBefore);

      await ms(tester, 4000); // ~9200: the re-armed check (#2) answers
      await ms(tester, 10);
      expect(platform.controllers.single.loaded.last, _ticketUrl);

      // The ticket is for the entry page; the page the user was on follows.
      platform.delegates.single.onPageFinished!(dashboardUrl);
      await ms(tester, 10);
      expect(platform.controllers.single.loaded.last, rankingUrl);
    });

    testWidgets('leaving the screen while a check is running changes nothing afterwards', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(),
        probe: (_) => _after3s(recovered()),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);
      await ms(tester, 2100);
      expect(coordinator.probeCalls, 1);

      await tester.pumpWidget(const SizedBox()); // user / parish change, logout…
      await tester.pump(const Duration(seconds: 10));

      expect(tester.takeException(), isNull);
      expect(platform.controllers.single.loaded, [_localUrl]);
      expect(coordinator.probeCalls, 1);
    });

    testWidgets('a page that opens but never loads does not make the screen flap at the first pace', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(),
        probe: (_) async => recovered(),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);

      await ms(tester, 2100); // check #1 -> ticket -> page never finishes
      expect(platform.controllers.single.loaded, [_localUrl, _ticketUrl]);

      await ms(tester, 8100); // the 8 s page budget runs out -> back to the copy
      expect(platform.controllers.single.loaded, [_localUrl, _ticketUrl, _localUrl]);
      platform.delegates.single.onPageFinished!(_localUrl.toString());
      await ms(tester, 10);
      expect(coordinator.probeCalls, 1);

      // A flapping screen would ask again 2 s later (~12000).
      await ms(tester, 2300);
      expect(coordinator.probeCalls, 1, reason: 'the delay kept growing');

      await ms(tester, 2000); // ~14500: the 4 s delay is over
      expect(coordinator.probeCalls, 2);
    });

    testWidgets('twenty online/offline transitions in a row end where they should', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(),
        probe: (_) async => recovered(),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);

      for (var cycle = 1; cycle <= 20; cycle++) {
        await ms(tester, 2100); // reconnect check is due and succeeds
        await ms(tester, 10);
        expect(
          platform.controllers.single.loaded.last,
          _ticketUrl,
          reason: 'cycle $cycle went online',
        );
        platform.delegates.single.onPageFinished!(dashboardUrl);
        await ms(tester, 10);
        expect(find.textContaining('OFFLINE'), findsNothing, reason: 'cycle $cycle');

        // The connection drops while the live page is open.
        platform.delegates.single.onWebResourceError!(
          const WebResourceError(
            errorCode: -2,
            description: 'net::ERR_INTERNET_DISCONNECTED',
            isForMainFrame: true,
          ),
        );
        await ms(tester, 10);
        expect(
          platform.controllers.single.loaded.last,
          _localUrl,
          reason: 'cycle $cycle fell back to the copy',
        );
        platform.delegates.single.onPageFinished!(_localUrl.toString());
        await ms(tester, 10);
        expect(find.textContaining('OFFLINE •'), findsOneWidget, reason: 'cycle $cycle');
      }

      expect(tester.takeException(), isNull);
      expect(find.byType(spinner), findsNothing);
      expect(coordinator.probeCalls, 20, reason: 'the pace never degraded');
      expect(platform.controllers.single.loaded.length, 1 + 20 * 2);
    });

    testWidgets('refreshing a module page asks for a ticket for the ENTRY page and returns to the module', (
      tester,
    ) async {
      final scheduleUrl = Uri.parse('https://szarlej.ministrant.eu/public/schedule.php');
      final coordinator = _ScriptedCoordinator(
        (forceOffline) async => forceOffline ? _offlinePlan() : _onlinePlan(),
      );
      await tester.pumpWidget(_host(coordinator));
      await ms(tester, 10);
      platform.delegates.single.onPageFinished!(dashboardUrl);
      await ms(tester, 10);

      // The user opens a page the server has no handoff entry for.
      await platform.delegates.single.onNavigationRequest!(
        NavigationRequest(url: scheduleUrl.toString(), isMainFrame: true),
      );
      platform.delegates.single.onPageFinished!(scheduleUrl.toString());
      await ms(tester, 10);

      // The connection drops and later the user refreshes.
      platform.delegates.single.onWebResourceError!(
        const WebResourceError(
          errorCode: -2,
          description: 'net::ERR_INTERNET_DISCONNECTED',
          isForMainFrame: true,
        ),
      );
      await ms(tester, 10);
      platform.delegates.single.onPageFinished!(_localUrl.toString());
      await ms(tester, 10);

      await tester.tap(find.byTooltip('Spróbuj połączyć'));
      await ms(tester, 10);

      expect(
        coordinator.planRequests.last,
        ('/public/schedule.php', '/public/dashboard.php'),
        reason: 'the ticket is for the entry page; the page being refreshed is the target',
      );
      expect(platform.controllers.single.loaded.last, _ticketUrl);

      // The ticket lands on the entry page; the module the user was on follows.
      platform.delegates.single.onPageFinished!(dashboardUrl);
      await ms(tester, 10);
      expect(platform.controllers.single.loaded.last, scheduleUrl);
    });

    testWidgets('an expired PHP session is renewed silently; sign-out only if the renewal does not help', (
      tester,
    ) async {
      var logouts = 0;
      final scheduleUrl = Uri.parse('https://szarlej.ministrant.eu/public/schedule.php');
      const loginUrl = 'https://szarlej.ministrant.eu/public/login.php';
      final coordinator = _ScriptedCoordinator((_) async => _onlinePlan());
      await tester.pumpWidget(
        _host(
          coordinator,
          onLogout: () async {
            logouts++;
          },
        ),
      );
      await ms(tester, 10);
      platform.delegates.single.onPageFinished!(dashboardUrl);
      await ms(tester, 10);
      await platform.delegates.single.onNavigationRequest!(
        NavigationRequest(url: scheduleUrl.toString(), isMainFrame: true),
      );
      platform.delegates.single.onPageFinished!(scheduleUrl.toString());
      await ms(tester, 10);
      expect(coordinator.planCalls, 1);

      // The PHP session ended: the page the user asked for lands on login.
      platform.delegates.single.onPageFinished!(loginUrl);
      await ms(tester, 10);

      expect(logouts, 0, reason: 'the mobile sign-in is still valid');
      expect(coordinator.planCalls, 2, reason: 'a new session was requested');
      expect(
        coordinator.planRequests.last,
        ('/public/schedule.php', '/public/dashboard.php'),
        reason: 'and it returns to the page the user was on, not the login page',
      );

      // The new session works: landing, then the page itself.
      platform.delegates.single.onPageFinished!(dashboardUrl);
      await ms(tester, 10);
      expect(platform.controllers.single.loaded.last, scheduleUrl);
      platform.delegates.single.onPageFinished!(scheduleUrl.toString());
      await ms(tester, 10);
      expect(find.byType(spinner), findsNothing);

      // A later expiry is renewed again (the allowance is per expiry)...
      platform.delegates.single.onPageFinished!(loginUrl);
      await ms(tester, 10);
      expect(coordinator.planCalls, 3);
      expect(logouts, 0);

      // ...but login straight after a renewal means it did not help.
      platform.delegates.single.onPageFinished!(loginUrl);
      await ms(tester, 10);
      expect(logouts, 1);
    });

    testWidgets('a page that is merely slow is not reported as OFFLINE', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (forceOffline) async => forceOffline ? _offlinePlan() : _onlinePlan(),
      );
      await tester.pumpWidget(_host(coordinator));
      await ms(tester, 10); // ticket obtained; the page never finishes

      await ms(tester, 8100); // the 8 s page budget runs out

      expect(coordinator.planCalls, 2);
      expect(coordinator.planReasons.last, OfflineReason.slowServer);
    });

    testWidgets('a page the server answered with an error is reported as a server problem', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (forceOffline) async => forceOffline ? _offlinePlan() : _onlinePlan(),
      );
      await tester.pumpWidget(_host(coordinator));
      await ms(tester, 10);

      platform.delegates.single.onHttpError!(
        HttpResponseError(
          request: WebResourceRequest(uri: Uri.parse(dashboardUrl)),
          response: WebResourceResponse(uri: Uri.parse(dashboardUrl), statusCode: 502),
        ),
      );
      await ms(tester, 10);

      expect(coordinator.planCalls, 2);
      expect(coordinator.planReasons.last, OfflineReason.serverUnavailable);
    });

    testWidgets('a real failure to connect is NOT labelled with an earlier, different reason', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (forceOffline) async => forceOffline ? _offlinePlan() : _onlinePlan(),
      );
      await tester.pumpWidget(_host(coordinator));
      await ms(tester, 10);
      await ms(tester, 8100); // a slow-page fallback happens first
      expect(coordinator.planReasons.last, OfflineReason.slowServer);

      platform.delegates.single.onPageFinished!(_localUrl.toString());
      await ms(tester, 10);
      // The user retries; the connection then fails outright.
      await tester.tap(find.byTooltip('Spróbuj połączyć'));
      await ms(tester, 10);
      platform.delegates.single.onWebResourceError!(
        const WebResourceError(
          errorCode: -2,
          description: 'net::ERR_INTERNET_DISCONNECTED',
          isForMainFrame: true,
        ),
      );
      await ms(tester, 10);

      expect(coordinator.planReasons.last, OfflineReason.noNetwork);
    });

    testWidgets('no navigation, refresh, retry or reconnect ever asks for a ticket for a page outside the registry', (
      tester,
    ) async {
      // Linked from the panel, absent from the server's handoff registry.
      const pages = [
        'schedule.php',
        'points.php',
        'points-history.php',
        'gathering-attendance.php',
      ];
      final coordinator = _ScriptedCoordinator(
        (forceOffline) async => forceOffline ? _offlinePlan() : _onlinePlan(),
      );

      for (final page in pages) {
        final url = 'https://szarlej.ministrant.eu/public/$page';
        await tester.pumpWidget(_host(coordinator));
        await ms(tester, 10);
        final delegate = platform.delegates.last;
        delegate.onPageFinished!(dashboardUrl);
        await ms(tester, 10);

        // Open the page, then lose the connection while on it.
        await delegate.onNavigationRequest!(
          NavigationRequest(url: url, isMainFrame: true),
        );
        delegate.onPageFinished!(url);
        await ms(tester, 10);
        delegate.onWebResourceError!(
          const WebResourceError(
            errorCode: -2,
            description: 'net::ERR_INTERNET_DISCONNECTED',
            isForMainFrame: true,
          ),
        );
        await ms(tester, 10);
        delegate.onPageFinished!(_localUrl.toString());
        await ms(tester, 10);

        // Refresh by hand.
        await tester.tap(find.byTooltip('Spróbuj połączyć'));
        await ms(tester, 10);
        expect(
          coordinator.planRequests.last,
          ('/public/$page', '/public/dashboard.php'),
          reason: 'refresh on $page',
        );
        delegate.onPageFinished!(dashboardUrl); // the ticket lands
        await ms(tester, 10);
        expect(platform.controllers.last.loaded.last, Uri.parse(url), reason: page);
        delegate.onPageFinished!(url);
        await ms(tester, 10);

        // Lose the connection again; the background check must also go
        // through the entry page.
        delegate.onWebResourceError!(
          const WebResourceError(
            errorCode: -2,
            description: 'net::ERR_INTERNET_DISCONNECTED',
            isForMainFrame: true,
          ),
        );
        await ms(tester, 10);
        delegate.onPageFinished!(_localUrl.toString());
        await ms(tester, 2100);
        expect(coordinator.probeTargets.last, '/public/dashboard.php', reason: 'reconnect on $page');

        // A fresh screen for the next page: the same tree would only be
        // UPDATED, carrying this page over as the current one.
        await tester.pumpWidget(const SizedBox());
      }

      expect(
        coordinator.planRequests.map((r) => r.$2).toSet(),
        {'/public/dashboard.php'},
        reason: 'every ticket was requested for the entry page only',
      );
      expect(coordinator.probeTargets.toSet(), {'/public/dashboard.php'});
    });

    testWidgets('refreshing from a saved copy drops the OFFLINE label as soon as the live page is requested', (
      tester,
    ) async {
      var plans = 0;
      final coordinator = _ScriptedCoordinator(
        // 1st: the saved copy. 2nd (the refresh): the server takes a moment.
        (_) => ++plans == 1
            ? Future.value(_offlinePlan())
            : _after(const Duration(milliseconds: 300), _onlinePlan()),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);
      expect(find.textContaining('OFFLINE •'), findsOneWidget);

      await tester.tap(find.byTooltip('Spróbuj połączyć'));
      await ms(tester, 400); // the ticket has arrived; the page is loading

      expect(platform.controllers.single.loaded.last, _ticketUrl);
      expect(find.byType(spinner), findsOneWidget, reason: 'the live page has not finished');
      expect(
        find.textContaining('OFFLINE'),
        findsNothing,
        reason: 'the live page is on its way; the label must not wait for it to finish',
      );
    });

    testWidgets('going back online loads the LIVE page and hides the saved copy until it has', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _offlinePlan(),
        probe: (_) async => recovered(),
      );
      await tester.pumpWidget(_host(coordinator));
      await readyOffline(tester, platform);
      expect(find.textContaining('OFFLINE •'), findsOneWidget);
      final controller = platform.controllers.single;

      await ms(tester, 2100);
      await ms(tester, 10);

      // The live address is requested (the ticket's, which the server turns
      // into the real page) — not a reload of the saved copy.
      expect(controller.loaded.last, _ticketUrl);
      expect(controller.loaded.last, isNot(_localUrl));
      // Until the live page has finished, the saved copy is not on screen:
      // a spinner covers it, and the banner no longer claims OFFLINE.
      expect(find.byType(spinner), findsOneWidget);
      expect(find.textContaining('OFFLINE'), findsNothing);

      controller.scripts.clear();
      platform.delegates.single.onPageFinished!(dashboardUrl);
      await ms(tester, 10);
      expect(find.byType(spinner), findsNothing);
      // The page that just loaded is captured, so the saved copy is
      // REPLACED by this fresh content rather than left stale.
      expect(
        controller.scripts.where((s) => s.contains('postMessage')),
        isNotEmpty,
        reason: 'the freshly loaded live page must be saved',
      );
    });

    testWidgets('a refusal when opening the page is not a reason to ask again', (
      tester,
    ) async {
      final coordinator = _ScriptedCoordinator(
        (_) async => _serverError(400),
        probe: (_) async => recovered(),
      );
      await tester.pumpWidget(_host(coordinator));
      await ms(tester, 10);

      await tester.pump(const Duration(minutes: 3));

      expect(coordinator.probeCalls, 0);
      expect(find.textContaining('Połączenie z serwerem działa'), findsOneWidget);
    });
  });

  testWidgets('a page that finishes in time removes the overlay and the deadline', (
    tester,
  ) async {
    final coordinator = _ScriptedCoordinator((_) async => _onlinePlan());
    await tester.pumpWidget(_host(coordinator));
    await tester.pump(const Duration(milliseconds: 1));

    platform.delegates.single.onPageFinished!(
      'https://szarlej.ministrant.eu/public/dashboard.php',
    );
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.byType(spinner), findsNothing);
    expect(find.byType(WebViewWidget), findsOneWidget);
    expect(find.text('SPRÓBUJ PONOWNIE'), findsNothing);

    // No deadline fires afterwards and flips a finished page to an error.
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('SPRÓBUJ PONOWNIE'), findsNothing);
  });
}
