import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Same in-memory fake channel as user_session_service_test.dart — real
  // read/write round-trip, not just "always return null".
  const secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final fakeStore = <String, String>{};

  setUp(() {
    fakeStore.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      secureStorageChannel,
      (call) async {
        final args = call.arguments as Map?;
        final key = args?['key'] as String?;
        switch (call.method) {
          case 'read':
            return key != null ? fakeStore[key] : null;
          case 'write':
            final value = args?['value'] as String?;
            if (key != null) {
              if (value == null) {
                fakeStore.remove(key);
              } else {
                fakeStore[key] = value;
              }
            }
            return null;
          case 'delete':
            if (key != null) fakeStore.remove(key);
            return null;
          case 'readAll':
            return Map<String, String>.from(fakeStore);
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(secureStorageChannel, null);
  });

  group('ApiClient.parish() header contract (review round — real bug this closes)', () {
    test('sends BOTH Authorization and X-Installation-Id — missing the latter was a real 400 against the real backend', () async {
      fakeStore['server_url'] = 'https://witosa.ministrant.eu';
      fakeStore['mobile_user_token'] = 'fake-user-token-abc';
      fakeStore['installation_id'] = '550e8400-e29b-41d4-a716-446655440000';

      final secureStorage = SecureStorageService();
      final api = ApiClient(secureStorage);

      final dio = await api.parish();

      expect(dio.options.headers['Authorization'], 'Bearer fake-user-token-abc');
      expect(
        dio.options.headers['X-Installation-Id'],
        '550e8400-e29b-41d4-a716-446655440000',
        reason: 'the parish backend requires this on EVERY business request (mobileapi_device_context()) and 400s without it',
      );
    });

    test('fails closed with StateError when installation_id is missing, even if token+server_url are present', () async {
      fakeStore['server_url'] = 'https://witosa.ministrant.eu';
      fakeStore['mobile_user_token'] = 'fake-user-token-abc';
      // installation_id deliberately NOT set.

      final api = ApiClient(SecureStorageService());

      await expectLater(api.parish(), throwsA(isA<StateError>()));
    });

    test('fails closed with StateError when mobile_user_token is missing, even if installation_id+server_url are present', () async {
      fakeStore['server_url'] = 'https://witosa.ministrant.eu';
      fakeStore['installation_id'] = '550e8400-e29b-41d4-a716-446655440000';
      // mobile_user_token deliberately NOT set.

      final api = ApiClient(SecureStorageService());

      await expectLater(api.parish(), throwsA(isA<StateError>()));
    });
  });
}
