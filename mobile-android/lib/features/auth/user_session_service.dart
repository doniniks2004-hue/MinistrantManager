import 'package:dio/dio.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/database/app_database.dart';
import '../../core/network/api_client.dart';
import '../../core/offline/snapshot_store.dart';
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

/// The credentials are correct, but this legacy account is still in the
/// mandatory first-login/reset state (users.password_changed = 0).
/// No general-purpose mobile_user_token has been issued yet.
class UserLoginPasswordChangeRequired extends UserLoginResult {
  const UserLoginPasswordChangeRequired();
}

/// A transport-level failure (no connectivity, timeout, 5xx) — distinct
/// from invalid credentials so the UI can say "spróbuj ponownie" instead
/// of "sprawdź hasło".
class UserLoginLocalError extends UserLoginResult {
  const UserLoginLocalError();
}

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
  UserSessionService({required this.api, required this.secureStorage, required this.db, required this.snapshotStore});

  final ApiClient api;
  final SecureStorageService secureStorage;
  final AppDatabase db;

  /// Offline-architecture milestone, P7: the SAME security boundary as
  /// db.wipeUserScopedBusinessData() and WebViewCookieManager's cookie
  /// clear just below, for the offline PHP-page snapshot cache
  /// specifically. "Review round, point 3" (this file's own existing
  /// comment on the SQLite wipe) applies identically here — a snapshot
  /// is exactly the kind of "previous user's cached ... etc." data that
  /// comment already describes, just stored as files instead of rows.
  final SnapshotStore snapshotStore;

  /// Override only the transport in tests; all session logic stays production code.
  Dio createLoginClient(BaseOptions options) => Dio(options);

  Future<UserLoginResult> login({required String username, required String password}) =>
      _requestSession('/mobile/session/login', {'username': username, 'password': password});

  Future<UserLoginResult> changeRequiredPassword({
    required String username,
    required String currentPassword,
    required String newPassword,
  }) => _requestSession('/mobile/session/change-password', {
    'username': username,
    'current_password': currentPassword,
    'new_password': newPassword,
  });

  Future<UserLoginResult> _requestSession(String path, Map<String, dynamic> payload) async {
    Dio? client;
    try {
      final installationId = await secureStorage.installationId;
      final serverUrl = await secureStorage.serverUrl;
      if (installationId == null || serverUrl == null) {
        return const UserLoginLocalError();
      }
      client = createLoginClient(BaseOptions(
        baseUrl: '$serverUrl/api/v1',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      ));
      final response = await client.post(path, data: {
        ...payload, 'installation_id': installationId,
      });
      final data = response.data;
      if (data is! Map) return const UserLoginNetworkError();
      final token = data['token'];
      final user = data['user'];
      if (token is! String || token.trim().isEmpty || user is! Map) {
        return const UserLoginNetworkError();
      }
      final userId = user['id'];
      final fullName = user['full_name'];
      final roleId = user['role_id'];
      if (userId is! int || userId <= 0 ||
          (fullName != null && fullName is! String) ||
          (roleId != null && roleId is! int)) {
        return const UserLoginNetworkError();
      }
      final previousUserId = await secureStorage.currentUserId;
      if (previousUserId != null && previousUserId != userId) {
        await db.wipeUserScopedBusinessData();
        await _clearWebviewCookies();
        await _clearSnapshotsForUser(previousUserId);
      }
      await secureStorage.setUserSession(
        token: token, userId: userId,
        fullName: fullName as String?, roleId: roleId as int?,
      );
      api.resetParishClient();
      return UserLoginSuccess(fullName: fullName as String?);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data;
      if ((status == 403 || status == 503) &&
          body is Map && body['error'] == 'device_not_authorized') {
        final state = body['device_state'];
        const states = {'active', 'revoked', 'parish_disabled', 'not_found',
          'parish_mismatch', 'central_unavailable'};
        return UserLoginDeviceNotAuthorized(
          deviceState: state is String && states.contains(state)
              ? state : 'central_unavailable',
        );
      }
      if (status == 428 && body is Map && body['error'] == 'password_change_required') {
        return const UserLoginPasswordChangeRequired();
      }
      if (status == 401 || status == 400 ||
          (status == 409 && path.endsWith('/change-password'))) {
        return const UserLoginInvalidCredentials();
      }
      return const UserLoginNetworkError();
    } catch (_) {
      // Keystore/SQLite failures must never leave the UI awaiting a result.
      // Do not expose exceptions: they can contain credentials or response data.
      return const UserLoginLocalError();
    } finally {
      client?.close();
    }
  }

  /// Explicit logout. Review round, point 3: removes the user session and
  /// wipes user-scoped business data — but deliberately does NOT touch
  /// device activation (installation_id/device_token/parish info) or
  /// global config, so the app returns straight to the LOGIN screen, never
  /// back to QR activation.
  Future<void> logout() async {
    // Offline-architecture milestone, P7: read the user_id BEFORE
    // clearUserSession() wipes it — same ordering concern as every other
    // "what to clear" question here (can't clear something keyed by a
    // value you've already thrown away).
    final userId = await secureStorage.currentUserId;

    await secureStorage.clearUserSession();
    api.resetParishClient();
    await db.wipeUserScopedBusinessData();
    await _clearWebviewCookies();
    if (userId != null) {
      await _clearSnapshotsForUser(userId);
    }
  }

  /// Offline-architecture milestone, P7: review round — "logout ->
  /// clearForUser" and "zmiana użytkownika -> brak starego snapshotu".
  /// Shared by logout() and both user-switch blocks above (login() and
  /// changePassword() can each result in a different human signing in
  /// than whoever was signed in before). Wrapped defensively, same
  /// reasoning as _clearWebviewCookies() just below: a filesystem issue
  /// clearing the offline cache must never abort logout/login itself —
  /// the device-level checks and the user-scoped SQLite wipe (already
  /// completed by the time this runs) are what actually matter for
  /// correctness; this is defense in depth on top of those, not a
  /// precondition for them succeeding.
  Future<void> _clearSnapshotsForUser(int userId) async {
    try {
      final parishId = await secureStorage.parishId;
      if (parishId == null) return;
      await snapshotStore.clearForUser(parishId: parishId, userId: userId.toString());
    } catch (_) {
      // Best-effort — see this method's own docblock.
    }
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
