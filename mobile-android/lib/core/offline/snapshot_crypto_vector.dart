import 'dart:typed_data';

/// A KNOWN ANSWER for AES-256-GCM, computed by OpenSSL 3.0.13 (through Python
/// `cryptography` 46.0.6), that is by none of the implementations this app has:
/// not the Dart one (pointycastle), not javax.crypto, not CryptoKit.
///
/// Two uses, both about the same question: do the three agree?
///  1. The unit tests check the Dart implementation against it, in both
///     directions (it decrypts the answer, and `package:encrypt` seals the plain
///     text with this IV into exactly these bytes), and that a changed byte is
///     refused.
///  2. At start the app asks the PLATFORM's AES-GCM the same two questions, on
///     the device it is running on, and uses the platform for real data only if
///     both answers are exactly these bytes (SnapshotEncryptor.verifyPlatform).
///     Dart, OpenSSL and the platform then all agree on the layout (IV, then
///     ciphertext, then a 16-byte tag), so what one writes the others read.
///
/// Public constants of a test: not a secret, and not a key anything real uses.
const snapshotVectorKeyHex = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const snapshotVectorIvHex = 'a0a1a2a3a4a5a6a7a8a9aaab';
const snapshotVectorPlainHex = '4d696e69737472616e74204d616e6167657220e28094206b6f706961207374726f6e793a207a61c5bcc3b3c582c4872067c499c59b6cc485206a61c5bac58420e29c93';

/// IV || ciphertext || tag, as SnapshotEncryptor.encryptBytes lays it out.
const snapshotVectorSealedHex =
    'a0a1a2a3a4a5a6a7a8a9aaabab71124436bf70de0c11a79e6614a1b915de79f2'
    '12236207f37e4fe75fd80173bd183ec58f5832f8e35fb70d8bbe04d920dfdf8d'
    'f9bcdefb61346a9b1eb5019056201642ec2f7c3be83a6781e17912228a909d';

Uint8List snapshotVectorBytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
]);
