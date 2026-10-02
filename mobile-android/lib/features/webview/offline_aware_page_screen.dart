import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/offline/offline_page_coordinator.dart';

/// Offline-architecture milestone, P6 (P10: real-Szarlej fixes —
/// targetPath/handoffUrl separation, MinistrantBridge). Connects every
/// piece built in P2-P5 to an actual `WebViewController`:
///
/// ```
/// ONLINE:  PHP -> WebView -> render -> SnapshotCaptureService -> ... -> SnapshotStore
/// OFFLINE: brak internetu -> LocalSnapshotServer -> 127.0.0.1 -> WebView -> ostatni snapshot
/// ```
///
/// Honest limit, stated plainly rather than glossed over: this class is
/// the one genuinely untestable piece of the whole offline architecture
/// built so far — `flutter test` has no WebView platform channel at
/// all, so nothing that actually touches [WebViewController] can be
/// exercised here the way every other file in `core/offline/` has been
/// (real sockets, real temp directories, real HTTP servers). All of the
/// DECISION logic this screen depends on — [OfflinePageCoordinator.plan],
/// the online/offline branch, the capture trigger, the banner text — IS
/// fully tested (offline_page_coordinator_test.dart); this file is
/// deliberately as thin as possible specifically so the untested
/// surface is as small as it can be. Real device/CI verification is
/// what actually confirms this file itself.
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
  });

  final String title;

  /// The page's own identity — e.g. `/public/dashboard.php` — NEVER a
  /// handoff URL (see [OfflinePageCoordinator]'s own class docblock for
  /// why that distinction is load-bearing, a real finding against the
  /// actual Szarlej installation).
  final String targetPath;

  /// Same role as LegacyModuleScreen's own `allowedHost` — the real
  /// parish host (e.g. `szarlej.ministrant.eu`), checked by
  /// [_decideNavigation] while online.
  final String allowedHost;

  final String parishId;
  final String userId;
  final OfflinePageCoordinator coordinator;
  final Future<void> Function()? onLogout;

  @override
  State<OfflineAwarePageScreen> createState() => _OfflineAwarePageScreenState();
}

enum _LoadState { loading, ready, error, noSnapshot }

class _OfflineAwarePageScreenState extends State<OfflineAwarePageScreen> {
  static const _captureChannelName = 'MMPageCapture';

  /// P10 finding: the real, already-deployed Szarlej PHP (footer.php)
  /// already expects a native bridge object under this exact name —
  /// `window.MinistrantBridge.debugPing(...)` /
  /// `.saveRememberToken(...)` / `.onScroll(...)` — wrapped in its own
  /// try/catch, so nothing breaks today without it, but three real
  /// features (diagnostic ping, legacy "remember me" continuity, a
  /// Facebook-style collapsing header on scroll) simply don't fire.
  /// webview_flutter's own channel abstraction only ever gives the page
  /// a single `postMessage(String)` method on `window.<channelName>` —
  /// never multiple named methods the way a raw native bridge would —
  /// so [_bridgeShimScript] wraps that one raw channel into the
  /// multi-method shape the PHP already calls.
  static const _bridgeChannelName = 'MinistrantBridge';

  static const _bridgeShimScript = '''
(function() {
  if (!window.$_bridgeChannelName || window.$_bridgeChannelName.__mmShimmed) return;
  var raw = window.$_bridgeChannelName;
  window.$_bridgeChannelName = {
    __mmShimmed: true,
    debugPing: function(page) {
      raw.postMessage(JSON.stringify({type: 'debug_ping', page: page}));
    },
    saveRememberToken: function(token) {
      raw.postMessage(JSON.stringify({type: 'remember_token', token: token}));
    },
    onScroll: function(direction) {
      raw.postMessage(JSON.stringify({type: 'scroll', direction: direction}));
    }
  };
})();
''';

  late final WebViewController _controller;
  _LoadState _state = _LoadState.loading;
  String? _errorMessage;
  String? _offlineBannerText;

  /// Set once [widget.coordinator.plan] actually returns — governs both
  /// whether a finished page load should trigger a background capture
  /// AND which host [_decideNavigation] allows, so it is never left at
  /// a stale default while a plan is in flight.
  bool _isOnlineMode = true;

