import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';

/// P10 finding: Szarlej's real, already-deployed footer.php expects a
/// native bridge to hand it a "remember me" continuity token —
/// entirely separate from this app's own mobile_user_token system.
/// Review round: "remember_token może być przekazany do istniejącego
/// bezpiecznego storage, a nie wrzucony do zwykłego cache WebView".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(secureStorageChannel, null);
  });

  group('SecureStorageService legacy remember-token', () {
    test('stores and returns the exact token given', () async {
      final storage = SecureStorageService();
      await storage.setLegacyRememberToken('abc123-legacy-token');
      expect(await storage.legacyRememberToken, 'abc123-legacy-token');
    });

    test('returns null when nothing was ever stored', () async {
      final storage = SecureStorageService();
      expect(await storage.legacyRememberToken, isNull);
    });

    test('deleteLegacyRememberToken actually removes it', () async {
      final storage = SecureStorageService();
      await storage.setLegacyRememberToken('to-be-deleted');
      await storage.deleteLegacyRememberToken();
      expect(await storage.legacyRememberToken, isNull);
    });

    test('clearUserSession() also removes it — a stale legacy token must never survive logout/user-switch', () async {
      final storage = SecureStorageService();
      await storage.setLegacyRememberToken('should-not-survive-logout');
      await storage.clearUserSession();
      expect(await storage.legacyRememberToken, isNull);
    });

    test('is stored under a key separate from the mobile_user_token and db encryption key', () async {
      final storage = SecureStorageService();
      await storage.setLegacyRememberToken('legacy-value');
      final dbKey = await storage.getOrCreateDbEncryptionKey();
      expect(await storage.legacyRememberToken, 'legacy-value', reason: 'generating the db key must never clobber this');
      expect(dbKey, isNot(equals('legacy-value')));
    });
  });
}
