import '../../core/database/app_database.dart';
import '../../core/offline/snapshot_store.dart';
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
  RevocationHandler({required this.db, required this.secureStorage, required this.snapshotStore});

  final AppDatabase db;
  final SecureStorageService secureStorage;

  /// Offline-architecture milestone, P7: review round — "revoke ->
  /// clearForParish". Without this, a revoked/disabled parish's cached
  /// offline PHP pages would simply keep working forever on this device
  /// — a genuine way to bypass the revocation entirely, since
  /// OfflinePageCoordinator's offline branch has no idea a parish was
  /// ever revoked; it only knows "can I reach the server" and "is there
  /// a snapshot". The snapshot files themselves are, unlike the SQLite
  /// database handled below, NOT separately encrypted at rest today —
  /// a real question worth raising with Dominik, not something to
  /// silently decide in this round, which is scoped to clearing/
  /// isolation specifically.
  final SnapshotStore snapshotStore;

  Future<void> handle(DeviceAuthState state) async {
    if (state != DeviceAuthState.revoked && state != DeviceAuthState.parishDisabled) {
      return;
    }

    // Read parishId BEFORE clearActivation() below wipes it — same
    // "can't clear something keyed by a value you've already thrown
    // away" ordering concern as everywhere else parishId/userId feeds a
    // SnapshotStore call. Done first, before anything else in this
    // sequence, and wrapped defensively: a filesystem issue clearing the
    // (unencrypted, lower-stakes) offline page cache must never abort
    // the crypto-erase sequence below, which is what actually matters
    // most for a revoked device.
    try {
      final parishId = await secureStorage.parishId;
      if (parishId != null) {
        await snapshotStore.clearForParish(parishId: parishId);
      }
      // Offline-architecture milestone, P8.2 — "REVOKE -> clear
      // snapshots -> crypto-erase key", the SAME defense-in-depth
      // reasoning as deleteDbEncryptionKey() just below: even a
      // leftover/backed-up copy of a snapshot file that somehow
      // survived clearForParish()'s deletion is permanently unreadable
      // once the key itself is gone. The key is per-DEVICE, not
      // per-parish (a device is only ever activated for one parish at a
      // time), so destroying it on any revocation is always correct —
      // whatever parish this device is activated for NEXT gets a
      // genuinely fresh key on first snapshot write.
      await secureStorage.deleteSnapshotEncryptionKey();
    } catch (_) {
      // Best-effort — see this field's own docblock.
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
