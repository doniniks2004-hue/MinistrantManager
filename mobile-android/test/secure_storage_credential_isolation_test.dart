import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  test(
    'logout removes credentials even when a native write finishes late',
    () async {
      final values = <String, String>{};
      final started = Completer<void>();
      final release = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments = call.arguments as Map;
            final key = arguments['key'] as String;
            if (call.method == 'read') return values[key];
            if (call.method == 'delete') values.remove(key);
            if (call.method == 'write') {
              if (!started.isCompleted) {
                started.complete();
                await release.future;
              }
              values[key] = arguments['value'] as String;
            }
            return null;
          });
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final storage = SecureStorageService();
      final login = storage.setUserSession(token: 'session-A', userId: 1);
      await started.future;
      final lateBridge = storage.setLegacyRememberToken('remember-A');
      final logout = storage.clearUserSession();
      release.complete();
      await Future.wait([login, lateBridge, logout]);
      expect(await storage.hasUserSession, isFalse);
      expect(await storage.legacyRememberToken, isNull);
      expect(values, isEmpty);
    },
  );
  test('failed account switch never combines old token with new identity', () async {
    final values = <String, String>{
      'mobile_user_token': 'token-A', 'current_user_id': '1',
      'legacy_remember_token': 'remember-A',
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      if (call.method == 'read') return values[key];
      if (call.method == 'delete') values.remove(key);
      if (call.method == 'write') {
        if (key == 'current_user_full_name') throw PlatformException(code: 'disk-error');
        values[key] = args['value'] as String;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final storage = SecureStorageService();
    await expectLater(storage.setUserSession(token: 'token-B', userId: 2, fullName: 'B'), throwsA(isA<PlatformException>()));
    expect(await storage.hasUserSession, isFalse);
    expect(await storage.mobileUserToken, isNull);
    expect(await storage.legacyRememberToken, isNull);
  });

}
