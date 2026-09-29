import 'package:dio/dio.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/database/app_database.dart';
import '../../core/network/api_client.dart';
import '../../core/secure/secure_storage_service.dart';

/// Outcome of a login attempt — deliberately a closed set the UI switches
/// on, rather than a raw exception, so LoginScreen can show the right
/// message without needing to know Dio/HTTP status-code details itself.
sealed class UserLoginResult {
  const UserLoginResult();
}

class UserLoginSuccess extends UserLoginResult {
  const UserLoginSuccess({required this.fullName});
  final String? fullName;
}

/// Wrong username/password, OR the account is rate-limited — the backend
/// deliberately reports both the same way (see LegacyPasswordAuthenticator
/// on the backend), so this client can't and shouldn't try to tell them
/// apart either.
class UserLoginInvalidCredentials extends UserLoginResult {
  const UserLoginInvalidCredentials();
}

/// A transport-level failure (no connectivity, timeout, 5xx) — distinct
/// from invalid credentials so the UI can say "spróbuj ponownie" instead
/// of "sprawdź hasło".
class UserLoginNetworkError extends UserLoginResult {
  const UserLoginNetworkError();
}

/// Device-control-plane milestone (review round point 8): the PARISH
/// confirmed the password was correct, but app.ministrant.eu says this
/// installation is NOT authorized right now (revoked / parish_disabled /
/// not_found / parish_mismatch / central_unavailable). Deliberately its
/// OWN result type — NEVER shown as "zły login/hasło" (the password WAS
/// right) and NEVER as a generic network problem (revoked/disabled/
/// mismatch are affirmative answers, not a hiccup) — review round:
/// "wymuś ponowne sprawdzenie device status przez centralny flow", which
/// is exactly what [deviceState] lets the caller distinguish:
/// 'central_unavailable' is retriable (try again shortly); the other
/// four states mean a human needs to sort this out (contact whoever
/// manages the parish's devices).
class UserLoginDeviceNotAuthorized extends UserLoginResult {
  const UserLoginDeviceNotAuthorized({required this.deviceState});
  final String deviceState;
}

/// Session/device management around `/api/v1/mobile/session/login` —
/// deliberately separate from ActivationService (device-level) and from
/// SyncEngine (business-data sync). This is specifically "which human is
/// signed in on this already-activated device" (milestone "Mój grafik",
/// review round).
class UserSessionService {
  UserSessionService({required this.api, required this.secureStorage, required this.db});

  final ApiClient api;
  final SecureStorageService secureStorage;
  final AppDatabase db;

  Future<UserLoginResult> login({required String username, required String password}) async {
    final installationId = await secureStorage.installationId;
    final serverUrl = await secureStorage.serverUrl;
    if (installationId == null || serverUrl == null) {
      // Shouldn't normally be reachable — LoginScreen only ever shows once
      // the device is already activated — but fail closed rather than
      // send a request with a missing field.
      return const UserLoginNetworkError();
    }

    final loginDio = Dio(BaseOptions(
      baseUrl: '$serverUrl/api/v1',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));

    try {
      final resp = await loginDio.post('/mobile/session/login', data: {
        'username': username,
        'password': password,
        'installation_id': installationId,
      });
      final data = resp.data as Map<String, dynamic>;
      final token = data['token'] as String;
      final user = data['user'] as Map<String, dynamic>;
      final newUserId = user['id'] as int;
      final fullName = user['full_name'] as String?;
      final roleId = user['role_id'] as int?;

      // Review round, point 3 — the whole reason this method exists as
      // more than a one-line HTTP call: if a DIFFERENT human is signing
      // in than whoever was signed in on this device before, the
      // previous user's cached schedule/attendance/points/etc. must be
      // gone BEFORE this method returns — i.e. before the caller shows
      // ANY app content — never "for a moment" while a fresh bootstrap
      // catches up in the background.
      final previousUserId = await secureStorage.currentUserId;
      if (previousUserId != null && previousUserId != newUserId) {
        await db.wipeUserScopedBusinessData();
        await _clearWebviewCookies();
      }

      await secureStorage.setUserSession(token: token, userId: newUserId, fullName: fullName, roleId: roleId);
      // A stale Authorization header (no token, or the previous user's)
      // must never be reused for the very next parish API call.
      api.resetParishClient();

      return UserLoginSuccess(fullName: fullName);
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;

      // Device-control-plane milestone: 403/503 with error code
      // "device_not_authorized" is NEVER "zły login/hasło" — the
      // password was correct; app.ministrant.eu just won't authorize
      // this installation right now. Checked BEFORE the 401/400 case
      // below since these status codes never overlap with it in this
      // backend's design (device_not_authorized is only ever 403/503).
      if (statusCode == 403 || statusCode == 503) {
        final body = e.response?.data;
        final deviceState = (body is Map ? body['device_state'] as String? : null) ?? 'central_unavailable';
        return UserLoginDeviceNotAuthorized(deviceState: deviceState);
      }

      if (statusCode == 401 || statusCode == 400) {
        return const UserLoginInvalidCredentials();
      }
      return const UserLoginNetworkError();
    }
  }

  /// Explicit logout. Review round, point 3: removes the user session and
  /// wipes user-scoped business data — but deliberately does NOT touch
  /// device activation (installation_id/device_token/parish info) or
  /// global config, so the app returns straight to the LOGIN screen, never
  /// back to QR activation.
  Future<void> logout() async {
    await secureStorage.clearUserSession();
    api.resetParishClient();
    await db.wipeUserScopedBusinessData();
    await _clearWebviewCookies();
  }

  /// Review round point 19: "Bartek po Adamie nie może odziedziczyć ...
  /// sesji PHP Adama" — the WebView's cookie jar is shared across EVERY
  /// LegacyModuleScreen instance (it's the platform's single WebView
  /// cookie store, not per-widget), so a stale PHP session cookie from
  /// the previous user must be gone before the next one could ever open
  /// a legacy module and silently inherit it. Wrapped defensively — a
  /// platform without a real WebView binding (e.g. a unit test with no
  /// platform channel registered) must never abort logout/user-switch
  /// over this; the user-scoped SQLite wipe above is what actually
  /// matters for correctness, this is defense in depth on top of it.
  Future<void> _clearWebviewCookies() async {
    try {
      await WebViewCookieManager().clearCookies();
    } catch (_) {
      // Best-effort — see docblock above.
    }
  }

  /// Review round, point 4: the PARISH API (not app.ministrant.eu)
  /// rejected the current mobile_user_token with a 401 — a USER session
  /// problem, never a device problem. Clears ONLY the user session
  /// (identical effect to [logout] on local state) so the app routes back
  /// to the login screen — never treated as DEVICE_REVOKED, never clears
  /// installation_id/device_token, never re-triggers QR activation.
  Future<void> handleParishSessionExpired() => logout();
}
