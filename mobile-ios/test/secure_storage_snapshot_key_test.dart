import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';

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

  group('SecureStorageService.getOrCreateSnapshotEncryptionKey', () {
    test('generates a 64-character hex key on first call', () async {
      final storage = SecureStorageService();
      final key = await storage.getOrCreateSnapshotEncryptionKey();

      expect(key.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), isTrue);
    });

    test('returns the SAME key on every subsequent call — never regenerates silently', () async {
      final storage = SecureStorageService();
      final first = await storage.getOrCreateSnapshotEncryptionKey();
      final second = await storage.getOrCreateSnapshotEncryptionKey();

      expect(second, first);
    });

    test('is a genuinely DIFFERENT key from the database encryption key — a leak of one must never compromise the other', () async {
      final storage = SecureStorageService();
      final snapshotKey = await storage.getOrCreateSnapshotEncryptionKey();
      final dbKey = await storage.getOrCreateDbEncryptionKey();

      expect(snapshotKey, isNot(equals(dbKey)));
    });

    test('deleteSnapshotEncryptionKey removes it — the NEXT getOrCreate call generates a genuinely new one', () async {
      final storage = SecureStorageService();
      final original = await storage.getOrCreateSnapshotEncryptionKey();

      await storage.deleteSnapshotEncryptionKey();

      final regenerated = await storage.getOrCreateSnapshotEncryptionKey();
      expect(regenerated, isNot(equals(original)), reason: 'review round P8.2 crypto-erase: the old key must be genuinely gone, never reused');
    });

    test('deleteSnapshotEncryptionKey never touches the database encryption key', () async {
      final storage = SecureStorageService();
      final dbKey = await storage.getOrCreateDbEncryptionKey();
      await storage.getOrCreateSnapshotEncryptionKey();

      await storage.deleteSnapshotEncryptionKey();

      expect(await storage.getOrCreateDbEncryptionKey(), dbKey, reason: 'these are two independent keys with two independent lifecycles');
    });
  });
}
