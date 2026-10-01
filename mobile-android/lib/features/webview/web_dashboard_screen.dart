import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/secure/secure_storage_service.dart';
import 'webview_handoff_service.dart';

/// The real legacy PHP dashboard is the visual source of truth.
/// Online and offline use the same WebView surface; Flutter only owns
/// the small offline status strip and the navigation/back handling.
class WebDashboardScreen extends StatefulWidget {
  const WebDashboardScreen({
    super.key,
    required this.handoffService,
    required this.secureStorage,
    required this.isOnline,
    this.lastSyncAt,
  });

  final WebviewHandoffService handoffService;
  final SecureStorageService secureStorage;
  final bool isOnline;
  final DateTime? lastSyncAt;

  @override
  State<WebDashboardScreen> createState() => _WebDashboardScreenState();
}

enum _DashboardLoadState { loading, ready, error }

class _WebDashboardScreenState extends State<WebDashboardScreen> {
  late final WebViewController _controller;
  _DashboardLoadState _state = _DashboardLoadState.loading;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _state = _DashboardLoadState.ready);
        },
        onWebResourceError: (error) {
          if (mounted) {
            setState(() {
              _state = _DashboardLoadState.error;
              _error = error.description;
            });
          }
        },
        onNavigationRequest: _decideNavigation,
      ));
    _openDashboard();
  }

  NavigationDecision _decideNavigation(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      return NavigationDecision.prevent;
    }
    // This callback cannot await. The initial dashboard URL is validated
    // before loading; same-host navigation is allowed and all other hosts
    // are opened in the system browser.
    final host = uri.host;
    if (_allowedHost == host) return NavigationDecision.navigate;
    launchUrl(uri, mode: LaunchMode.externalApplication);
    return NavigationDecision.prevent;
  }

  String? _allowedHost;

  Future<void> _openDashboard() async {
    try {
      final serverUrl = await widget.secureStorage.serverUrl;
      if (serverUrl == null) throw StateError('Brak serwera parafii.');
      final base = Uri.parse(serverUrl);
      _allowedHost = base.host;

      if (widget.isOnline) {
        final handoff = await widget.handoffService.requestHandoffUrl('/public/dashboard.php');
        if (handoff.host != base.host || handoff.scheme != 'https') {
          throw StateError('Nieprawidłowy adres dashboardu.');
        }
        await _controller.loadRequest(handoff);
      } else {
        // Android/iOS WebView retains the same browser cache used by the
        // online visit. Loading the exact dashboard URL keeps the PHP UI
        // identical; if the cache is unavailable, we show a clear state
        // instead of inventing a second offline UI.
        await _controller.loadRequest(Uri.parse('$serverUrl/public/dashboard.php'));
        // WebView will use its retained browser cache when the device has
        // no network. We deliberately keep the same HTTPS origin so the
        // cached CSS/images/session storage belong to the parish host.
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _DashboardLoadState.error;
          _error = widget.isOnline
              ? 'Nie udało się otworzyć panelu parafii.'
              : 'Brak zapisanej wersji panelu na tym urządzeniu.';
        });
      }
    }
  }

  Future<bool> _handleBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return false;
    }
    return true;
  }

  String _format(DateTime dt) {
    final d = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _handleBack();
        if (shouldPop && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              if (_state == _DashboardLoadState.ready)
                WebViewWidget(controller: _controller)
              else if (_state == _DashboardLoadState.loading)
                const Center(child: CircularProgressIndicator())
              else
                _ErrorState(message: _error ?? 'Nie udało się załadować panelu.', onRetry: _openDashboard),
              if (!widget.isOnline)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: Material(
                    elevation: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      color: Colors.amber.shade100,
                      child: Text(
                        'OFFLINE${widget.lastSyncAt != null ? ' • ostatnie dane: ${_format(widget.lastSyncAt!)}' : ''}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
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
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('SPRÓBUJ PONOWNIE')),
          ],
        ),
      ),
    );
  }
}
