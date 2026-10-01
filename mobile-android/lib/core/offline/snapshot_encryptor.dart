import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;

/// Offline-architecture milestone, P8. Encrypts/decrypts the actual
/// bytes stored for every offline snapshot file (snapshot.html, each
/// asset, manifest.json) — review round: "snapshot może zawierać realny
/// panel użytkownika", the same severity class as the SQLite database,
/// which already gets this treatment (SQLite3MultipleCiphers). This is
/// the general-purpose Dart-level equivalent for plain files, since
/// nothing already in this project's dependencies does that.
///
/// AES-256-GCM: an AEAD cipher, deliberately NOT a bare mode like CBC —
/// decryption fails LOUDLY (throws) if the ciphertext was tampered with
/// or corrupted, rather than silently returning garbage bytes that
/// might otherwise be handed straight to a WebView. A FRESH random
/// 12-byte IV (nonce) is generated for every single [encryptBytes] call
/// and stored, in the clear, as the first 12 bytes of the returned
/// payload — reusing a nonce with the same key is a genuine
/// confidentiality break for GCM specifically, so this class never
/// accepts or reuses a caller-supplied IV; it is ALWAYS freshly
/// generated internally, every time.
///
/// Key management is this class's caller's job (SecureStorageService's
/// own `getOrCreateSnapshotEncryptionKey()`/`deleteSnapshotEncryptionKey()`,
/// mirroring the EXISTING `getOrCreateDbEncryptionKey()` pattern exactly)
/// — this class only ever receives an already-resolved key string.
class SnapshotEncryptor {
  SnapshotEncryptor({required String hexKey}) : _encrypter = enc.Encrypter(enc.AES(_keyFromHex(hexKey), mode: enc.AESMode.gcm));

  final enc.Encrypter _encrypter;

  /// 96 bits — the standard, NIST-recommended IV length for AES-GCM.
  static const _ivLengthBytes = 12;

  static enc.Key _keyFromHex(String hexKey) {
    if (hexKey.length != 64) {
      // 32 bytes == 64 hex characters — matches
      // getOrCreateDbEncryptionKey()'s own key length exactly. Fails
      // loudly rather than silently truncating/padding a wrong-length
      // key into something that LOOKS like it works but uses fewer
      // real key bits than intended.
      throw ArgumentError('Expected a 64-character hex string (32 bytes / AES-256), got ${hexKey.length} characters.');
    }
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = int.parse(hexKey.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return enc.Key(bytes);
  }

  /// Returns `iv (12 bytes) + ciphertext+tag` concatenated — this exact
  /// packed shape is what [decryptBytes] expects back. Never returns the
  /// same bytes twice for the same input, even called twice in a row
  /// with identical [plaintext] — the random IV guarantees that.
  List<int> encryptBytes(List<int> plaintext) {
    final random = Random.secure();
    final ivBytes = Uint8List.fromList(List<int>.generate(_ivLengthBytes, (_) => random.nextInt(256)));
    final iv = enc.IV(ivBytes);
    final encrypted = _encrypter.encryptBytes(plaintext, iv: iv);
    return ivBytes + encrypted.bytes;
  }

  /// Reverses [encryptBytes] exactly. Throws (never returns garbage) if
  /// [packed] is too short to even contain an IV, or if the GCM
  /// authentication tag doesn't match — i.e. the data was corrupted or
  /// tampered with since it was encrypted.
  List<int> decryptBytes(List<int> packed) {
    if (packed.length <= _ivLengthBytes) {
      throw const FormatException('Encrypted payload is too short to contain an IV plus any actual content.');
    }
    final ivBytes = Uint8List.fromList(packed.sublist(0, _ivLengthBytes));
    final cipherBytes = Uint8List.fromList(packed.sublist(_ivLengthBytes));
    final iv = enc.IV(ivBytes);
    final encrypted = enc.Encrypted(cipherBytes);
    return _encrypter.decryptBytes(encrypted, iv: iv);
  }
}
