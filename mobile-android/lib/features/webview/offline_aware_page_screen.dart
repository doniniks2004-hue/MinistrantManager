import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/offline/offline_page_coordinator.dart';
import '../../core/offline/page_identity.dart';

/// Hosts the real PHP page. Offline replays saved views, without writes.
class OfflineAwarePageScreen extends StatefulWidget {
  const OfflineAwarePageScreen({
    super.key,
    required this.title,
    required this.targetPath,
    required this.allowedHost,
    required this.parishId,
    required this.userId,
    required this.coordinator,
    this.onLogout,
    this.forceOffline = false,
  });
  final String title;
  final String targetPath;
  final String allowedHost;
  final String parishId;
  final String userId;
  final OfflinePageCoordinator coordinator;
  final Future<void> Function()? onLogout;
  final bool forceOffline;
  @override
  State<OfflineAwarePageScreen> createState() => _OfflineAwarePageScreenState();
}

enum _LoadState { loading, ready, error, noSnapshot }

class _OfflineAwarePageScreenState extends State<OfflineAwarePageScreen> {
  static const _captureChannel = 'MMPageCapture';
  static const _bridgeChannel = 'MinistrantBridge';
  static const _bridgeShim = '''
(function() {
  if (!window.MinistrantBridge || window.MinistrantBridge.__mmShimmed) return;
  var raw = window.MinistrantBridge;
  window.MinistrantBridge = {
    __mmShimmed: true,
    debugPing: function() {}, onScroll: function() {},
    saveRememberToken: function(token) {
      raw.postMessage(JSON.stringify({type: 'remember_token', token: token}));
    }
  };
})();
''';
  /// Budget for a PHP page to finish rendering ONCE a handoff ticket
  /// exists (and for later in-session navigations). Deliberately separate
  /// from — and much longer than — the connect budget in
  /// OfflinePageCoordinator.onlineTimeout: that one answers "is there a
  /// working connection at all" and must stay short so a truly offline
  /// phone reaches its saved view fast; this one only decides when a
  /// reachable-but-slow page is given up on. Before they were split, one
  /// 1.5 s timer started BEFORE the ticket request and also covered the
  /// page load, so a ticket that took 1.4 s left the page ~100 ms.
  /// Tunable — verify on a real device on a slow mobile connection.
  static const _pageRenderBudget = Duration(seconds: 8);

  /// ONE absolute budget for everything that stands between "load
  /// started" and "saved view on screen": the handoff attempt, local
  /// planning, and rendering the loopback page. It is a single timer
  /// started when the load starts — NOT a budget per stage. Per-stage
  /// budgets add up (1.4 s of planning left the full 2 s render budget
  /// still to run: spinner until 3.4 s); one timer cannot. It does not
  /// apply once a handoff ticket exists (the online page then has
  /// [_pageRenderBudget]). A failure detector, not a target: a loopback
  /// page normally renders in well under a second. Worst case on a
  /// Wi-Fi-without-internet network: the 1.5 s connect budget leaves
  /// ~0.5 s for local planning and rendering — if on-device measurement
  /// shows that is too tight, shorten OfflinePageCoordinator.onlineTimeout
  /// rather than lengthening this.
  static const _offlineTotalBudget = Duration(seconds: 2);

  /// True from the moment a handoff ticket is in hand (PageLoadOnline) —
  /// from then on [_offlineTotalBudget] no longer applies.
  bool _onlineRendering = false;
  Timer? _totalDeadline;

  /// The loopback document the screen is CURRENTLY waiting for or showing
  /// — null whenever no offline navigation is current (a new load began,
  /// the load was abandoned by its deadline, or it failed). Callbacks for
  /// anything else are stale: the engine keeps running a navigation the
  /// screen has given up on, and its onPageFinished arrives later.
  /// _loadGeneration cannot guard that (callbacks carry no generation), so
  /// the navigation is identified by its URL instead — unique per plan,
  /// see OfflinePageCoordinator.
  Uri? _offlineLoadUrl;

  bool _isCurrentOfflineDocument(Uri uri) {
    final current = _offlineLoadUrl;
    // Scheme/host/port/token prefix are checked by LocalSnapshotServer.ownsUrl.
    return current != null &&
        uri.path == current.path &&
        uri.query == current.query;
  }

  late final WebViewController _controller;
  _LoadState _state = _LoadState.loading;
  String? _errorText;
  bool _online = true;
  bool _loggingOut = false;
  String? _banner;
  late String _currentPath;
  Timer? _navigationDeadline;
  Timer? _captureTimer;
  int _loadGeneration = 0;
  String? _afterHandoffPath;
  final Set<String> _failedDocuments = {};

