import 'dart:async';

import 'package:webview_flutter/webview_flutter.dart' show WebViewCookieManager;
import '../../core/database/app_database.dart';
import '../../core/offline/snapshot_encryptor.dart';
import '../../core/offline/snapshot_store.dart';
import '../../core/secure/secure_storage_service.dart';
import '../../core/security/wipe_lock.dart';
import '../../core/sync/sync_engine.dart';
import 'wipe_marker.dart';

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
  RevocationHandler({
    required this.db,
    required this.secureStorage,
    required this.snapshotStore,
    Future<void> Function()? clearWebViewCookies,
    WipeMarkerStore? markerStore,
    WipeMarkerStore? fallbackMarkerStore,
    Future<void> Function(String step)? afterStep, // for tests only: see [_afterStep]
    Future<void> Function()? deleteDatabaseFiles,
    Future<bool> Function()? databaseFilesRemain,
    DateTime Function()? now,
    WipeLock? wipeLock,
  }) : wipeLock = wipeLock ?? WipeLock(),
       _clearWebViewCookies = clearWebViewCookies ?? _clearPlatformCookies,
       _markers = WipeMarkers([
         markerStore ?? secureStorage.wipeMarkerStore,
         fallbackMarkerStore ?? FileWipeMarkerStore(),
       ]),
       _afterStep = afterStep,
       _deleteDatabaseFiles = deleteDatabaseFiles ?? AppDatabase.deleteDatabaseFiles,
       _databaseFilesRemain = databaseFilesRemain ?? AppDatabase.databaseFilesRemain,
       _now = now ?? DateTime.now;

  final WipeMarkers _markers;

  /// Held from the start of a wipe until it is confirmed complete (see [WipeLock]). Shared with the
  /// coordinator that hands out saved copies and with the screen that shows the panel.
  final WipeLock wipeLock;

  /// Test hook, called after each step of the wipe and OUTSIDE the error handling of the step: a
  /// throw from it ends the wipe at that point, as a process that dies there would.
  final Future<void> Function(String step)? _afterStep;

  /// How the last wipe went (see [WipeOutcome]). Null before any.
  WipeOutcome? lastOutcome;

  /// The wipe that was started in THIS process and is not complete, kept so that it can be tried
  /// again ([retryIncompleteWipe]) even when no marker could be stored for it.
  WipeMarker? _pending;

  /// True while a wipe started in this process is not complete.
  bool get hasIncompleteWipe => _pending != null;
  final Future<void> Function() _deleteDatabaseFiles;
  final Future<bool> Function() _databaseFilesRemain;
  final DateTime Function() _now;

  final Future<void> Function() _clearWebViewCookies;

  static Future<void> _clearPlatformCookies() =>
      WebViewCookieManager().clearCookies();

  /// Null when the handler finishes a wipe at startup, when no database has been opened.
  final AppDatabase? db;
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
    await _wipeAndDeactivate(
      state == DeviceAuthState.revoked ? WipeReason.revoked : WipeReason.parishDisabled,
    );
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
  Future<void> resetParishManually() => _wipeAndDeactivate(WipeReason.manualReset);
  // (Both this and [handle] THROW [WipeIncompleteException] when the wipe is not complete.)

  /// Deletes the saved pages of the current parish AND invalidates the key
  /// that encrypts them, each attempted on its own: a failure to delete the
  /// files (a locked directory, a full disk) must never skip destroying the
  /// key, because a key that is gone makes every surviving file unreadable.
  /// They used to share one try, so the first failure skipped the second.
  ///
  /// Returns whether BOTH steps succeeded. False means the wipe is not
  /// complete (files may remain, or the key may still exist) and must not be
  /// reported as a full erase.
  /// Removes the parish's PHP session from the WebView's cookie jar.
  ///
  /// The session the handoff creates lives for 30 days of inactivity on the
  /// server (SESSION_LIFETIME_SECONDS), and the parish pages do not know about
  /// devices at all: revoking a device stops the mobile API and the issuing of
  /// new tickets, but a session cookie that is still in the jar would go on
  /// working. Logging a user out already cleared it (user_session_service.dart);
  /// the revocation path did not. Best-effort, like the rest of the wipe: it
  /// must never stop the sequence that follows.
  Future<void> clearWebViewSession() async {
    try {
      await _clearWebViewCookies();
    } catch (_) {
      // A platform without a WebView binding (a unit test) must not abort a
      // revocation.
    }
  }

  Future<bool> wipeSnapshotsAndKey({String? parishId, bool clearAllWhenUnknown = false}) async {
    var complete = true;
    try {
      final parish = parishId ?? await secureStorage.parishId;
      if (parish != null) {
        await snapshotStore.clearForParish(parishId: parish);
      } else if (clearAllWhenUnknown) {
        // A wipe that cannot tell which parish it is for removes every saved page.
        await snapshotStore.clearAll();
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

  /// The ONE wipe operation that is running, if any. Every caller (a manual reset, a central
  /// revocation, a retry) that comes while it runs gets THE SAME operation and waits for it: two
  /// sequences never run at once, and none can release the lock, or let the app be rebuilt, while
  /// another is still deleting.
  Future<void>? _running;

  Future<void> _exclusive(Future<void> Function() body) {
    final running = _running;
    if (running != null) return running;
    final run = body();
    _running = run;
    unawaited(run.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_running, run)) _running = null;
    }));
    return run;
  }

  Future<void> _wipeAndDeactivate(WipeReason reason) {
    // From the moment a wipe is requested nothing may show or hand out this device's data (taken
    // before the operation starts, so a caller that joins a running one is covered too).
    wipeLock.acquire();
    return _exclusive(() => _wipeOnce(reason));
  }

  Future<void> _wipeOnce(WipeReason reason) async {
    // A wipe of this process that did not finish is CONTINUED, not started over beside it.
    if (_pending != null) {
      await _retryOnce();
      return;
    }
    // The parish is read BEFORE the activation that names it is cleared, and written down with the
    // marker: after a restart in the middle of the wipe the activation may already be gone.
    String? parishId;
    try {
      parishId = await secureStorage.parishId;
    } catch (_) {}
    final marker = WipeMarker(reason: reason, parishId: parishId, startedAt: _now());

    // The marker goes first, in every place it can be kept. If it cannot be kept ANYWHERE the wipe
    // still runs (erasing matters more than being able to resume it), but nothing will resume it if
    // the process is interrupted, so it is done in the order that leaves the least behind: the
    // activation first, so that an interrupted wipe cannot start an app that shows revoked data.
    final markerStored = await _markers.write(marker.encode());
    await _afterStep?.call('marker');

    final result = await _runWipe(marker, activationFirst: !markerStored);
    lastOutcome = WipeOutcome(
      markerStored: markerStored,
      complete: result.complete,
      activationCleared: result.activationCleared,
    );
    if (!result.complete) {
      // NOT a normal ending. The caller must not rebuild the services or offer a new activation as
      // though the device were clean: this throws, and the screen that asked shows a blocking state
      // with a retry ([retryIncompleteWipe]).
      _pending = marker;
      throw const WipeIncompleteException();
    }
    _pending = null;
    wipeLock.release();
    // Removed only once every required step is confirmed. A removal that fails leaves the marker:
    // the next start (and an in-session restart of startup, which is what follows a wipe) finishes
    // the repeatable wipe and tries again, and no activation can happen in between.
    if (markerStored) {
      try {
        await _markers.delete();
      } catch (_) {}
    }
  }

  /// Tries again a wipe of this process that did not complete. True when it is now complete (or
  /// there was nothing to retry). Works whether or not a marker could be stored: it does not depend
  /// on one. Joins the wipe that is running, if there is one.
  Future<bool> retryIncompleteWipe() async {
    if (_pending == null && _running == null) return true;
    try {
      await _exclusive(_retryOnce);
      return true;
    } on WipeIncompleteException {
      return false;
    }
  }

  Future<void> _retryOnce() async {
    final pending = _pending;
    if (pending == null) return;
    wipeLock.acquire();
    final markerStored = lastOutcome?.markerStored ?? false;
    final result = await _runWipe(pending, activationFirst: !markerStored);
    lastOutcome = WipeOutcome(
      markerStored: markerStored,
      complete: result.complete,
      activationCleared: result.activationCleared,
    );
    if (!result.complete) throw const WipeIncompleteException();
    _pending = null;
    wipeLock.release();
    if (markerStored) {
      try {
        await _markers.delete();
      } catch (_) {}
    }
  }

  /// Finishes a wipe that was started and not confirmed complete: the marker is read first thing at
  /// startup, before the activation, the database or any saved page is touched. Returns whether
  /// there was one. Throws when it cannot be finished (or when the marker cannot even be read), so
  /// that startup stops: a half-erased app does not show its data.
  ///
  /// Every step is safe to run again, and none needs an open database.
  Future<bool> resumeInterruptedWipe() async {
    final raw = await _markers.read();
    if (raw == null) return false;
    final result = await _runWipe(WipeMarker.decode(raw));
    if (!result.complete) throw const WipeIncompleteException();
    await _markers.delete();
    return true;
  }

  /// Every required step is attempted, in order, each on its own: one that fails must not skip the
  /// next. True only when all of them are confirmed. The activation is cleared last, so a restart in
  /// the middle never finds an app that thinks it is still validly activated against data that is
  /// partly destroyed (and the marker is what makes that restart finish the job).
  Future<({bool complete, bool activationCleared})> _runWipe(WipeMarker marker, {bool activationFirst = false}) async {
    var complete = true;
    var activationCleared = false;
    Future<void> clearActivation() async {
      try {
        await secureStorage.clearActivation();
        // Only a REMOVED activation counts: a failed removal is not "cleared", and in the order that
        // puts the activation first it is the one step the protection depends on.
        activationCleared = true;
      } catch (_) {
        // Stays "not cleared"; it is tried once more after the other steps, and the wipe is complete
        // only if it is cleared by then.
      }
      await _afterStep?.call('activation');
    }

    if (activationFirst) await clearActivation();

    // REVOKE -> clear snapshots -> crypto-erase key: a copy of a snapshot file that survives is
    // unreadable once the key is gone (see wipeSnapshotsAndKey).
    if (!await wipeSnapshotsAndKey(parishId: marker.parishId, clearAllWhenUnknown: true)) {
      complete = false;
    }
    await _afterStep?.call('snapshots');
    await clearWebViewSession(); // best effort by design
    await _afterStep?.call('cookies');

    // Rows first (needs a live connection; best effort), then the file (needs the connection closed;
    // required and verified), then the key, then the activation.
    final database = db;
    if (database != null) {
      try {
        await database.wipeAllParishData();
      } catch (_) {}
      await _afterStep?.call('rows');
    }
    try {
      if (database != null) {
        await database.closeAndDeleteFiles();
      } else {
        await _deleteDatabaseFiles();
      }
      if (await _databaseFilesRemain()) complete = false;
    } catch (_) {
      complete = false;
    }
    await _afterStep?.call('db-files');
    try {
      await secureStorage.deleteDbEncryptionKey();
    } catch (_) {
      complete = false;
    }
    await _afterStep?.call('db-key');
    if (!activationCleared) await clearActivation();
    return (complete: complete && activationCleared, activationCleared: activationCleared);
  }
}

