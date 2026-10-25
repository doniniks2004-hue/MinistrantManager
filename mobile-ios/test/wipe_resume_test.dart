import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/security/wipe_lock.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart' show DeviceAuthState;
import 'package:ministrant_manager/features/revocation/revocation_handler.dart';
import 'package:ministrant_manager/features/revocation/wipe_marker.dart';

/// The "wipe in progress" marker: written before anything is deleted, removed only when every
/// required step is confirmed, and used at the next start to finish an interrupted wipe.
/// (Written without being able to run Flutter here: not executed.)

class _MemoryMarker implements WipeMarkerStore {
  String? value;
  bool failWrite = false;
  bool failRead = false;
  bool failDelete = false;
  final events = <String>[];

  @override
  Future<String?> read() async {
    if (failRead) throw StateError('storage unreadable');
    return value;
  }

  @override
  Future<void> write(String v) async {
    events.add('marker:write');
    if (failWrite) throw StateError('storage unwritable');
    value = v;
  }

  @override
  Future<void> delete() async {
    events.add('marker:delete');
    if (failDelete) throw StateError('storage undeletable');
    value = null;
  }
}

class _Storage extends SecureStorageService {
  _Storage(this.log);
  final List<String> log;
  String? parish = 'parish-a';
  bool activated = true;
  bool failSnapshotKey = false;
  bool failDbKey = false;
  bool failClear = false;
  int clearFailures = 0; // the next N removals fail, then it works

  @override
  Future<String?> get parishId async => parish;

  @override
  Future<void> deleteSnapshotEncryptionKey() async {
    log.add('snapshot-key');
    if (failSnapshotKey) throw StateError('x');
  }

  @override
  Future<void> deleteDbEncryptionKey() async {
    log.add('db-key');
    if (failDbKey) throw StateError('x');
  }

  @override
  Future<void> clearActivation() async {
    log.add('activation');
    if (failClear) throw StateError('x');
    if (clearFailures > 0) {
      clearFailures--;
      throw StateError('x');
    }
    activated = false;
    parish = null;
  }
}

class _Store extends SnapshotStore {
  _Store(this.log) : super(encryptor: SnapshotEncryptor(hexKey: '1' * 64));
  final List<String> log;
  bool fails = false;
  String? clearedParish;
  bool clearedAll = false;

  @override
  Future<void> clearForParish({required String parishId}) async {
    log.add('snapshots');
    if (fails) throw const FileSystemException('locked');
    clearedParish = parishId;
  }

  @override
  Future<void> clearAll() async {
    log.add('snapshots-all');
    if (fails) throw const FileSystemException('locked');
    clearedAll = true;
  }
}

