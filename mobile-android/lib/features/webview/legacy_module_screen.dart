import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'webview_handoff_service.dart';

/// Hybrid dashboard milestone (review round, points 17/30): the ONE
/// generic WebView shell every legacy PHP module opens through — never a
/// bespoke WebView per module. Security rules enforced here apply to
/// EVERY module automatically, with nothing left to a per-module author
/// to remember:
///   - HTTPS only, host allowlisted to the ACTIVE parish's own server_url
///     host — no other host is ever loaded inside this WebView, no
///     matter what a page's own links/redirects try.
///   - Any navigation to a DIFFERENT host is blocked here and instead
///     opened in the system browser (review round point 17/30).
///   - `file://` and arbitrary local file access are never reachable —
///     the WebView only ever navigates to https URLs on the allowlisted
///     host to begin with.
///   - mobile_user_token is NEVER passed to this screen or to the
///     WebView in any form — only the one-time handoff ticket
///     (WebviewHandoffService), consumed server-side before this screen
///     ever loads a single pixel of the target page.
class LegacyModuleScreen extends StatefulWidget {
  const LegacyModuleScreen({
    super.key,
    required this.title,
    required this.path,
    required this.handoffService,
    required this.allowedHost,
    this.isOnline = true,
  });

  final String title;
  final String path;
  final WebviewHandoffService handoffService;

  /// The ONLY host this WebView instance is ever allowed to display —
  /// derived from the active parish's own `server_url` at call time,
  /// never a fixed/global value (review round point 10: "aplikacja nie
  /// jest na sztywno związana z jedną parafią").
  final String allowedHost;

  final bool isOnline;

  @override
  State<LegacyModuleScreen> createState() => _LegacyModuleScreenState();
}

enum _LoadState { loading, ready, error, offline }

class _LegacyModuleScreenState extends State<LegacyModuleScreen> {
  late final WebViewController _controller;
  _LoadState _state = _LoadState.loading;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => setState(() => _state = _LoadState.ready),
          onWebResourceError: (error) => setState(() {
            _state = _LoadState.error;
            _errorMessage = error.description;
          }),
          // Review round points 17/30: the single enforcement point for
          // "WebView may move ONLY within the active parish / approved MM
          // hosts". Every navigation — including ones triggered by the
          // page's own links, redirects, or JS — passes through here.
          onNavigationRequest: (request) => _decideNavigation(request.url),
        ),
      );

    if (!widget.isOnline) {
      _state = _LoadState.offline;
    } else {
      _startHandoff();
    }
  }

  NavigationDecision _decideNavigation(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return NavigationDecision.prevent;

    // file:// or any non-https scheme (review round point 30: "file://
    // wyłączone", "mixed HTTP content niedozwolony") — the handoff URL
    // itself and every legitimate page on the parish server are https.
    if (uri.scheme != 'https') {
      return NavigationDecision.prevent;
    }

    if (uri.host == widget.allowedHost) {
      return NavigationDecision.navigate;
    }

    // A different host — never load it inside the WebView. Open it in
    // the system browser instead (review round point 17: "external links
    // → systemowa przeglądarka") so a legitimate outbound link (e.g. a
    // reference in an announcement) still works, just not INSIDE the
    // app's WebView shell.
    launchUrl(uri, mode: LaunchMode.externalApplication);
    return NavigationDecision.prevent;
  }

  Future<void> _startHandoff() async {
    setState(() => _state = _LoadState.loading);
    try {
      final handoffUrl = await widget.handoffService.requestHandoffUrl(widget.path);
      if (handoffUrl.host != widget.allowedHost || handoffUrl.scheme != 'https') {
        // Defensive: the backend should never return anything else, but
        // this screen never loads a URL outside its own allowlist even
        // if it somehow did.
        setState(() {
          _state = _LoadState.error;
          _errorMessage = 'Nieprawidłowy adres modułu.';
        });
        return;
      }
      await _controller.loadRequest(handoffUrl);
    } catch (e) {
      setState(() {
        _state = _LoadState.error;
        _errorMessage = 'Nie udało się otworzyć modułu.';
      });
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
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            if (_state == _LoadState.ready)
              IconButton(icon: const Icon(Icons.refresh), onPressed: () => _controller.reload()),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _LoadState.offline:
        return const _MessageState(
          icon: Icons.wifi_off,
          message: 'Ten moduł wymaga połączenia z internetem.',
        );
      case _LoadState.error:
        return _MessageState(
          icon: Icons.error_outline,
          message: _errorMessage ?? 'Nie udało się załadować modułu.',
          actionLabel: 'SPRÓBUJ PONOWNIE',
          onAction: _startHandoff,
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
