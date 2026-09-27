import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart';

void main() {
  final engine = SyncEngine(
    db: AppDatabase.forTesting(),
    api: ApiClient(SecureStorageService()),
    secureStorage: SecureStorageService(),
  );

  group('SyncEngine status interpretation — mirrors backend DeviceStatusEvaluator', () {
    test('DEVICE_REVOKED maps to DeviceAuthState.revoked', () {
      final result = engine.interpretStatusForTesting({'status': 'DEVICE_REVOKED'});
      expect(result.state, DeviceAuthState.revoked);
    });

    test('PARISH_DISABLED maps to DeviceAuthState.parishDisabled', () {
      final result = engine.interpretStatusForTesting({'status': 'PARISH_DISABLED'});
      expect(result.state, DeviceAuthState.parishDisabled);
    });

    test('UPDATE_REQUIRED maps to DeviceAuthState.updateRequired and carries the minimum version', () {
      final result = engine.interpretStatusForTesting({
        'status': 'UPDATE_REQUIRED',
        'minimum_supported_app_version': '1.2.0',
      });
      expect(result.state, DeviceAuthState.updateRequired);
      expect(result.minimumSupportedAppVersion, '1.2.0');
    });

    test('ACTIVE maps to DeviceAuthState.active — only the exact literal string', () {
      expect(engine.interpretStatusForTesting({'status': 'ACTIVE'}).state, DeviceAuthState.active);
    });

    // Review round fix: was fail-OPEN (unknown/missing status -> active).
    // An unrecognized or missing status string must fail CLOSED instead —
    // never silently treated as active.
    test('an unrecognized status string maps to DeviceAuthState.authError, NOT active', () {
      expect(engine.interpretStatusForTesting({'status': 'SOMETHING_FUTURE_UNKNOWN'}).state, DeviceAuthState.authError);
    });

    test('a missing/null status maps to DeviceAuthState.authError, NOT active', () {
      expect(engine.interpretStatusForTesting({}).state, DeviceAuthState.authError);
      expect(engine.interpretStatusForTesting({'status': null}).state, DeviceAuthState.authError);
    });
  });
}
