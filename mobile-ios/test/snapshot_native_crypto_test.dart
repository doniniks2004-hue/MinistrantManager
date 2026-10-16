import 'dart:math';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/snapshot_crypto_vector.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';

/// The platform side (javax.crypto / CryptoKit) cannot run here, so these test
/// the Dart side of the contract against a stand-in that does what the platform
/// does. The real platform is tested where it exists: on the device, at start,
/// by the known-answer check (SnapshotEncryptor.verifyPlatform), which decides
/// whether the platform is used at all and says so in the log.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('eu.ministrant.manager/crypto');
  final encryptor = SnapshotEncryptor(hexKey: 'c' * 64);

  Uint8List bytes(int n, [int seed = 3]) {
    final random = Random(seed);
    return Uint8List.fromList(List<int>.generate(n, (_) => random.nextInt(256)));
  }

  late List<MethodCall> calls;
  late List<String> statuses;

  bool isVectorRequest(Map args) =>
      (args['key'] as Uint8List).length == 32 &&
      (args['key'] as Uint8List).first == 0 &&
      (args['key'] as Uint8List)[1] == 1 &&
      (args['key'] as Uint8List)[31] == 0x1f;

  /// Does what the platform does, with `package:encrypt` as the reference.
  /// [refuseData]: refuses (as the platform does for a payload it cannot open)
  /// every request EXCEPT the known-answer check. [wrongAnswers]: answers the
  /// known-answer check with the wrong bytes (a broken platform).
  Future<void> installStandIn({bool refuseData = false, bool wrongAnswers = false}) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map;
      final key = args['key'] as Uint8List;
      final data = args['data'] as Uint8List;
      expect(key, hasLength(32), reason: 'the key is sent as 32 bytes');
      if (wrongAnswers) {
        return Uint8List.fromList(List<int>.filled(data.length + 28, 7));
      }
      if (refuseData && !isVectorRequest(args)) throw PlatformException(code: 'crypto_failed');
      final aes = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));
      switch (call.method) {
        case 'decrypt':
          // IV (12) ‖ ciphertext ‖ tag
          return Uint8List.fromList(
            aes.decryptBytes(
              enc.Encrypted(Uint8List.fromList(data.sublist(12))),
              iv: enc.IV(Uint8List.fromList(data.sublist(0, 12))),
            ),
          );
        case 'encrypt':
          final iv = args['iv'] as Uint8List;
          expect(iv, hasLength(12));
          // IV ‖ ciphertext ‖ tag, sealed WITH the IV the caller chose.
          return Uint8List.fromList([...iv, ...aes.encryptBytes(data, iv: enc.IV(iv)).bytes]);
      }
      throw MissingPluginException();
    });
    // The check runs once, at start; do it now and forget its two calls so that a
    // test counts only what happens afterwards.
    await SnapshotEncryptor.verifyPlatform();
    calls.clear();
  }

  setUp(() {
    calls = [];
    statuses = [];
    SnapshotEncryptor.debugResetNative();
    SnapshotEncryptor.statusLog = statuses.add;
    messenger.setMockMethodCallHandler(channel, null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    SnapshotEncryptor.debugResetNative();
  });

  group('the platform must prove it agrees before it is used', () {
    test('a platform that reproduces the OpenSSL answer in both directions is verified and used', () async {
      await installStandIn();
      expect(SnapshotEncryptor.platformStatus, startsWith('verified'));
      expect(statuses.single, startsWith('crypto-selftest: verified'));
    });

    test('the check asks the two questions: seal the known text with the known IV, and open the known bytes', () async {
      final seen = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen.add(call);
        final args = call.arguments as Map;
        final key = args['key'] as Uint8List;
        final aes = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));
        if (call.method == 'encrypt') {
          final iv = args['iv'] as Uint8List;
          return Uint8List.fromList([...iv, ...aes.encryptBytes(args['data'] as Uint8List, iv: enc.IV(iv)).bytes]);
        }
        final data = args['data'] as Uint8List;
        return Uint8List.fromList(
          aes.decryptBytes(enc.Encrypted(Uint8List.fromList(data.sublist(12))), iv: enc.IV(Uint8List.fromList(data.sublist(0, 12)))),
        );
      });
      await SnapshotEncryptor.verifyPlatform();

      expect(seen.map((c) => c.method), ['encrypt', 'decrypt']);
      expect((seen[0].arguments as Map)['key'], snapshotVectorBytes(snapshotVectorKeyHex));
      expect((seen[0].arguments as Map)['iv'], snapshotVectorBytes(snapshotVectorIvHex));
      expect((seen[0].arguments as Map)['data'], snapshotVectorBytes(snapshotVectorPlainHex));
      expect((seen[1].arguments as Map)['data'], snapshotVectorBytes(snapshotVectorSealedHex));
    });

    test('a platform that gives WRONG bytes is never used, and the log says MISMATCH', () async {
      await installStandIn(wrongAnswers: true);
      expect(SnapshotEncryptor.platformStatus, startsWith('MISMATCH'));
      expect(statuses.single, contains('NOT USED'));

      final plain = bytes(5000);
      expect(await encryptor.decryptBytesInBackground(encryptor.encryptBytes(plain)), plain);
      expect(await encryptor.encryptBytesInBackground(plain), hasLength(12 + 5000 + 16));
      expect(calls, isEmpty, reason: 'no real data ever went to a platform that disagrees');
      expect(SnapshotEncryptor.nativeCalls, 0);
    });

    test('no platform side: unavailable, Dart does the work', () async {
      messenger.setMockMethodCallHandler(channel, null);
      final plain = bytes(5000);
      expect(await encryptor.decryptBytesInBackground(encryptor.encryptBytes(plain)), plain);
      expect(SnapshotEncryptor.platformStatus, startsWith('unavailable'));
      expect(SnapshotEncryptor.dartCalls, 1);
      expect(SnapshotEncryptor.nativeCalls, 0);
    });

    test('the check runs ONCE however many calls arrive first', () async {
      final seen = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen.add(call.method);
        final args = call.arguments as Map;
        final aes = enc.Encrypter(enc.AES(enc.Key(args['key'] as Uint8List), mode: enc.AESMode.gcm));
        final data = args['data'] as Uint8List;
        if (call.method == 'encrypt') {
          final iv = args['iv'] as Uint8List;
          return Uint8List.fromList([...iv, ...aes.encryptBytes(data, iv: enc.IV(iv)).bytes]);
        }
        return Uint8List.fromList(
          aes.decryptBytes(enc.Encrypted(Uint8List.fromList(data.sublist(12))), iv: enc.IV(Uint8List.fromList(data.sublist(0, 12)))),
        );
      });
      final packed = encryptor.encryptBytes(bytes(3000));
      await Future.wait([for (var i = 0; i < 5; i++) encryptor.decryptBytesInBackground(packed)]);

      expect(seen.where((m) => m == 'encrypt'), hasLength(1), reason: 'one check, shared');
      expect(seen.where((m) => m == 'decrypt'), hasLength(1 + 5), reason: 'the check, then the five real ones');
      expect(statuses, hasLength(1));
    });

    test('a decision once made is not reopened: a platform that appears later is not used', () async {
      final plain = bytes(5000);
      final packed = encryptor.encryptBytes(plain);
      await encryptor.decryptBytesInBackground(packed); // no platform: unavailable
      await installStandIn();
      expect(await encryptor.decryptBytesInBackground(packed), plain);
      expect(calls, isEmpty);
    });
  });

  group('once verified', () {
    test('a page is decrypted by the platform, and the result is the same', () async {
      await installStandIn();
      final plain = bytes(5000);
      expect(await encryptor.decryptBytesInBackground(encryptor.encryptBytes(plain)), plain);
      expect(SnapshotEncryptor.nativeCalls, 1);
      expect(SnapshotEncryptor.dartCalls, 0);
      expect(calls.single.method, 'decrypt');
      expect((calls.single.arguments as Map).keys, unorderedEquals(['key', 'data']));
    });

    test('encrypting through the platform gives bytes the Dart side reads, with the IV that was chosen', () async {
      await installStandIn();
      final plain = bytes(5000);

      final sealed = await encryptor.encryptBytesInBackground(plain);

      expect(SnapshotEncryptor.nativeCalls, 1);
      final iv = (calls.single.arguments as Map)['iv'] as Uint8List;
      expect(sealed.sublist(0, 12), iv, reason: 'IV ‖ ciphertext ‖ tag');
      expect(encryptor.decryptBytes(sealed), plain, reason: 'the Dart implementation reads what the platform wrote');
      expect(sealed.length, 12 + plain.length + 16);
    });

    test('a fresh IV for every encryption', () async {
      await installStandIn();
      final plain = bytes(2000);
      final a = await encryptor.encryptBytesInBackground(plain);
      final b = await encryptor.encryptBytesInBackground(plain);
      expect(a.sublist(0, 12), isNot(b.sublist(0, 12)));
    });

    test('small payloads never go to the platform (the call costs more than the work)', () async {
      await installStandIn();
      final plain = bytes(300);
      expect(await encryptor.decryptBytesInBackground(encryptor.encryptBytes(plain)), plain);
      expect(calls, isEmpty);
      expect(SnapshotEncryptor.dartCalls, 1);
    });

    test('the platform REFUSES a payload: Dart does the work and gives the answer; the platform is asked again next time', () async {
      await installStandIn(refuseData: true);
      final plain = bytes(5000);
      expect(await encryptor.decryptBytesInBackground(encryptor.encryptBytes(plain)), plain);
      expect(calls, hasLength(1));
      expect(SnapshotEncryptor.dartCalls, 1);
      expect(SnapshotEncryptor.nativeCalls, 0);

      await encryptor.decryptBytesInBackground(encryptor.encryptBytes(plain));
      expect(calls, hasLength(2), reason: 'one refusal does not switch a verified platform off');
    });

    test('a payload that does not authenticate is refused, whoever is asked', () async {
      final packed = Uint8List.fromList(encryptor.encryptBytes(bytes(5000)))..[100] ^= 0xff;

      await installStandIn(refuseData: true); // the platform says no ...
      await expectLater(encryptor.decryptBytesInBackground(packed), throwsA(anything)); // ... and so does Dart

      messenger.setMockMethodCallHandler(channel, null);
      SnapshotEncryptor.debugResetNative();
      await expectLater(encryptor.decryptBytesInBackground(packed), throwsA(anything)); // and with no platform at all
    });

    test('the platform answering with nothing falls back to Dart', () async {
      await installStandIn();
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      final plain = bytes(5000);
      expect(await encryptor.decryptBytesInBackground(encryptor.encryptBytes(plain)), plain);
      expect(SnapshotEncryptor.dartCalls, 1);
    });

    test('a payload too short to hold an IV is refused without asking the platform', () async {
      await installStandIn();
      await expectLater(encryptor.decryptBytesInBackground(Uint8List(10)), throwsA(isA<FormatException>()));
      expect(calls, isEmpty);
    });
  });
}
