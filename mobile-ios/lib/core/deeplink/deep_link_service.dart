import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:meta/meta.dart';

/// Spec §35: thin wrapper around `app_links` that surfaces ONLY the
/// activation token from an incoming
/// `https://app.ministrant.eu/activate/{token}` link — every other URI
/// (or a malformed one) is silently ignored rather than propagated,
/// since this app has exactly one deep-link use case. Requires the
/// platform config in ios/Runner/Runner.entitlements and
/// android/app/src/main/AndroidManifest.xml's App Links intent-filter
/// (both already present but inert until the real fingerprints/Team ID
/// from decision #9 are filled in — see backend's docs-app-links.md).
class DeepLinkService {
  DeepLinkService() : _appLinks = AppLinks();

  /// Review round 2, point 6: the ONLY host this service will ever act
  /// on. Not hardcoded inline in `_extractToken` so a future environment
  /// (staging vs production) can override it via the constructor without
  /// touching the extraction logic itself.
  static const _trustedHost = 'app.ministrant.eu';

  final AppLinks _appLinks;
  StreamSubscription<Uri>? _subscription;

  /// Fires once for the link that actually launched the app cold (if
  /// any), then again for every subsequent link received while the app
  /// is already running. Call [dispose] when the owning widget is
  /// disposed.
  void listen(void Function(String token) onToken) {
    _appLinks.getInitialLink().then((uri) {
      final token = _extractToken(uri);
      if (token != null) onToken(token);
    });

    _subscription = _appLinks.uriLinkStream.listen((uri) {
      final token = _extractToken(uri);
      if (token != null) onToken(token);
    });
  }

  /// Review round 2, point 6 fix: previously accepted ANY URI containing
  /// an `/activate/<something>` path segment, regardless of scheme or
  /// host — so e.g. `http://evil.example/activate/whatever` or
  /// `myapp://activate/whatever` would have been treated exactly like a
  /// genuine app.ministrant.eu link, reaching ActivationScreen's "check
  /// code" flow with an attacker-chosen token. The backend still
  /// validates the token itself (a bogus one just fails activation), so
  /// this was never a way to actually activate against fake data — but a
  /// deep-link parser has no business being loose about scheme/host
  /// when precision costs nothing here.
  @visibleForTesting
  String? extractTokenForTesting(Uri? uri) => _extractToken(uri);

  String? _extractToken(Uri? uri) {
    if (uri == null) return null;
    if (uri.scheme != 'https') return null;
    if (uri.host != _trustedHost) return null;

    final segments = uri.pathSegments;
    final idx = segments.indexOf('activate');
    if (idx == -1 || idx + 1 >= segments.length) return null;

    final token = segments[idx + 1];
    return token.isEmpty ? null : token;
  }

  void dispose() {
    _subscription?.cancel();
  }
}