void main() {
  late _MemoryMarker marker; // the Keystore marker
  late _MemoryMarker fallback; // the file marker
  late _Storage storage;
  late _Store store;
  late List<String> log;
  var dbFilesRemain = true;
  var failDbDelete = false;

  RevocationHandler handler({Future<void> Function(String step)? afterStep}) => RevocationHandler(
    db: null, // finishing a wipe needs no database; the live one is covered by revocation_wipe_test
    secureStorage: storage,
    snapshotStore: store,
    clearWebViewCookies: () async => log.add('cookies'),
    markerStore: marker,
    fallbackMarkerStore: fallback,
    afterStep: afterStep,
    deleteDatabaseFiles: () async {
      log.add('db-files');
      if (failDbDelete) throw const FileSystemException('locked');
      dbFilesRemain = false;
    },
    databaseFilesRemain: () async => dbFilesRemain,
    now: () => DateTime.utc(2026, 10, 22, 12),
  );

  setUp(() {
    marker = _MemoryMarker();
    fallback = _MemoryMarker();
    log = [];
    storage = _Storage(log);
    store = _Store(log);
    dbFilesRemain = true;
    failDbDelete = false;
  });

  group('the marker itself', () {
    test('round-trips reason, parish and time', () {
      final m = WipeMarker(
        reason: WipeReason.parishDisabled,
        parishId: 'p1',
        startedAt: DateTime.utc(2026, 1, 2, 3),
      );
      final back = WipeMarker.decode(m.encode());
      expect(back.reason, WipeReason.parishDisabled);
      expect(back.parishId, 'p1');
      expect(back.startedAt, DateTime.utc(2026, 1, 2, 3));
    });

    test('text that cannot be read is still a marker, with nothing in it', () {
      for (final raw in ['', 'garbage', '[]', '{"reason":"???"}']) {
        final m = WipeMarker.decode(raw);
        expect(m.reason, isNull, reason: raw);
        expect(m.parishId, isNull, reason: raw);
      }
    });

    test('holds no token, key or URL', () {
      final text = WipeMarker(
        reason: WipeReason.revoked,
        parishId: 'p1',
        startedAt: DateTime.utc(2026),
      ).encode();
      expect(text, isNot(contains('token')));
      expect(text, isNot(contains('http')));
    });
  });

  group('starting a wipe', () {
    test('the marker is written BEFORE anything is deleted', () async {
      marker.events.clear();
      await handler().handle(DeviceAuthState.revoked);
      expect(marker.events.first, 'marker:write');
      // Nothing was logged before the marker write: the log starts with the first deletion.
      expect(log.first, 'snapshots');
    });

    test('the marker carries the parish and the reason', () async {
      storage.failClear = true; // keep the marker so that it can be read
      await expectLater(handler().handle(DeviceAuthState.parishDisabled), throwsA(isA<WipeIncompleteException>()));
      final m = WipeMarker.decode(marker.value!);
      expect(m.parishId, 'parish-a');
      expect(m.reason, WipeReason.parishDisabled);
    });

    test('a complete wipe removes the marker', () async {
      await handler().handle(DeviceAuthState.revoked);
      expect(marker.value, isNull);
      expect(fallback.value, isNull);
      expect(marker.events.last, 'marker:delete');
      expect(storage.activated, isFalse);
      expect(dbFilesRemain, isFalse);
    });

    test('every step runs, in order, and the activation is cleared last', () async {
      await handler().handle(DeviceAuthState.revoked);
      expect(log, ['snapshots', 'snapshot-key', 'cookies', 'db-files', 'db-key', 'activation']);
    });

    test('a manual reset starts the same wipe', () async {
      await handler().resetParishManually();
      expect(marker.events.first, 'marker:write');
      expect(marker.value, isNull);
      expect(log.last, 'activation');
    });

    test('a marker that cannot be written does not stop the wipe', () async {
      marker.failWrite = true;
      await handler().handle(DeviceAuthState.revoked);
      expect(log, contains('db-key'));
      expect(storage.activated, isFalse);
    });

    for (final failing in ['snapshots', 'snapshot-key', 'db-files', 'db-key', 'activation']) {
      test('a failed step ($failing) keeps the marker, and the later steps still run', () async {
        switch (failing) {
          case 'snapshots':
            store.fails = true;
          case 'snapshot-key':
            storage.failSnapshotKey = true;
          case 'db-files':
            failDbDelete = true;
          case 'db-key':
            storage.failDbKey = true;
          case 'activation':
            storage.failClear = true;
        }
        await expectLater(handler().handle(DeviceAuthState.revoked), throwsA(isA<WipeIncompleteException>()));
        expect(marker.value, isNotNull, reason: 'the wipe is not confirmed complete');
        expect(log, contains('activation'), reason: 'one failure must not skip the rest');
        expect(log, contains('db-key'));
      });
    }

    test('database files that are still there after the deletion keep the marker', () async {
      final h = RevocationHandler(
        db: null,
        secureStorage: storage,
        snapshotStore: store,
        clearWebViewCookies: () async {},
        markerStore: marker,
        fallbackMarkerStore: fallback,
        deleteDatabaseFiles: () async {}, // "succeeds" and leaves the files
        databaseFilesRemain: () async => true,
      );
      await expectLater(h.handle(DeviceAuthState.revoked), throwsA(isA<WipeIncompleteException>()));
      expect(marker.value, isNotNull);
    });
  });

  group('what never starts a wipe', () {
    for (final state in [
      DeviceAuthState.active,
      DeviceAuthState.authError, // an answer that cannot be read / an unknown status
      DeviceAuthState.tokenRejected, // a refusal: blocks, erases nothing
      DeviceAuthState.updateRequired,
      DeviceAuthState.offlineWithinLease,
      DeviceAuthState.offlineLeaseExpired,
    ]) {
      test('$state: no marker, no deletion', () async {
        await handler().handle(state);
        expect(marker.events, isEmpty);
        expect(log, isEmpty);
        expect(storage.activated, isTrue);
      });
    }
  });

  group('finishing an interrupted wipe at the next start', () {
    test('no marker: nothing happens', () async {
      expect(await handler().resumeInterruptedWipe(), isFalse);
      expect(log, isEmpty);
    });

    test('a crash after the marker was written: the wipe is finished, then the marker goes', () async {
      marker.value = WipeMarker(
        reason: WipeReason.revoked,
        parishId: 'parish-a',
        startedAt: DateTime.utc(2026),
      ).encode();
      expect(await handler().resumeInterruptedWipe(), isTrue);
      expect(store.clearedParish, 'parish-a');
      expect(log, containsAll(['snapshot-key', 'db-files', 'db-key', 'activation']));
      expect(marker.value, isNull);
    });

    test('the parish comes from the marker, not from the activation (already gone)', () async {
      storage.parish = null;
      marker.value = WipeMarker(
        reason: WipeReason.revoked,
        parishId: 'parish-from-marker',
        startedAt: DateTime.utc(2026),
      ).encode();
      await handler().resumeInterruptedWipe();
      expect(store.clearedParish, 'parish-from-marker');
    });

    test('an unreadable marker, or one with no parish, removes every saved page', () async {
      storage.parish = null;
      marker.value = 'garbage';
      await handler().resumeInterruptedWipe();
      expect(store.clearedAll, isTrue);
      expect(marker.value, isNull);
    });

    test('repeating it is harmless: a second run after completion does nothing', () async {
      marker.value = WipeMarker(
        reason: WipeReason.revoked,
        parishId: 'parish-a',
        startedAt: DateTime.utc(2026),
      ).encode();
      await handler().resumeInterruptedWipe();
      log.clear();
      expect(await handler().resumeInterruptedWipe(), isFalse);
      expect(log, isEmpty);
    });

    test('the same steps run twice over (a second interruption) without error', () async {
      marker.value = WipeMarker(
        reason: WipeReason.revoked,
        parishId: 'parish-a',
        startedAt: DateTime.utc(2026),
      ).encode();
      storage.failClear = true;
      await expectLater(handler().resumeInterruptedWipe(), throwsA(isA<WipeIncompleteException>()));
      expect(marker.value, isNotNull);
      storage.failClear = false;
      expect(await handler().resumeInterruptedWipe(), isTrue);
      expect(marker.value, isNull);
    });

    test('a step that fails again keeps the marker and throws: startup does not go on', () async {
      marker.value = WipeMarker(
        reason: WipeReason.revoked,
        parishId: 'parish-a',
        startedAt: DateTime.utc(2026),
      ).encode();
      failDbDelete = true;
      await expectLater(handler().resumeInterruptedWipe(), throwsA(isA<WipeIncompleteException>()));
      expect(marker.value, isNotNull);
    });

    test('a marker that cannot be read stops startup (fail closed)', () async {
      marker.failRead = true;
      await expectLater(handler().resumeInterruptedWipe(), throwsA(isA<StateError>()));
      expect(log, isEmpty);
    });

    test('a marker that cannot be removed after a complete wipe stops startup, and the next one finishes', () async {
      marker.value = WipeMarker(
        reason: WipeReason.revoked,
        parishId: 'parish-a',
        startedAt: DateTime.utc(2026),
      ).encode();
      marker.failDelete = true;
      await expectLater(handler().resumeInterruptedWipe(), throwsA(isA<StateError>()));
      marker.failDelete = false;
      expect(await handler().resumeInterruptedWipe(), isTrue);
      expect(marker.value, isNull);
    });
  });

  group('the marker is kept in two places, and what that does and does not guarantee', () {
    const steps = ['marker', 'snapshots', 'cookies', 'db-files', 'db-key', 'activation'];

    // The process dies right after [step]: the hook throws outside the step's own error handling.
    Future<void> dieAfter(String step, RevocationHandler Function(Future<void> Function(String)) build) async {
      final h = build((s) async {
        if (s == step) throw const _ProcessDied();
      });
      await expectLater(h.handle(DeviceAuthState.revoked), throwsA(isA<_ProcessDied>()), reason: step);
    }

    void expectWipedEverywhere() {
      expect(store.clearedParish, 'parish-a');
      expect(log, containsAll(['snapshot-key', 'db-files', 'db-key', 'activation']));
      expect(storage.activated, isFalse);
      expect(dbFilesRemain, isFalse);
      expect(marker.value, isNull);
      expect(fallback.value, isNull);
    }

    test('both places hold the marker when both work', () async {
      storage.failClear = true; // keep it
      await expectLater(handler().handle(DeviceAuthState.revoked), throwsA(isA<WipeIncompleteException>()));
      expect(marker.value, isNotNull);
      expect(fallback.value, isNotNull);
      expect(marker.value, fallback.value);
    });

    test('a complete wipe says its marker was stored, so that it would have been resumed', () async {
      final h = handler();
      await h.handle(DeviceAuthState.revoked);
      expect(h.lastOutcome!.markerStored, isTrue);
      expect(h.lastOutcome!.complete, isTrue);
      expect(h.lastOutcome!.resumeGuaranteed, isTrue);
    });

    for (final step in steps) {
      test('the process dies after "$step": the next start finishes the wipe (both places working)', () async {
        await dieAfter(step, (hook) => handler(afterStep: hook));
        expect(await handler().resumeInterruptedWipe(), isTrue);
        expectWipedEverywhere();
      });

      test('the process dies after "$step": the FILE marker alone is enough (the keystore refused the write)', () async {
        marker.failWrite = true;
        await dieAfter(step, (hook) => handler(afterStep: hook));
        expect(marker.value, isNull);
        marker.failWrite = false;
        expect(await handler().resumeInterruptedWipe(), isTrue);
        expectWipedEverywhere();
      });

      test('the process dies after "$step": the KEYSTORE marker alone is enough (the file could not be written)', () async {
        fallback.failWrite = true;
        await dieAfter(step, (hook) => handler(afterStep: hook));
        fallback.failWrite = false;
        expect(await handler().resumeInterruptedWipe(), isTrue);
        expectWipedEverywhere();
      });
    }

    test('the keystore cannot be read at the restart, but the file marker is there: the wipe is finished', () async {
      marker.failWrite = true;
      await dieAfter('snapshots', (hook) => handler(afterStep: hook));
      marker.failWrite = false;
      marker.failRead = true;
      expect(await handler().resumeInterruptedWipe(), isTrue);
      expect(store.clearedParish, 'parish-a');
    });

    test('a marker that is found in either place is enough; one that cannot be read in one place and is absent in the other is NOT "no marker"', () async {
      marker.failRead = true;
      await expectLater(handler().resumeInterruptedWipe(), throwsA(isA<StateError>()));
      expect(log, isEmpty);
    });

    group('when NO marker could be stored anywhere', () {
      test('the wipe still runs, and says plainly that it cannot be resumed', () async {
        marker.failWrite = true;
        fallback.failWrite = true;
        final h = handler();
        await h.handle(DeviceAuthState.revoked);
        expect(h.lastOutcome!.markerStored, isFalse);
        expect(h.lastOutcome!.resumeGuaranteed, isFalse, reason: 'no marker, no promise');
        expect(h.lastOutcome!.complete, isTrue);
        expect(storage.activated, isFalse);
        expect(marker.value, isNull);
        expect(fallback.value, isNull);
      });

      test('the activation goes FIRST: an interrupted wipe cannot start an app that still shows the data', () async {
        marker.failWrite = true;
        fallback.failWrite = true;
        await handler().handle(DeviceAuthState.revoked);
        expect(log.first, 'activation');
        expect(log.last, 'db-key');
      });

      for (final step in ['snapshots', 'cookies', 'db-files', 'db-key']) {
        test('the process dies after "$step": the app is already not activated (nothing is resumed, and none is claimed)', () async {
          marker.failWrite = true;
          fallback.failWrite = true;
          await dieAfter(step, (hook) => handler(afterStep: hook));
          expect(storage.activated, isFalse, reason: 'cleared before anything else');
          marker.failWrite = false;
          fallback.failWrite = false;
          expect(await handler().resumeInterruptedWipe(), isFalse, reason: 'there is nothing to resume it from');
        });
      }

      test('an incomplete wipe with no marker is reported as incomplete AND unresumable', () async {
        marker.failWrite = true;
        fallback.failWrite = true;
        store.fails = true;
        final h = handler();
        await expectLater(h.handle(DeviceAuthState.revoked), throwsA(isA<WipeIncompleteException>()));
        expect(h.lastOutcome!.complete, isFalse);
        expect(h.lastOutcome!.resumeGuaranteed, isFalse);
      });
    });

    test('a marker that cannot be removed from one place after a complete wipe is not left to wipe the next activation', () async {
      fallback.failDelete = true;
      await handler().handle(DeviceAuthState.revoked);
      // The wipe is complete; one marker could not be cleared. The next startup finishes (it repeats
      // harmlessly) and must clear it before anything can be activated.
      expect(fallback.value, isNotNull);
      fallback.failDelete = false;
      expect(await handler().resumeInterruptedWipe(), isTrue);
      expect(fallback.value, isNull);
      expect(marker.value, isNull);
    });
  });

  group('a wipe that is not complete STOPS the flow (it is not a normal ending)', () {
    test('handle throws, the outcome says incomplete, and the handler knows one is pending', () async {
      store.fails = true;
      final h = handler();
      await expectLater(h.handle(DeviceAuthState.revoked), throwsA(isA<WipeIncompleteException>()));
      expect(h.lastOutcome!.complete, isFalse);
      expect(h.hasIncompleteWipe, isTrue);
    });

    test('resetParishManually (the user\'s own "change parish") throws too', () async {
      store.fails = true;
      await expectLater(handler().resetParishManually(), throwsA(isA<WipeIncompleteException>()));
    });

    test('retryIncompleteWipe: false while it keeps failing, true once it works, and then the markers go', () async {
      store.fails = true;
      final h = handler();
      await expectLater(h.handle(DeviceAuthState.revoked), throwsA(isA<WipeIncompleteException>()));
      expect(await h.retryIncompleteWipe(), isFalse);
      expect(h.hasIncompleteWipe, isTrue);
      expect(marker.value, isNotNull);
      store.fails = false;
      expect(await h.retryIncompleteWipe(), isTrue);
      expect(h.hasIncompleteWipe, isFalse);
      expect(marker.value, isNull);
      expect(fallback.value, isNull);
      expect(store.clearedParish, 'parish-a', reason: 'the parish of the wipe, not of the (cleared) activation');
    });

    group('the wipe lock: held from the START of a wipe until it is COMPLETE', () {
      test('held while the wipe runs, released when it is complete', () async {
        final lock = WipeLock();
        final gate = Completer<void>();
        final h = RevocationHandler(
          db: null,
          secureStorage: storage,
          snapshotStore: store,
          clearWebViewCookies: () async {},
          markerStore: marker,
          fallbackMarkerStore: fallback,
          deleteDatabaseFiles: () async => gate.future,
          databaseFilesRemain: () async => false,
          wipeLock: lock,
        );
        expect(lock.isHeld, isFalse);
        final running = h.handle(DeviceAuthState.revoked);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(lock.isHeld, isTrue, reason: 'taken before anything was deleted');
        gate.complete();
        await running;
        expect(lock.isHeld, isFalse);
      });

      test('an incomplete wipe leaves it held, through every further attempt, until one succeeds', () async {
        final lock = WipeLock();
        store.fails = true;
        final h = RevocationHandler(
          db: null,
          secureStorage: storage,
          snapshotStore: store,
          clearWebViewCookies: () async {},
          markerStore: marker,
          fallbackMarkerStore: fallback,
          deleteDatabaseFiles: () async {},
          databaseFilesRemain: () async => false,
          wipeLock: lock,
        );
        await expectLater(h.resetParishManually(), throwsA(isA<WipeIncompleteException>()));
        expect(lock.isHeld, isTrue);
        expect(await h.retryIncompleteWipe(), isFalse);
        expect(lock.isHeld, isTrue);
        // A second manual reset CONTINUES the pending wipe (it does not start one beside it).
        await expectLater(h.resetParishManually(), throwsA(isA<WipeIncompleteException>()));
        expect(lock.isHeld, isTrue);
        store.fails = false;
        await h.resetParishManually();
        expect(lock.isHeld, isFalse);
        expect(h.hasIncompleteWipe, isFalse);
      });
    });

    group('ONE wipe operation at a time', () {
      RevocationHandler gated(WipeLock lock, Completer<void> gate, List<String> calls) => RevocationHandler(
            db: null,
            secureStorage: storage,
            snapshotStore: store,
            clearWebViewCookies: () async {},
            markerStore: marker,
            fallbackMarkerStore: fallback,
            deleteDatabaseFiles: () async {
              calls.add('db-files');
              await gate.future;
            },
            databaseFilesRemain: () async => false,
            wipeLock: lock,
          );

      test('a manual reset and a central revocation at the same time share ONE sequence', () async {
        final lock = WipeLock();
        final gate = Completer<void>();
        final calls = <String>[];
        final h = gated(lock, gate, calls);
        var manualDone = false;
        var centralDone = false;
        final manual = h.resetParishManually().then((_) => manualDone = true);
        final central = h.handle(DeviceAuthState.revoked).then((_) => centralDone = true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(calls, ['db-files'], reason: 'one deletion step, not two');
        expect(lock.isHeld, isTrue);
        expect(manualDone || centralDone, isFalse, reason: 'neither may report the end while a step is still deleting');
        gate.complete();
        await Future.wait([manual, central]);
        expect(calls, ['db-files'], reason: 'still one sequence in the end');
        expect(lock.isHeld, isFalse);
        expect(h.hasIncompleteWipe, isFalse);
        expect(marker.events.where((e) => e == 'marker:write').length, 1, reason: 'one marker, written once');
      });

      test('both callers see the SAME failure; a later retry is one operation again', () async {
        final lock = WipeLock();
        store.fails = true;
        final gate = Completer<void>()..complete();
        final h = gated(lock, gate, <String>[]);
        final results = await Future.wait([
          h.resetParishManually().then((_) => 'ok', onError: (Object e) => e.runtimeType.toString()),
          h.handle(DeviceAuthState.revoked).then((_) => 'ok', onError: (Object e) => e.runtimeType.toString()),
        ]);
        expect(results, ['WipeIncompleteException', 'WipeIncompleteException']);
        expect(lock.isHeld, isTrue);
        store.fails = false;
        final retries = await Future.wait([h.retryIncompleteWipe(), h.retryIncompleteWipe()]);
        expect(retries, [true, true]);
        expect(lock.isHeld, isFalse);
      });

      test('a retry that comes while a wipe is running waits for it', () async {
        final lock = WipeLock();
        final gate = Completer<void>();
        final calls = <String>[];
        final h = gated(lock, gate, calls);
        final running = h.resetParishManually();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        var retried = false;
        final retry = h.retryIncompleteWipe().then((v) => retried = v);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(retried, isFalse);
        gate.complete();
        await running;
        await retry;
        expect(retried, isTrue);
        expect(calls, ['db-files']);
      });
    });

    test('with nothing pending there is nothing to retry', () async {
      expect(await handler().retryIncompleteWipe(), isTrue);
    });

    group('BOTH marker writes fail AND the activation cannot be cleared', () {
      setUp(() {
        marker.failWrite = true;
        fallback.failWrite = true;
        storage.failClear = true;
      });

      test('the wipe throws; it says no marker, no activation cleared, and that an interruption is NOT covered', () async {
        final h = handler();
        await expectLater(h.handle(DeviceAuthState.revoked), throwsA(isA<WipeIncompleteException>()));
        final o = h.lastOutcome!;
        expect(o.markerStored, isFalse);
        expect(o.activationCleared, isFalse, reason: 'the removal failed: it is not "cleared"');
        expect(o.complete, isFalse);
        expect(o.resumeGuaranteed, isFalse);
        expect(o.safeIfInterrupted, isFalse, reason: '"activation first" protects only once the activation is gone');
        expect(storage.activated, isTrue);
      });

      test('the activation is tried first AND again at the end: two attempts, both failed', () async {
        await expectLater(handler().handle(DeviceAuthState.revoked), throwsA(isA<WipeIncompleteException>()));
        expect(log.where((e) => e == 'activation'), hasLength(2));
        expect(log.first, 'activation');
        expect(log.last, 'activation');
      });

      test('the retry works with no marker at all, once the storage recovers', () async {
        final h = handler();
        await expectLater(h.handle(DeviceAuthState.revoked), throwsA(isA<WipeIncompleteException>()));
        expect(await h.retryIncompleteWipe(), isFalse);
        storage.failClear = false;
        expect(await h.retryIncompleteWipe(), isTrue);
        expect(storage.activated, isFalse);
        expect(h.lastOutcome!.activationCleared, isTrue);
        expect(h.hasIncompleteWipe, isFalse);
      });

      test('a restart in between knows nothing (and no promise was made): stated, tested', () async {
        final h = handler();
        await expectLater(h.handle(DeviceAuthState.revoked), throwsA(isA<WipeIncompleteException>()));
        marker.failWrite = false;
        fallback.failWrite = false;
        expect(await handler().resumeInterruptedWipe(), isFalse, reason: 'nothing recorded it');
        expect(h.lastOutcome!.resumeGuaranteed, isFalse);
      });
    });

    test('an activation that fails ONCE, with no marker, is cleared by the second attempt: complete and safe', () async {
      marker.failWrite = true;
      fallback.failWrite = true;
      storage.clearFailures = 1;
      final h = handler();
      await h.handle(DeviceAuthState.revoked);
      expect(h.lastOutcome!.activationCleared, isTrue);
      expect(h.lastOutcome!.complete, isTrue);
      expect(storage.activated, isFalse);
    });

    test('a marker that WAS stored makes an interruption safe even while the activation is still there', () async {
      storage.failClear = true;
      final h = handler();
      await expectLater(h.handle(DeviceAuthState.revoked), throwsA(isA<WipeIncompleteException>()));
      expect(h.lastOutcome!.markerStored, isTrue);
      expect(h.lastOutcome!.activationCleared, isFalse);
      expect(h.lastOutcome!.safeIfInterrupted, isTrue);
    });
  });
}

class _ProcessDied implements Exception {
  const _ProcessDied();
}
