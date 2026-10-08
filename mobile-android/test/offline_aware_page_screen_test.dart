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

  @override
  Future<void> runJavaScript(String javaScript) async {}

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

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
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
    Future<PageLoadPlan> Function(bool forceOffline) script,
  ) => _ScriptedCoordinator._(SnapshotStore(encryptor: _encryptor), script);

  _ScriptedCoordinator._(SnapshotStore store, this.script)
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
  int planCalls = 0;

  @override
  Future<PageLoadPlan> plan({
    required String parishId,
    required String userId,
    required String targetPath,
    bool forceOffline = false,
  }) {
    planCalls++;
    return script(forceOffline);
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
}) => MaterialApp(
  home: OfflineAwarePageScreen(
    title: 'Panel',
    targetPath: '/public/dashboard.php',
    allowedHost: 'szarlej.ministrant.eu',
    parishId: 'p',
    userId: 'u',
    coordinator: coordinator,
    onLogout: onLogout,
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
