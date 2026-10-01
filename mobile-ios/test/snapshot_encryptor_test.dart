import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';

void main() {
  // A fixed, valid 32-byte (64 hex char) test key — never a real key,
  // just something of the exact right shape getOrCreateDbEncryptionKey()
  // would also produce.
  const testKey = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

  group('SnapshotEncryptor', () {
    test('round-trips plain text exactly', () {
      final encryptor = SnapshotEncryptor(hexKey: testKey);
      final plaintext = utf8.encode('<html><body>Dashboard</body></html>');

      final packed = encryptor.encryptBytes(plaintext);
      final decrypted = encryptor.decryptBytes(packed);

      expect(utf8.decode(decrypted), '<html><body>Dashboard</body></html>');
    });

    test('round-trips arbitrary binary content exactly (not just UTF-8 text)', () {
      final encryptor = SnapshotEncryptor(hexKey: testKey);
      // Bytes that are NOT valid UTF-8 on their own -- simulating real
      // image/font binary content, not text.
      final binary = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xD8, 0x00, 0x01, 0x02, 0x03];

      final packed = encryptor.encryptBytes(binary);
      final decrypted = encryptor.decryptBytes(packed);

      expect(decrypted, binary);
    });

    test('the packed output is NOT the plaintext in recognizable form', () {
      final encryptor = SnapshotEncryptor(hexKey: testKey);
      const secret = 'Ministrant Jan Kowalski — Grafik Szarlej';
      final packed = encryptor.encryptBytes(utf8.encode(secret));

      // A crude but meaningful sanity check: the literal plaintext bytes
      // must not appear as a contiguous run anywhere in the stored
      // payload -- this is what "encrypted at rest" actually means in
      // practice, not just "some function was called".
      final packedString = String.fromCharCodes(packed.where((b) => b < 256));
      expect(packedString.contains('Kowalski'), isFalse);
      expect(packedString.contains('Szarlej'), isFalse);
    });

    test(
      'review round requirement: encrypting the SAME plaintext twice never produces the same bytes — proves the IV is actually randomized, not reused',
      () {
        final encryptor = SnapshotEncryptor(hexKey: testKey);
        final plaintext = utf8.encode('identical content both times');

        final packedOnce = encryptor.encryptBytes(plaintext);
        final packedTwice = encryptor.encryptBytes(plaintext);

        expect(packedOnce, isNot(equals(packedTwice)), reason: 'nonce reuse with the same key is a real confidentiality break for GCM specifically');
        // But both must still independently decrypt back to the same plaintext.
        expect(utf8.decode(encryptor.decryptBytes(packedOnce)), 'identical content both times');
        expect(utf8.decode(encryptor.decryptBytes(packedTwice)), 'identical content both times');
      },
    );

    test('tampering with even one byte of the ciphertext causes decryption to throw, never to return garbage silently', () {
      final encryptor = SnapshotEncryptor(hexKey: testKey);
      final packed = encryptor.encryptBytes(utf8.encode('untampered content'));

      final tampered = List<int>.from(packed);
      tampered[tampered.length - 1] = tampered[tampered.length - 1] ^ 0xFF; // flip the last byte

      expect(() => encryptor.decryptBytes(tampered), throwsA(anything));
    });

    test('decrypting with the WRONG key throws rather than returning garbage', () {
      // Per Dominik's exact diagnosis: the previous hand-typed literal
      // was 62 characters, not the required 64 -- the constructor
      // correctly rejected it before this test ever reached the actual
      // thing it meant to check (decrypting with a DIFFERENT but
      // VALID-length key). Built programmatically here instead of as a
      // hand-counted literal, specifically so this exact mistake can't
      // happen again.
      final otherKey = 'f' * 64;
      final encryptor = SnapshotEncryptor(hexKey: testKey);
      final wrongKeyEncryptor = SnapshotEncryptor(hexKey: otherKey);

      final packed = encryptor.encryptBytes(utf8.encode('encrypted with the real key'));

      expect(() => wrongKeyEncryptor.decryptBytes(packed), throwsA(anything));
    });

    test('a key of the wrong length is rejected immediately, never silently truncated or padded', () {
      expect(() => SnapshotEncryptor(hexKey: 'tooshort'), throwsArgumentError);
      expect(() => SnapshotEncryptor(hexKey: testKey + 'ab'), throwsArgumentError);
    });

    test('a payload too short to contain an IV is rejected rather than misread', () {
      final encryptor = SnapshotEncryptor(hexKey: testKey);
      expect(() => encryptor.decryptBytes([1, 2, 3]), throwsFormatException);
    });

    test('empty plaintext round-trips correctly (an empty manifest.json edge case, say)', () {
      final encryptor = SnapshotEncryptor(hexKey: testKey);
      final packed = encryptor.encryptBytes(<int>[]);
      final decrypted = encryptor.decryptBytes(packed);
      expect(decrypted, isEmpty);
    });
  });
}