/// The startup hook: finishes an interrupted wipe with nothing but the secure storage and the
/// file system. The snapshot store here only DELETES, so its encryptor gets a placeholder key
/// (the real one may already be destroyed; reading a key just to erase would create a new one).
Future<bool> resumeInterruptedWipe(SecureStorageService storage) {
  final handler = RevocationHandler(
    db: null,
    secureStorage: storage,
    snapshotStore: SnapshotStore(encryptor: SnapshotEncryptor(hexKey: '0' * 64)),
  );
  return handler.resumeInterruptedWipe();
}

/// How a wipe ended.
class WipeOutcome {
  const WipeOutcome({required this.markerStored, required this.complete, required this.activationCleared});

  /// The activation was actually removed. With no marker stored the order "activation first" protects
  /// an interrupted wipe ONLY when this is true; when it is false nothing protects it.
  final bool activationCleared;

  /// The marker was stored in at least one place before the wipe began.
  final bool markerStored;

  /// Every required step was confirmed.
  final bool complete;

  /// Whether an interrupted wipe WOULD be finished at the next start. False when no marker was
  /// stored anywhere: then nothing is known to resume it, and nothing may say it will be.
  bool get resumeGuaranteed => markerStored;

  /// An interrupted wipe leaves nothing that could start showing revoked data: either a marker will
  /// resume it, or the activation is already gone.
  bool get safeIfInterrupted => markerStored || activationCleared;
}
