import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wraps flutter_secure_storage (Android Keystore / iOS Keychain).
/// This is the ONLY place device_token, installation_id, and the resolved
/// parish server_url are persisted. Never write these to SharedPreferences,
/// plain files, or logs (spec §21, §4).
class SecureStorageService {
  SecureStorageService()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
        );

  final FlutterSecureStorage _storage;

  static const _kInstallationId = 'installation_id';
  static const _kDeviceToken = 'device_token';
  static const _kParishId = 'parish_id';
  static const _kParishSlug = 'parish_slug';
  static const _kServerUrl = 'server_url';
  static const _kDbEncryptionKey = 'db_encryption_key';

  Future<String?> get installationId => _storage.read(key: _kInstallationId);
  Future<void> setInstallationId(String value) => _storage.write(key: _kInstallationId, value: value);

  Future<String?> get deviceToken => _storage.read(key: _kDeviceToken);
  Future<void> setDeviceToken(String value) => _storage.write(key: _kDeviceToken, value: value);

  Future<String?> get parishId => _storage.read(key: _kParishId);
  Future<String?> get parishSlug => _storage.read(key: _kParishSlug);
  Future<String?> get serverUrl => _storage.read(key: _kServerUrl);

  Future<void> savedActivation({
    required String parishId,
    required String parishSlug,
    required String serverUrl,
    required String deviceToken,
  }) async {
    await _storage.write(key: _kParishId, value: parishId);
    await _storage.write(key: _kParishSlug, value: parishSlug);
    await _storage.write(key: _kServerUrl, value: serverUrl);
    await _storage.write(key: _kDeviceToken, value: deviceToken);
  }

  /// Called on DEVICE_REVOKED / PARISH_DISABLED / manual "reset activation".
  /// Wipes everything EXCEPT installation_id (spec: the UUID must survive
  /// reinstall-free resets so a re-activation reuses the same identity —
  /// if you want a truly fresh identity on reset, clear this too).
  Future<void> clearActivation() async {
    await _storage.delete(key: _kParishId);
    await _storage.delete(key: _kParishSlug);
    await _storage.delete(key: _kServerUrl);
    await _storage.delete(key: _kDeviceToken);
  }

  Future<bool> get isActivated async => (await deviceToken) != null;

  /// Encryption key for the local SQLCipher database (spec §4 / RODO —
  /// the DB holds altar-server names, attendance, points; a bare
  /// `flutter_secure_storage` for the device token alone is NOT enough,
  /// the database FILE itself must be encrypted). Generated once, on
  /// first app start, and never rotated automatically — losing this key
  /// means the local database becomes unreadable (which is exactly the
  /// point: it should be, to anyone without it).
  Future<String> getOrCreateDbEncryptionKey() async {
    final existing = await _storage.read(key: _kDbEncryptionKey);
    if (existing != null) return existing;

    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final key = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    await _storage.write(key: _kDbEncryptionKey, value: key);
    return key;
  }

  /// Review round 2, point 2 — crypto-erase: called by RevocationHandler
  /// AFTER AppDatabase.closeAndDeleteFiles(), never before (the database
  /// must close cleanly with a still-valid key). Once this returns, the
  /// old key exists nowhere — not in Keystore/Keychain, not anywhere this
  /// app can reach — so even a leftover copy of the (now-deleted) database
  /// file from a backup or crash dump is permanently unreadable. The next
  /// `getOrCreateDbEncryptionKey()` call (on next activation) generates a
  /// genuinely NEW key, never reuses this one.
  Future<void> deleteDbEncryptionKey() => _storage.delete(key: _kDbEncryptionKey);
}
