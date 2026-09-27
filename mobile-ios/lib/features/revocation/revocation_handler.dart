import '../../core/database/app_database.dart';
import '../../core/secure/secure_storage_service.dart';
import '../../core/sync/sync_engine.dart';

/// Reacts to DeviceAuthState.revoked / parishDisabled (spec §8/§9) with a
/// genuine CRYPTO-ERASE, not just row deletion (review round 2, point 2):
///   1. wipe rows (best-effort, while the connection still works)
///   2. close the database connection AND delete the SQLite file plus its
///      -wal/-shm/-journal siblings
///   3. delete the database ENCRYPTION KEY from Keystore/Keychain — after
///      this, even a leftover copy of the file (backup, crash dump) is
///      permanently unreadable
///   4. clear the activation token/parish/server_url
///   5. `installation_id` is deliberately left alone (spec: survives resets)
///
/// After this returns, the AppDatabase instance passed to this handler is
/// CLOSED and unusable — the caller (main.dart) MUST construct a fresh
/// AppDatabase (which will generate a brand new key, since the old one no
/// longer exists) before the app can be used again. See
/// main.dart's `_rebuildDatabaseAfterRevocation`.
///
/// This is the ONLY place that permanently deletes local data outside of
/// a user-initiated "reset activation" — never call this speculatively.
class RevocationHandler {
  RevocationHandler({required this.db, required this.secureStorage});

  final AppDatabase db;
  final SecureStorageService secureStorage;

  Future<void> handle(DeviceAuthState state) async {
    if (state != DeviceAuthState.revoked && state != DeviceAuthState.parishDisabled) {
      return;
    }

    // Order matters: rows first (needs a live connection), then the file
    // (needs the connection closed), then the key (only once the file is
    // gone do we destroy the one thing that could ever have decrypted
    // it). Clearing the activation token last means a crash mid-sequence
    // never leaves the app thinking it's still validly activated against
    // data that's already partially destroyed.
    await db.wipeAllParishData();
    await db.closeAndDeleteFiles();
    await secureStorage.deleteDbEncryptionKey();
    await secureStorage.clearActivation();
  }
}
