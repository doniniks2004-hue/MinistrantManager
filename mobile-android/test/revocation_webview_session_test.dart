import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart' show DeviceAuthState;
import 'package:ministrant_manager/features/revocation/revocation_handler.dart';

/// The parish pages keep a PHP session for 30 days and do not know about
/// devices, so a session cookie left in the WebView's jar outlives the
/// revocation of the device. Logging a user out cleared it; revoking did not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  final store = <String, String>{};
  late Directory docs;
  late SnapshotStore snapshots;
  var cleared = 0;

  setUp(() async {
    store.clear();
    cleared = 0;
    docs = await Directory.systemTemp.createTemp('mm_revoke_docs_');
    snapshots = SnapshotStore(encryptor: SnapshotEncryptor(hexKey: '1' * 64), rootOverride: docs);
    messenger.setMockMethodCallHandler(pathChannel, (call) async => docs.path);
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      final args = call.arguments as Map?;
      final key = args?['key'] as String?;
      switch (call.method) {
        case 'read':
          return key == null ? null : store[key];
        case 'write':
          final value = args?['value'] as String?;
          if (key != null) value == null ? store.remove(key) : store[key] = value;
          return null;
        case 'delete':
          if (key != null) store.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(store);
        case 'deleteAll':
          store.clear();
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(secureChannel, null);
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  RevocationHandler handler({Future<void> Function()? clear}) => RevocationHandler(
    db: AppDatabase.forTesting(),
    secureStorage: SecureStorageService(),
    snapshotStore: snapshots,
    clearWebViewCookies: clear ?? () async => cleared++,
  );

  Future<void> activate() => SecureStorageService().savedActivation(
    parishId: 'witosa',
    parishSlug: 'witosa',
    serverUrl: 'https://witosa.ministrant.eu',
    deviceToken: 'device-token',
  );

  test('a REVOKED device loses the WebView session', () async {
    await activate();
    await handler().handle(DeviceAuthState.revoked);
    expect(cleared, 1);
  });

  test('a DISABLED parish does too', () async {
    await activate();
    await handler().handle(DeviceAuthState.parishDisabled);
    expect(cleared, 1);
  });

  test('a device that is still authorised keeps its session', () async {
    await activate();
    await handler().handle(DeviceAuthState.active);
    expect(cleared, 0);
  });

  test('a cookie jar that cannot be cleared never stops the rest of the revocation', () async {
    await activate();
    expect(await SecureStorageService().isActivated, isTrue);

    await handler(clear: () async => throw StateError('no WebView binding')).handle(DeviceAuthState.revoked);

    expect(await SecureStorageService().isActivated, isFalse, reason: 'the activation is still cleared');
  });
}
