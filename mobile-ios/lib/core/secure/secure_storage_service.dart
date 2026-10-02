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
  // Review round (milestone: "Mój grafik"): a SEPARATE credential from
  // device_token, deliberately. device_token proves "this physical
  // device is activated and not revoked" (app.ministrant.eu, device
  // control plane); mobile_user_token proves "this specific human is
  // currently signed in" (the parish's own /session/login) — ApiClient.parish()
  // now uses ONLY this one, never device_token.
  static const _kMobileUserToken = 'mobile_user_token';
  static const _kCurrentUserId = 'current_user_id';
  static const _kCurrentUserFullName = 'current_user_full_name';
  static const _kCurrentUserRoleId = 'current_user_role_id';

  Future<String?> get installationId => _storage.read(key: _kInstallationId);
  Future<void> setInstallationId(String value) => _storage.write(key: _kInstallationId, value: value);

  Future<String?> get deviceToken => _storage.read(key: _kDeviceToken);
  Future<void> setDeviceToken(String value) => _storage.write(key: _kDeviceToken, value: value);

  Future<String?> get parishId => _storage.read(key: _kParishId);
  Future<String?> get parishSlug => _storage.read(key: _kParishSlug);
  Future<String?> get serverUrl => _storage.read(key: _kServerUrl);

  Future<String?> get mobileUserToken => _storage.read(key: _kMobileUserToken);

  Future<int?> get currentUserId async {
    final raw = await _storage.read(key: _kCurrentUserId);
    return raw != null ? int.tryParse(raw) : null;
  }

  Future<String?> get currentUserFullName => _storage.read(key: _kCurrentUserFullName);

  /// Hybrid dashboard milestone, review round point 22: the role_id the
  /// dashboard uses for its DISPLAY-only module filter
  /// (ModuleDescriptor.visibleFor) — real enforcement stays server-side.
  Future<int?> get currentUserRoleId async {
    final raw = await _storage.read(key: _kCurrentUserRoleId);
    return raw != null ? int.tryParse(raw) : null;
  }

  Future<bool> get hasUserSession async {
    // Review round fix: must require BOTH — a process interrupted
    // between the individual writes in setUserSession() below (now
    // ordered so this can't happen going forward, but a value already on
    // disk from before this fix could still be in that state) must never
    // read as "there is a session" with a null user id.
    final token = await mobileUserToken;
    final userId = await currentUserId;
    return token != null && userId != null;
  }

  /// Called right after a successful `/session/login`. Review round fix:
  /// writes user_id (and full_name) FIRST, the token LAST — if the app is
  /// killed partway through, the WORST case is "user_id is stored but no
  /// token yet", which `hasUserSession` (above) correctly reads as "no
  /// session" (fails closed). The old order (token first) could leave
  /// "token present, no user_id" after an interruption, which is exactly
  /// the half-written state `hasUserSession` must never treat as valid.
  Future<void> setUserSession({required String token, required int userId, String? fullName, int? roleId}) async {
    await _storage.write(key: _kCurrentUserId, value: userId.toString());
    if (fullName != null) {
      await _storage.write(key: _kCurrentUserFullName, value: fullName);
    } else {
      await _storage.delete(key: _kCurrentUserFullName);
    }
    if (roleId != null) {
      await _storage.write(key: _kCurrentUserRoleId, value: roleId.toString());
    } else {
      await _storage.delete(key: _kCurrentUserRoleId);
    }
    await _storage.write(key: _kMobileUserToken, value: token);
  }

  /// Explicit logout OR the parish API rejecting the current
  /// mobile_user_token with a 401 (review round, point 4 — a USER session
  /// problem, never a device problem). Deliberately leaves installation_id,
  /// device_token, parish_id/slug/server_url completely untouched — logout
  /// (or a session 401) never requires re-scanning the activation QR.
  Future<void> clearUserSession() async {
    await _storage.delete(key: _kMobileUserToken);
    await _storage.delete(key: _kCurrentUserId);
    await _storage.delete(key: _kCurrentUserFullName);
    await _storage.delete(key: _kCurrentUserRoleId);
    // P10: the legacy PHP "remember me" continuity token (see its own
    // field docblock) is issued per-user, at login — a stale one must
    // never survive this specific user's session ending, same as every
    // other credential cleared above.
    await _storage.delete(key: _kLegacyRememberToken);
  }

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
  /// Also clears the user session — a revoked/disabled device can't have
  /// a meaningfully valid signed-in user either.
  Future<void> clearActivation() async {
    await _storage.delete(key: _kParishId);
    await _storage.delete(key: _kParishSlug);
    await _storage.delete(key: _kServerUrl);
    await _storage.delete(key: _kDeviceToken);
    await clearUserSession();
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

  static const _kSnapshotEncryptionKey = 'snapshot_encryption_key';

  /// Offline-architecture milestone, P8.2: the key SnapshotEncryptor uses
  /// for every offline PHP-page snapshot file — review round: "snapshot
  /// może zawierać realny panel użytkownika", the same severity class as
  /// the SQLite database handled by `getOrCreateDbEncryptionKey()` just
  /// above, whose exact generation approach (32 random bytes via
  /// `Random.secure()`, hex-encoded) this mirrors precisely rather than
  /// inventing a second way to do the same thing. Generated once, on
  /// first use, and never rotated automatically — losing this key means
  /// every existing snapshot becomes permanently unreadable (which is
  /// exactly the point: it should be, to anyone without it) and the app
  /// simply falls back to treating every page as having no cached
  /// snapshot (SnapshotStore/LocalSnapshotServer never crash on a
  /// decryption failure — see their own docs).
  ///
  /// Deliberately a SEPARATE key from the database's own — a leak of one
  /// should never automatically compromise the other, and each follows
  /// its own, independent lifecycle below.
  Future<String> getOrCreateSnapshotEncryptionKey() async {
    final existing = await _storage.read(key: _kSnapshotEncryptionKey);
    if (existing != null) return existing;

    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final key = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    await _storage.write(key: _kSnapshotEncryptionKey, value: key);
    return key;
  }

  /// Review round P8.2 — crypto-erase on revoke: "REVOKE -> clear
  /// snapshots -> crypto-erase key", called by RevocationHandler
  /// alongside `deleteDbEncryptionKey()`. Once this returns, even a
  /// leftover/backed-up copy of a snapshot file that somehow survived
  /// SnapshotStore.clearForParish()'s deletion is permanently
  /// unreadable — the key existed only in this app's own secure storage
  /// entry, now gone. The next `getOrCreateSnapshotEncryptionKey()` call
  /// (whenever this device is next activated, for whatever parish)
  /// generates a genuinely NEW key, never reuses this one — matching
  /// `deleteDbEncryptionKey()`'s own exact reasoning.
  Future<void> deleteSnapshotEncryptionKey() => _storage.delete(key: _kSnapshotEncryptionKey);

  static const _kLegacyRememberToken = 'legacy_remember_token';

  /// P10 (real-Szarlej finding): the legacy PHP app's OWN pre-existing
  /// "remember me" mechanism (src/auth.php's issue_remember_token_from_central,
  /// handed to the WebView via footer.php's `_pending_remember_token` ->
  /// MinistrantBridge.saveRememberToken bridge call) — entirely separate
  /// from this app's own mobile_user_token/handoff-ticket system, which
  /// predates it and was built independently ("Iteration 2 point 2" per
  /// session_login.php's own comment; the two "don't need to know about
  /// each other"). Review round: "remember_token może być przekazany do
  /// istniejącego bezpiecznego storage, a nie wrzucony do zwykłego cache
  /// WebView" — stored here, in flutter_secure_storage, specifically so
  /// it is NOT sitting in the WebView's own cookie jar/cache (which
  /// clearActivation()/logout's cookie-clearing could wipe without this
  /// app ever knowing a legacy session-continuity token existed). This
  /// class only stores and returns the token as an opaque string; how
  /// (or whether) it's ever presented back to the legacy PHP app is
  /// outside this round's scope — the server-side consumption mechanism
  /// is pre-existing, separately-built PHP logic this mobile project
  /// doesn't own and doesn't yet have a client-side use for.
  Future<void> setLegacyRememberToken(String token) => _storage.write(key: _kLegacyRememberToken, value: token);

  Future<String?> get legacyRememberToken => _storage.read(key: _kLegacyRememberToken);

  Future<void> deleteLegacyRememberToken() => _storage.delete(key: _kLegacyRememberToken);
}
