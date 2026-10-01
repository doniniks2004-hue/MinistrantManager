import 'dart:io';

/// Offline-architecture milestone, P6. Deliberately a REAL reachability
/// probe against the actual target, not OS-level connectivity state
/// (e.g. "is WiFi connected") — matching the SAME principle already
/// established elsewhere in this app (DeviceAuthorizationService's own
/// "central_unavailable" state is likewise derived from an actual
/// failed HTTP attempt, never from querying the OS). A phone can be on
/// WiFi and still unable to reach a specific parish server (captive
/// portal, firewall, DNS issue, the server itself being down) — the
/// only question that actually matters for P6's online/offline decision
/// is "can THIS request to THIS server succeed right now", which only
/// an actual attempt can answer.
class ConnectivityProbe {
  ConnectivityProbe({HttpClient? httpClient, this.timeout = const Duration(seconds: 5)})
      : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;
  final Duration timeout;

  /// True for ANY response at all (200, 404, 500, ...) — reachability,
  /// not whether this exact path exists or succeeds. A HEAD request:
  /// cheap, no body to download, and the legacy PHP app never needs to
  /// actually process this as a real page view.
  Future<bool> canReach(Uri url) async {
    try {
      return await _attempt(url).timeout(timeout, onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _attempt(Uri url) async {
    final request = await _httpClient.headUrl(url);
    final response = await request.close();
    await response.drain<void>();
    return true;
  }
}
