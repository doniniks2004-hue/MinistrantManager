import 'package:dio/dio.dart';
import '../secure/secure_storage_service.dart';

/// Two distinct backends are talked to, and the app must never confuse them
/// (spec §1 / §13 / §23):
///
///  - centralHost (app.ministrant.eu): activation, device heartbeat/status.
///    Fixed, hardcoded base URL — this is the one and only thing baked
///    into the app at build time.
///  - parishHost (e.g. chwk.ministrant.eu): bootstrap/sync/actions for
///    business data. This base URL is NEVER hardcoded — it's whatever
///    `server_url` the central host returned at activation time, read
///    fresh from SecureStorageService.
class ApiClient {
  ApiClient(this._secureStorage)
      : central = Dio(BaseOptions(
          baseUrl: centralBaseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        ));

  /// The only hardcoded host in the whole app.
  static const centralBaseUrl = 'https://app.ministrant.eu/api';

  final SecureStorageService _secureStorage;
  final Dio central;

  Dio? _parishDio;

  /// Lazily builds (and caches) a Dio instance pointed at the parish's own
  /// subdomain, with the MOBILE USER TOKEN attached (review round,
  /// milestone "Mój grafik", point 1: this used to send the CENTRAL
  /// device_token — wrong credential entirely. device_token proves the
  /// DEVICE is activated; it says nothing about which human is signed in,
  /// and the parish's own /mobile/* endpoints authenticate the USER, not
  /// the device). Throws if the device isn't activated yet OR no user is
  /// signed in yet — callers must check SecureStorageService.isActivated
  /// and .hasUserSession first.
  ///
  /// Review round fix (real bug — the parish backend's
  /// `mobileapi_device_context()` requires this on EVERY business
  /// request and returns 400 `missing_installation_id` without it, which
  /// the app would have silently treated as "no schedule" — see
  /// HomeScreen's contract-error handling): also attaches
  /// `X-Installation-Id`, fetched fresh from SecureStorageService, same
  /// as `Authorization`. Both are required for `parish()` to be usable at
  /// all — missing EITHER one fails closed with a StateError, never a
  /// half-built client that would just 400 on first use.
  Future<Dio> parish() async {
    if (_parishDio != null) return _parishDio!;

    final serverUrl = await _secureStorage.serverUrl;
    final token = await _secureStorage.mobileUserToken;
    final installationId = await _secureStorage.installationId;
    if (serverUrl == null || token == null || installationId == null) {
      // K12 diagnostic round: names WHICH field is actually missing —
      // the previous generic message made "not activated" and "not
      // signed in yet" indistinguishable from each other, which is
      // exactly the ambiguity being chased right now on a real device
      // where the symptom (silent fallback to offline) gives no hint on
      // its own which precondition actually failed.
      final missing = [
        if (serverUrl == null) 'server_url',
        if (token == null) 'mobile_user_token',
        if (installationId == null) 'installation_id',
      ].join(', ');
      throw StateError('Parish API not ready — missing: $missing.');
    }

    _parishDio = Dio(BaseOptions(
      baseUrl: '$serverUrl/api/v1',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'Authorization': 'Bearer $token',
        'X-Installation-Id': installationId,
      },
    ));
    return _parishDio!;
  }

  /// Call after activation, after login, after logout, or after any change
  /// to the stored mobile_user_token, so a stale Authorization header
  /// (the previous user's token, or none at all) is never reused.
  void resetParishClient() => _parishDio = null;

  Dio centralWithAuth(String deviceToken) {
    return Dio(BaseOptions(
      baseUrl: centralBaseUrl,
      headers: {'Authorization': 'Bearer $deviceToken'},
      // Review round: `central` (below) already had timeouts; this client
      // didn't — an unresponsive server could hang checkDeviceStatus()
      // indefinitely instead of failing into the offline-lease path.
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
  }
}