  /// Legacy PHP may send scroll-direction bridge messages. The bridge is
  /// retained for compatibility, but the PHP page remains visually in
  /// charge; no native app bar is added.

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(_captureChannelName, onMessageReceived: _onCaptureMessage)
      ..addJavaScriptChannel(_bridgeChannelName, onMessageReceived: _onBridgeMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => _controller.runJavaScript(_bridgeShimScript),
          onPageFinished: _onPageFinished,
          onWebResourceError: (error) => setState(() {
            _state = _LoadState.error;
            _errorMessage = error.description;
          }),
          onNavigationRequest: (request) => _decideNavigation(request.url),
        ),
      );
    _loadPage();
  }

  void _onCaptureMessage(JavaScriptMessage message) {
    // Never fired for an offline snapshot replay in practice (only the
    // ONLINE branch below ever asks the page for its own HTML) — this
    // guard is defense in depth, not the primary mechanism.
    if (!_isOnlineMode) return;
    widget.coordinator.captureInBackground(
      parishId: widget.parishId,
      userId: widget.userId,
      targetPath: widget.targetPath,
      renderedHtml: message.message,
    );
  }

  /// P10: dispatches the three message types footer.php's own JS already
  /// sends through the shimmed bridge (see [_bridgeShimScript]). Never
  /// lets a malformed or unexpected message crash the page — this
  /// bridge is a convenience layer for the legacy PHP's own existing
  /// features, not something any security decision in this app depends
  /// on.
  void _onBridgeMessage(JavaScriptMessage message) {
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      switch (data['type'] as String?) {
        case 'remember_token':
          // Review round: "remember_token może być przekazany do
          // istniejącego bezpiecznego storage, a nie wrzucony do
          // zwykłego cache WebView" — flutter_secure_storage, never the
          // WebView's own cookie jar/cache. This app does not yet have
          // a client-side use for the token (the legacy PHP's own
          // consumption mechanism is separate, pre-existing server-side
          // logic this project doesn't own) — storing it securely is
          // this round's complete scope.
          final token = data['token'] as String?;
          if (token != null) {
            // Unawaited by design (this is a synchronous bridge
            // callback) — but the surrounding try/catch above is also
            // synchronous and would never see a LATER async failure, so
            // this needs its own handler rather than relying on that.
            widget.coordinator.handoffService.secureStorage.setLegacyRememberToken(token).catchError((_) {});
          }
          break;
        case 'scroll':
          // The legacy page owns its own header. Scroll messages are
          // intentionally not used to alter native UI.
          break;
        case 'debug_ping':
          // No app-side action — purely a liveness signal from the
          // page's own diagnostic script.
          break;
      }
    } catch (_) {
      // Malformed/unexpected bridge message — never let it crash the
      // page, see this method's own docblock.
    }
  }

  void _onPageFinished(String url) {
    if (mounted) setState(() => _state = _LoadState.ready);

    final finishedUri = Uri.tryParse(url);
    if (widget.onLogout != null &&
        finishedUri != null &&
        finishedUri.host == widget.allowedHost &&
        finishedUri.path.toLowerCase().contains('logout')) {
      widget.onLogout!();
      return;
    }

    if (_isOnlineMode) {
      // Review round §6: "Cały wyrenderowany DOM" — outerHTML of the
      // root element, not the server's original response body, so
      // anything the page's own JS did to the DOM before this fires is
      // captured too.
      _controller.runJavaScript('$_captureChannelName.postMessage(document.documentElement.outerHTML);');
    }
  }

  NavigationDecision _decideNavigation(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return NavigationDecision.prevent;

    if (_isOnlineMode) {
      // Same rule as LegacyModuleScreen's own allowlist — HTTPS only, on
      // the actual page's own host. A different host is opened in the
      // system browser rather than silently blocked, matching that
      // screen's existing behavior for a legitimate outbound link.
      if (uri.scheme == 'https' && uri.host == widget.allowedHost) {
        return NavigationDecision.navigate;
      }
      return NavigationDecision.prevent;
    }

    // Offline: the ONLY legitimate destination is the local snapshot
    // server itself (127.0.0.1, http, on whatever port LocalSnapshotServer
    // is currently bound to) — never a real external host, even an
    // https one, since there is no live PHP session to safely hand off
    // to while offline.
    if (uri.scheme == 'http' && uri.host == '127.0.0.1') {
      return NavigationDecision.navigate;
    }
    return NavigationDecision.prevent;
  }

  Future<void> _loadPage() async {
    if (mounted) setState(() => _state = _LoadState.loading);

    final plan = await widget.coordinator.plan(
      parishId: widget.parishId,
      userId: widget.userId,
      targetPath: widget.targetPath,
    );

    if (!mounted) return;

    switch (plan) {
      case PageLoadOnline():
        _isOnlineMode = true;
        setState(() => _offlineBannerText = null);
        // plan.url is the one-time handoff URL — navigation ONLY, never
        // stored, never used to resolve anything (see
        // OfflinePageCoordinator's own class docblock).
        await _controller.loadRequest(plan.url);
        break;
      case PageLoadOffline():
        _isOnlineMode = false;
        setState(() => _offlineBannerText = formatOfflineBannerText(plan.capturedAt));
        await _controller.loadRequest(plan.url);
        break;
      case PageLoadOfflineNoSnapshot():
        _isOnlineMode = false;
        setState(() => _state = _LoadState.noSnapshot);
    }
  }

  Future<bool> _handleBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return false; // stay on this screen, WebView handled its own back
    }
    return true; // let the screen pop
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _handleBack();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        body: Column(
          children: [
            // The PHP page owns the entire visual chrome. The app adds
            // exactly one native element when offline: the status banner.
            if (_offlineBannerText != null)
              Container(
                width: double.infinity,
                color: Colors.orange.shade100,
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  _offlineBannerText!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _LoadState.noSnapshot:
        return const _MessageState(
          icon: Icons.wifi_off,
          message: 'Brak zapisanej wersji tej strony. Połącz się z internetem, aby ją pobrać.',
        );
      case _LoadState.error:
        return _MessageState(
          icon: Icons.error_outline,
          message: _errorMessage ?? 'Nie udało się załadować strony.',
          actionLabel: 'SPRÓBUJ PONOWNIE',
          onAction: _loadPage,
        );
      case _LoadState.loading:
        return const Center(child: CircularProgressIndicator());
      case _LoadState.ready:
        return WebViewWidget(controller: _controller);
    }
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({required this.icon, required this.message, this.actionLabel, this.onAction});

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
