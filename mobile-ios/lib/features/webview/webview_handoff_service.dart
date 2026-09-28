import '../../core/network/api_client.dart';
import '../../core/secure/secure_storage_service.dart';

/// Hybrid dashboard milestone (review round, point 18). Requests a
/// short-lived, single-use ticket from the parish backend and builds the
/// URL a WebView navigates to — mobile_user_token itself NEVER appears
/// in this URL, in any JS, or in the WebView at all; only the ticket
/// does, and the ticket authorizes exactly one page load.
class WebviewHandoffService {
  WebviewHandoffService({required this.api, required this.secureStorage});

  final ApiClient api;
  final SecureStorageService secureStorage;

  /// [path] MUST be one of the paths the server itself advertised via a
  /// `webview` module descriptor — the backend independently re-validates
  /// this against its own allowlist regardless, but there is no reason
  /// to ever ask for a path this client didn't get from the server.
  ///
  /// Throws on any failure (network, auth, invalid path) — the caller
  /// (LegacyModuleScreen) is expected to show its own error/retry state
  /// rather than this service inventing one.
  Future<Uri> requestHandoffUrl(String path) async {
    final dio = await api.parish();
    final resp = await dio.post('/mobile/webview/handoff', data: {'path': path});
    final ticket = resp.data['ticket'] as String;

    final serverUrl = await secureStorage.serverUrl;
    if (serverUrl == null) {
      throw StateError('No server_url — device not activated.');
    }

    return Uri.parse('$serverUrl/public/mobile_handoff.php').replace(queryParameters: {'ticket': ticket});
  }
}
