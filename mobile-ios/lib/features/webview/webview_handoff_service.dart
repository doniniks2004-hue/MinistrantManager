import 'package:flutter/foundation.dart';

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
  /// (LegacyModuleScreen / OfflinePageCoordinator) is expected to show
  /// its own error/retry state (or fall back to offline) rather than
  /// this service inventing one.
  ///
  /// K12 diagnostic round: every step logs via debugPrint, on BOTH the
  /// success and failure path — review round's own request, since a
  /// silent fallback to offline gave no way to tell "the server actually
  /// rejected this" from "some precondition was never met" from "it
  /// quietly worked and something ELSE failed afterward". Permanent, not
  /// a throwaway print — never logs mobile_user_token/installation_id
  /// VALUES (only whether they're present), since those are real
  /// credentials; serverUrl and the ticket are logged in full, since
  /// neither is sensitive the same way (the ticket is explicitly
  /// short-lived and single-use by design).
  Future<Uri> requestHandoffUrl(String path) async {
    final serverUrl = await secureStorage.serverUrl;
    final hasToken = await secureStorage.mobileUserToken != null;
    final hasInstallationId = await secureStorage.installationId != null;
    debugPrint(
      'WebviewHandoffService.requestHandoffUrl("$path"): '
      'serverUrl=$serverUrl hasMobileUserToken=$hasToken hasInstallationId=$hasInstallationId',
    );

    final dio = await api.parish();
    debugPrint('WebviewHandoffService: POST ${dio.options.baseUrl}/mobile/webview/handoff');
    final resp = await dio.post('/mobile/webview/handoff', data: {'path': path});
    debugPrint('WebviewHandoffService: handoff response statusCode=${resp.statusCode} body=${resp.data}');

    final ticket = resp.data['ticket'] as String;
    debugPrint('WebviewHandoffService: ticket received (length=${ticket.length})');

    if (serverUrl == null) {
      throw StateError('No server_url — device not activated.');
    }

    final handoffUrl = Uri.parse('$serverUrl/public/mobile_handoff.php').replace(queryParameters: {'ticket': ticket});
    debugPrint('WebviewHandoffService: final handoff URL = $handoffUrl');
    return handoffUrl;
  }
}
