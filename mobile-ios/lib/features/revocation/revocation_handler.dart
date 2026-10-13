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
/// This is the ONLY place that permanently deletes local data — either
/// reactively via [handle] (a server-reported revoked/disabled state) or
/// deliberately via [resetParishManually] (review round P9: a user
/// choosing "Zmień parafię" in settings). Never call either
/// speculatively; both end with the app back at the activation screen.
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
    await _wipeAndDeactivate();
  }

  /// Offline-architecture milestone, P9. Review round decision: "Reset/
  /// zmiana parafii traktujemy jak utratę uprawnień do poprzedniej
  /// parafii" — a user choosing "Zmień parafię" is, security-wise,
  /// exactly the same event as the server saying this device is
  /// revoked: either way, this installation no longer has any business
  /// holding onto the current parish's data. Calling the SAME private
  /// sequence [handle] uses (rather than a second, independently
  /// written copy of it) is what actually guarantees the two paths can
  /// never drift apart — a future change to the wipe sequence only ever
  /// needs to happen in one place.
  ///
  /// Deliberately a separate PUBLIC method from [handle] rather than
  /// just exposing a way to call `handle(DeviceAuthState.revoked)` from
  /// the UI — a manual reset is a genuinely different TRIGGER (a user's
  /// own choice in a settings screen, with its own confirmation dialog)
  /// from a server-reported device state, and giving it its own name
  /// keeps that distinction clear at every call site, including in
  /// tests.
  Future<void> resetParishManually() => _wipeAndDeactivate();

  /// Deletes the saved pages of the current parish AND invalidates the key
  /// that encrypts them, each attempted on its own: a failure to delete the
  /// files (a locked directory, a full disk) must never skip destroying the
  /// key, because a key that is gone makes every surviving file unreadable.
  /// They used to share one try, so the first failure skipped the second.
  ///
  /// Returns whether BOTH steps succeeded. False means the wipe is not
  /// complete (files may remain, or the key may still exist) and must not be
  /// reported as a full erase.
  Future<bool> wipeSnapshotsAndKey() async {
    var complete = true;
    try {
      final parishId = await secureStorage.parishId;
      if (parishId != null) {
        await snapshotStore.clearForParish(parishId: parishId);
      }
    } catch (_) {
      complete = false;
    }
    try {
      await secureStorage.deleteSnapshotEncryptionKey();
    } catch (_) {
      complete = false;
    }
    return complete;
  }

  Future<void> _wipeAndDeactivate() async {
    // Read parishId BEFORE clearActivation() below wipes it — same
    // "can't clear something keyed by a value you've already thrown
    // away" ordering concern as everywhere else parishId/userId feeds a
    // SnapshotStore call. Done first, before anything else in this
    // sequence, and wrapped defensively: a filesystem issue clearing the
    // (unencrypted, lower-stakes) offline page cache must never abort
    // the crypto-erase sequence below, which is what actually matters
    // most for a revoked device.
    //
    // REVOKE -> clear snapshots -> crypto-erase key: the same defence in
    // depth as deleteDbEncryptionKey() below. A copy of a snapshot file that
    // somehow survives the deletion is permanently unreadable once the key
    // is gone. The key is per DEVICE, not per parish, so destroying it on any
    // revocation is always right: the next parish gets a fresh one on its
    // first snapshot write. The two steps are independent (see the method).
    await wipeSnapshotsAndKey();

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