  @override
  void initState() {
    super.initState();
    _currentPath = widget.targetPath;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(_captureChannel, onMessageReceived: _onCapture)
      ..addJavaScriptChannel(_bridgeChannel, onMessageReceived: _onBridge)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: _onStarted,
          onHttpError: (error) {
            final uri = error.request?.uri;
            if (!mounted || _loggingOut || uri == null) return;
            if (!_online) {
              // LocalSnapshotServer answers 5xx when a stored file cannot
              // be decrypted (corrupt cache / lost key). Without this the
              // WebView just renders an empty error body and the screen
              // reports "ready" over a blank page.
              if (_state == _LoadState.loading &&
                  widget.coordinator.localServer.ownsUrl(uri) &&
                  uri.path.endsWith('/snapshot.html') &&
                  _isCurrentOfflineDocument(uri)) {
                _offlineLoadUrl = null;
                _navigationDeadline?.cancel();
                _navigationDeadline = null;
                _totalDeadline?.cancel();
                _totalDeadline = null;
                _failedDocuments.add(uri.toString());
                setState(() {
                  _state = _LoadState.error;
                  _errorText =
                      'Zapisana kopia strony jest uszkodzona. Otwórz ją ponownie przy połączeniu z internetem.';
                });
              }
              return;
            }
            if (!_trusted(uri)) return;
            final path = snapshotPagePath(uri);
            if (path != _currentPath &&
                uri.path != '/public/mobile_handoff.php')
              return;
            _failedDocuments.add(uri.toString());
            unawaited(_loadPage(forceOffline: true));
          },
          onPageFinished: _onFinished,
          onWebResourceError: (e) {
            if (!mounted || _loggingOut || e.isForMainFrame != true) return;
            if (!_online) {
              // An error for a navigation that is no longer the current
              // one (abandoned, or replaced by a retry) must not fail the
              // load that IS current.
              final failed = e.url == null ? null : Uri.tryParse(e.url!);
              if (_offlineLoadUrl == null ||
                  (failed != null && !_isCurrentOfflineDocument(failed))) {
                return;
              }
            }
            _navigationDeadline?.cancel();
            _totalDeadline?.cancel();
            _totalDeadline = null;
            if (_online) {
              unawaited(_loadPage(forceOffline: true));
            } else {
              _offlineLoadUrl = null;
              setState(() {
                _state = _LoadState.error;
                _errorText = 'Nie udało się otworzyć zapisanej kopii strony.';
              });
            }
          },
          onNavigationRequest: _navigate,
        ),
      );
    unawaited(_loadPage(forceOffline: widget.forceOffline));
  }

  @override
  void didUpdateWidget(covariant OfflineAwarePageScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.forceOffline != widget.forceOffline) {
      unawaited(_loadPage(forceOffline: widget.forceOffline));
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _navigationDeadline?.cancel();
    _totalDeadline?.cancel();
    _captureTimer?.cancel();
    super.dispose();
  }

  bool _trusted(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == widget.allowedHost &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;

  void _onCapture(JavaScriptMessage message) {
    if (!_online || _loggingOut || !mounted) return;
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final uri = Uri.parse(data['url'] as String);
      final path = snapshotPagePath(uri);
      if (!_trusted(uri) || path == null || path != _currentPath) return;
      widget.coordinator.captureInBackground(
        parishId: widget.parishId,
        userId: widget.userId,
        targetPath: path,
        renderedHtml: data['html'] as String,
      );
    } catch (_) {
      // Ignore malformed or stale messages.
    }
  }

  void _onBridge(JavaScriptMessage message) {
    if (!_online || _loggingOut || !mounted) return;
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      if (data['type'] == 'remember_token' && data['token'] is String) {
        unawaited(
          widget.coordinator.handoffService.secureStorage
              .setLegacyRememberToken(data['token'] as String)
              .catchError((_) {}),
        );
      }
    } catch (_) {}
  }

  void _startDeadline() {
    if (_navigationDeadline != null) return;
    _navigationDeadline = Timer(_pageRenderBudget, () {
      if (mounted && _online && !_loggingOut) {
        unawaited(_loadPage(forceOffline: true));
      }
    });
  }

  /// Expiry of [_offlineTotalBudget]. Gives up on THIS load completely —
  /// including bumping [_loadGeneration] — so a plan, loadRequest or page
  /// callback that finishes late cannot bring the abandoned load back
  /// and flip the screen under the user after the error is already shown.
  void _expireOfflineBudget(int generation) {
    if (!mounted || _loggingOut || generation != _loadGeneration) return;
    if (_onlineRendering || _state != _LoadState.loading) return;
    _loadGeneration++;
    // The engine is still running the navigation we are giving up on; its
    // late onPageFinished must not turn this error back into "ready".
    _offlineLoadUrl = null;
    _navigationDeadline?.cancel();
    _navigationDeadline = null;
    setState(() {
      _state = _LoadState.error;
      _errorText = 'Zapisana kopia strony nie otworzyła się na czas. Spróbuj ponownie.';
    });
  }

  void _onStarted(String url) {
    if (!mounted || _loggingOut) return;
    _captureTimer?.cancel();
    final uri = Uri.tryParse(url);
    if (_online && uri != null && _trusted(uri)) {
      _failedDocuments.remove(uri.toString());
      final path = snapshotPagePath(uri);
      if (path != null && _afterHandoffPath == null) _currentPath = path;
      _startDeadline();
    }
    unawaited(_controller.runJavaScript(_bridgeShim).catchError((_) {}));
  }

  void _onFinished(String url) {
    if (!mounted || _loggingOut) return;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (_online
            ? !_trusted(uri)
            : !(widget.coordinator.localServer.ownsUrl(uri) &&
                  _isCurrentOfflineDocument(uri))))
      return;
    if (_failedDocuments.contains(uri.toString())) return;
    if (_online && _afterHandoffPath != null && snapshotPagePath(uri) != null) {
      final target = _afterHandoffPath!;
      _afterHandoffPath = null;
      if (snapshotPagePath(uri) != target) {
        _currentPath = target;
        unawaited(
          _controller.loadRequest(
            Uri.parse('https://${widget.allowedHost}').resolve(target),
          ),
        );
        return;
      }
    }
    _navigationDeadline?.cancel();
    _navigationDeadline = null;
    _totalDeadline?.cancel();
    _totalDeadline = null;
    // A login redirect means the PHP session expired; never cache it.
    if (_online && uri.pathSegments.lastOrNull?.toLowerCase() == 'login.php') {
      unawaited(_logout());
      return;
    }
    setState(() => _state = _LoadState.ready);
    if (!_online) {
      unawaited(
        _controller
            .runJavaScript(r"""
        document.querySelectorAll('form input,form textarea,form select,form button').forEach(function(e) {
          e.disabled = true; e.title = 'Dostępne po połączeniu z internetem';
        });
        document.addEventListener('submit', function(e) {
          e.preventDefault(); e.stopImmediatePropagation();
        }, true);
      """)
            .catchError((_) {}),
      );
    }
    if (_online) {
      final path = snapshotPagePath(uri);
      if (path == null) return;
      _currentPath = path;
      _capture();
      // Capture again after typical async DOM updates; navigation cancels this.
      _captureTimer = Timer(const Duration(milliseconds: 750), _capture);
    }
  }

  void _capture() {
    if (!mounted || !_online || _loggingOut) return;
    unawaited(
      _controller
          .runJavaScript('''
$_captureChannel.postMessage(JSON.stringify({
  url: location.href, html: document.documentElement.outerHTML
}));
''')
          .catchError((_) {}),
    );
  }

  NavigationDecision _navigate(NavigationRequest request) {
    if (_loggingOut) return NavigationDecision.prevent;
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    if (_trusted(uri)) {
      if (isLogoutPath(uri)) {
        unawaited(_logout());
        return NavigationDecision.prevent;
      }
      if (_online) {
        final path = snapshotPagePath(uri);
        if (request.isMainFrame && path != null && _afterHandoffPath == null) {
          _currentPath = path;
          _startDeadline();
        }
        return NavigationDecision.navigate;
      }
      if (request.isMainFrame) {
        final path = snapshotPagePath(uri);
        if (path != null) {
          _currentPath = path;
          unawaited(_loadPage(forceOffline: true));
        }
      }
      return NavigationDecision.prevent;
    }
    if (!_online && widget.coordinator.localServer.ownsUrl(uri))
      return NavigationDecision.navigate;
    if (_online &&
        request.isMainFrame &&
        const {'https', 'http', 'mailto', 'tel'}.contains(uri.scheme)) {
      unawaited(
        launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        ).catchError((_) => false),
      );
    }
    return NavigationDecision.prevent;
  }

  Future<void> _logout() async {
    if (_loggingOut || widget.onLogout == null) return;
    _loggingOut = true;
    _loadGeneration++;
    _offlineLoadUrl = null;
    _navigationDeadline?.cancel();
    _totalDeadline?.cancel();
    _captureTimer?.cancel();
    if (mounted) setState(() => _state = _LoadState.loading);
    widget.coordinator.localServer.rootDirectory = null;
    try {
      await _controller.loadHtmlString('<html><body></body></html>');
      await _controller.clearCache();
      await _controller.clearLocalStorage();
    } catch (_) {}
    await widget.onLogout!();
  }

  Future<void> _loadPage({bool forceOffline = false}) async {
    final generation = ++_loadGeneration;
    _navigationDeadline?.cancel();
    _navigationDeadline = null;
    _captureTimer?.cancel();
    if (!mounted || _loggingOut) return;
    setState(() => _state = _LoadState.loading);
    _onlineRendering = false;
    // From here on any offline navigation that was still pending belongs
    // to an abandoned load.
    _offlineLoadUrl = null;
    _totalDeadline?.cancel();
    _totalDeadline = Timer(
      _offlineTotalBudget,
      () => _expireOfflineBudget(generation),
    );
    try {
      // No page deadline here on purpose: plan() is itself bounded
      // (handoff by onlineTimeout, local view by offlinePlanTimeout), and
      // the page-render budget must only start once a ticket exists.
      // A forced-offline load leaves online mode IMMEDIATELY, not when the
      // plan returns: otherwise an online page the screen just gave up on
      // could still finish inside that window and flip the screen back.
      _online = !forceOffline;
      final plan = await widget.coordinator.plan(
        parishId: widget.parishId,
        userId: widget.userId,
        targetPath: _currentPath,
        forceOffline: forceOffline,
      );
      if (!mounted || _loggingOut || generation != _loadGeneration) return;
      switch (plan) {
        case PageLoadOnline():
          _online = true;
          _afterHandoffPath = Uri.parse(_currentPath).hasQuery
              ? _currentPath
              : null;
          _banner = null;
          _errorText = null;
          // A ticket exists: the server answered, so this is no longer
          // "is the network there" but "is the page slow" — it gets its
          // own, longer budget instead of the 2 s offline one.
          _onlineRendering = true;
          _offlineLoadUrl = null;
          _totalDeadline?.cancel();
          _totalDeadline = null;
          _startDeadline();
          await _controller.loadRequest(plan.url);
        case PageLoadOffline():
          _online = false;
          _afterHandoffPath = null;
          _banner = formatOfflineBannerText(plan.capturedAt);
          _errorText = null;
          // A previous attempt at this very URL may have been marked
          // failed (corrupt copy); the entry must not swallow the
          // onPageFinished of a legitimate retry.
          _failedDocuments.removeWhere((u) => u.startsWith('http://'));
          _offlineLoadUrl = plan.url;
          await _controller.loadRequest(plan.url);
        case PageLoadOfflineNoSnapshot():
          _online = false;
          _errorText = null;
          setState(() => _state = _LoadState.noSnapshot);
      }
    } catch (_) {
      if (mounted && generation == _loadGeneration)
        setState(() => _state = _LoadState.error);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      if (_online && await _controller.canGoBack()) {
        _startDeadline();
        await _controller.goBack();
      } else if (_currentPath != widget.targetPath) {
        _currentPath = widget.targetPath;
        await _loadPage(forceOffline: !_online);
      } else if (context.mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    },
    child: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (_banner != null)
              Container(
                color: Colors.orange.shade100,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$_banner • tylko podgląd',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Spróbuj połączyć',
                      icon: const Icon(Icons.refresh),
                      onPressed: () => _loadPage(),
                    ),
                  ],
                ),
              ),
            Expanded(
              // The WebView is ALWAYS part of the tree (it used to be added
              // only once onPageFinished had set `ready`, i.e. the page
              // had to finish loading in a view that did not exist yet).
              // Loading / no-snapshot / error are an opaque overlay on top,
              // so a rebuild can never tear the platform view down in the
              // middle of a navigation.
              child: Stack(
                children: [
                  WebViewWidget(controller: _controller),
                  if (_state != _LoadState.ready)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: _state == _LoadState.loading
                            ? const Center(child: CircularProgressIndicator())
                            : Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.wifi_off, size: 48),
                                      const SizedBox(height: 16),
                                      Text(
                                        _state == _LoadState.noSnapshot
                                            ? 'Brak zapisanej wersji tej strony. Otwórz ją przy połączeniu z internetem.'
                                            : (_errorText ??
                                                  'Nie udało się otworzyć strony.'),
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 16),
                                      FilledButton(
                                        onPressed: () => _loadPage(),
                                        child: const Text('SPRÓBUJ PONOWNIE'),
                                      ),
                                      if (_currentPath != widget.targetPath)
                                        TextButton(
                                          onPressed: () {
                                            _currentPath = widget.targetPath;
                                            unawaited(
                                              _loadPage(forceOffline: !_online),
                                            );
                                          },
                                          child: const Text('WRÓĆ DO PANELU'),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
