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
  /// subdomain, with the device token attached. Throws if activation
  /// hasn't happened yet — callers must check SecureStorageService.isActivated
  /// first.
  Future<Dio> parish() async {
    if (_parishDio != null) return _parishDio!;

    final serverUrl = await _secureStorage.serverUrl;
    final token = await _secureStorage.deviceToken;
    if (serverUrl == null || token == null) {
      throw StateError('App not activated — no parish server_url/device_token in secure storage.');
    }

    _parishDio = Dio(BaseOptions(
      baseUrl: '$serverUrl/api/v1',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {'Authorization': 'Bearer $token'},
    ));
    return _parishDio!;
  }

  /// Call after activation, or after any change to the stored device token,
  /// so a stale Authorization header is never reused.
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
