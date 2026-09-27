import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';
import 'dart:io' show Platform;

import '../../core/network/api_client.dart';
import '../../core/secure/secure_storage_service.dart';

class ActivationResult {
  ActivationResult({required this.parishName, required this.serverUrl});
  final String parishName;
  final String serverUrl;
}

class ActivationError implements Exception {
  ActivationError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Drives spec §18–§21: resolve a scanned/typed code against
/// app.ministrant.eu, confirm activation, persist installation_id +
/// device_token, and point ApiClient at the returned parish server_url.
class ActivationService {
  ActivationService({required this.api, required this.secureStorage});

  final ApiClient api;
  final SecureStorageService secureStorage;
  final _uuid = const Uuid();

  /// The ONLY host a scanned/typed value is trusted to represent an
  /// activation link for — mirrors DeepLinkService's identical constant
  /// (spec §35, review round: QR parser must be as strict as the App
  /// Link handler, not looser).
  static const _trustedHost = 'app.ministrant.eu';

  /// Extracts the token from a scanned QR value shaped like
  /// "https://app.ministrant.eu/activate/{token}" (spec §12), or returns
  /// the raw value unchanged if it's already a bare token/display code
  /// (no recognizable URL structure at all — its own validity is the
  /// backend's job to check, same as always).
  ///
  /// Review round fix: a value that DOES look like an activation link
  /// (has an `/activate/{token}` path) but is on the WRONG host/scheme is
  /// no longer extracted and passed through as if it were ours — e.g.
  /// `https://evil.example/activate/abc` used to yield `abc` exactly like
  /// a genuine app.ministrant.eu link would. The backend still rejects an
  /// unknown token either way (this was never an auth bypass), but the
  /// QR parser has no business being any looser than DeepLinkService's
  /// own App Link handler is.
  ///
  /// Returns null (never a token) for a link that IS activation-shaped
  /// but fails host/scheme validation — the caller should treat that as
  /// "not one of ours", not attempt an activation check with it.
  String? extractTokenFromQr(String scannedValue) {
    final trimmed = scannedValue.trim();
    final uri = Uri.tryParse(trimmed);

    final looksLikeUrl = uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    if (!looksLikeUrl) {
      // No recognizable URL shape at all — treat as a bare code/token,
      // same as always.
      return trimmed;
    }

    final segments = uri.pathSegments;
    final idx = segments.indexOf('activate');
    final isActivationShaped = idx != -1 && idx + 1 < segments.length;

    if (!isActivationShaped) {
      // Some other, unrelated URL — not an activation link at all, so
      // host/scheme validation doesn't even apply. Harmless either way:
      // the backend rejects whatever this resolves to as an unknown code.
      return trimmed;
    }

    if (uri.scheme != 'https' || uri.host != _trustedHost) {
      return null;
    }

    return segments[idx + 1];
  }

  Future<String> _installationId() async {
    final existing = await secureStorage.installationId;
    if (existing != null) return existing;
    final generated = _uuid.v4();
    await secureStorage.setInstallationId(generated);
    return generated;
  }

  Future<Map<String, String>> _deviceMeta() async {
    final pkgInfo = await PackageInfo.fromPlatform();
    final deviceInfo = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      return {
        'platform': 'android',
        'device_model': '${info.manufacturer} ${info.model}',
        'os_version': 'Android ${info.version.release}',
        'app_version': pkgInfo.version,
      };
    } else {
      final info = await deviceInfo.iosInfo;
      return {
        'platform': 'ios',
        'device_model': info.utsname.machine,
        'os_version': 'iOS ${info.systemVersion}',
        'app_version': pkgInfo.version,
      };
    }
  }

  /// Step 1 (spec §12): resolve token/display_code -> parish, WITHOUT
  /// consuming the code or registering a device yet. Used to show the
  /// "✓ Znaleziono parafię ... [AKTYWUJ]" confirmation screen.
  Future<ActivationResult> checkCode({String? token, String? displayCode}) async {
    try {
      final resp = await api.central.post('/activation/check', data: {
        if (token != null) 'token': token,
        if (displayCode != null) 'display_code': displayCode,
      });
      final parish = resp.data['parish'] as Map<String, dynamic>;
      return ActivationResult(parishName: parish['name'] as String, serverUrl: parish['server_url'] as String);
    } catch (_) {
      throw ActivationError('Kod aktywacyjny jest nieprawidłowy, wygasł lub został unieważniony.');
    }
  }

  /// Step 2 (spec §20–§21): actually register this installation and
  /// obtain a device_token. Persists everything needed for SyncEngine to
  /// start talking to the parish server immediately after this returns.
  Future<ActivationResult> confirmActivation({String? token, String? displayCode}) async {
    final installationId = await _installationId();
    final meta = await _deviceMeta();

    try {
      final resp = await api.central.post('/activation/confirm', data: {
        if (token != null) 'token': token,
        if (displayCode != null) 'display_code': displayCode,
        'installation_id': installationId,
        ...meta,
      });

      final parish = resp.data['parish'] as Map<String, dynamic>;
      final device = resp.data['device'] as Map<String, dynamic>;

      await secureStorage.savedActivation(
        parishId: parish['id'].toString(),
        parishSlug: parish['slug'] as String,
        serverUrl: parish['server_url'] as String,
        deviceToken: device['device_token'] as String,
      );
      api.resetParishClient();

      return ActivationResult(parishName: parish['name'] as String, serverUrl: parish['server_url'] as String);
    } catch (_) {
      throw ActivationError('Aktywacja nie powiodła się. Kod mógł zostać już wykorzystany lub unieważniony.');
    }
  }
}
