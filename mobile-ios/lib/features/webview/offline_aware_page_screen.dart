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
  late final WebViewController _controller;
  _LoadState _state = _LoadState.loading;
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
            if (!mounted || !_online || uri == null || !_trusted(uri)) return;
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
            _navigationDeadline?.cancel();
            if (_online) {
              unawaited(_loadPage(forceOffline: true));
            } else {
              setState(() => _state = _LoadState.error);
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
    _navigationDeadline = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && _online && !_loggingOut)
        unawaited(_loadPage(forceOffline: true));
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
      _navigationDeadline ??= Timer(const Duration(milliseconds: 1500), () {
        if (mounted && _online) unawaited(_loadPage(forceOffline: true));
      });
    }
    unawaited(_controller.runJavaScript(_bridgeShim).catchError((_) {}));
  }

  void _onFinished(String url) {
    if (!mounted || _loggingOut) return;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (_online
            ? !_trusted(uri)
            : !widget.coordinator.localServer.ownsUrl(uri)))
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
    _navigationDeadline?.cancel();
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
    try {
      if (!forceOffline) {
        _online = true;
        _startDeadline();
      }
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
          await _controller.loadRequest(plan.url);
        case PageLoadOffline():
          _online = false;
          _afterHandoffPath = null;
          _banner = formatOfflineBannerText(plan.capturedAt);
          await _controller.loadRequest(plan.url);
        case PageLoadOfflineNoSnapshot():
          _online = false;
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
              child: _state == _LoadState.ready
                  ? WebViewWidget(controller: _controller)
                  : _state == _LoadState.loading
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
                                  : 'Nie udało się otworzyć strony.',
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
                                  unawaited(_loadPage(forceOffline: !_online));
                                },
                                child: const Text('WRÓĆ DO PANELU'),
                              ),
                          ],
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
