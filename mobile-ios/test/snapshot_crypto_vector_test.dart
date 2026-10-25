import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/snapshot_crypto_vector.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';

/// The Dart implementation against an answer it did not compute: bytes sealed by
/// OpenSSL 3.0.13. If these pass, Dart and OpenSSL agree on AES-256-GCM and on
/// the layout (IV, ciphertext, 16-byte tag); the platform is held to the same
/// bytes on the device (SnapshotEncryptor.verifyPlatform), so all three agree.
void main() {
  final key = snapshotVectorBytes(snapshotVectorKeyHex);
  final iv = snapshotVectorBytes(snapshotVectorIvHex);
  final plain = snapshotVectorBytes(snapshotVectorPlainHex);
  final sealed = snapshotVectorBytes(snapshotVectorSealedHex);
  final encryptor = SnapshotEncryptor(hexKey: snapshotVectorKeyHex);

  test('the vector is what it claims to be', () {
    expect(key, hasLength(32));
    expect(iv, hasLength(12));
    expect(sealed, hasLength(12 + plain.length + 16), reason: 'IV, ciphertext (as long as the plain text), 16-byte tag');
    expect(sealed.sublist(0, 12), iv);
  });

  test('Dart OPENS what OpenSSL sealed', () {
    expect(encryptor.decryptBytes(sealed), plain);
  });

  test('Dart SEALS the same text with the same IV into exactly the bytes OpenSSL produced', () {
    final aes = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));
    expect(Uint8List.fromList([...iv, ...aes.encryptBytes(plain, iv: enc.IV(iv)).bytes]), sealed);
  });

  test('a changed byte, in the ciphertext or in the tag, is refused', () {
    for (final index in [12, 40, sealed.length - 1]) {
      final tampered = Uint8List.fromList(sealed)..[index] ^= 1;
      expect(() => encryptor.decryptBytes(tampered), throwsA(anything), reason: 'byte $index');
    }
  });

  test('the same bytes under another key are refused', () {
    expect(() => SnapshotEncryptor(hexKey: 'f' * 64).decryptBytes(sealed), throwsA(anything));
  });

  test('the plain text really is non-ASCII (Polish letters and a symbol), so a byte-level slip would show', () {
    expect(plain.any((b) => b > 127), isTrue);
  });
}
