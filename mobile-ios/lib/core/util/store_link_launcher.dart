import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Review round: HomeScreen and PreflightGate both showed a forced-update
/// screen with an "AKTUALIZUJ" button — HomeScreen's actually opened the
/// store URL, PreflightGate's was a hollow placeholder. One shared
/// implementation now backs both, instead of two independent (and, as it
/// turned out, inconsistent) copies of "launch this URL if non-empty".
class StoreLinkLauncher {
  const StoreLinkLauncher._();

  /// Test seam ONLY — url_launcher's real platform channel can't be
  /// invoked in a plain `flutter test` sandbox (no device/emulator), so
  /// tests substitute this to verify the RIGHT url would have been
  /// launched without needing the actual platform call to succeed.
  /// Always reset to null in `tearDown()`.
  @visibleForTesting
  static Future<bool> Function(Uri url, {LaunchMode mode})? launchUrlOverride;

  /// No-ops silently if [url] is null/empty (spec decision #15: no store
  /// listing published yet — the button simply does nothing extra) or
  /// isn't a parseable URI.
  static Future<void> open(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final launcher = launchUrlOverride ?? launchUrl;
    await launcher(uri, mode: LaunchMode.externalApplication);
  }
}
