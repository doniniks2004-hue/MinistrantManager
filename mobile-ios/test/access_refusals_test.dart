import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/security/access_refusals.dart';

class _MapStorage implements RefusalStorage {
  final data = <RefusalSlot, String>{};
  bool failReads = false;
  bool failWrites = false;
  bool failDeletes = false;
  Completer<void>? readGate; // a read waits for it (when set)
  Completer<void>? deleteGate; // a delete waits for it (when set); the removal happens AFTER the gate
  int writes = 0;
  int deletesStarted = 0;
  final events = <String>[];

  @override
  Future<String?> read(RefusalSlot slot) async {
    if (failReads) throw StateError('keystore unavailable');
    final gate = readGate;
    if (gate != null) await gate.future;
    return data[slot];
  }

  @override
  Future<void> write(RefusalSlot slot, String value) async {
    if (failWrites) throw StateError('keystore unavailable');
    writes++;
    events.add('write');
    data[slot] = value;
  }

  @override
  Future<void> delete(RefusalSlot slot) async {
    if (failDeletes) throw StateError('keystore unavailable');
    deletesStarted++;
    events.add('delete-started');
    final gate = deleteGate;
    if (gate != null) await gate.future;
    events.add('delete-done');
    data.remove(slot);
  }
}

class _Sharing {
  final inner = _MapStorage();
}

/// Separate objects in front of one physical storage, as `SecureStorageService.refusalStorage` hands out.
class _SharedView implements RefusalStorage, SharedRefusalStorage {
  _SharedView(this._shared, this.key);
  final _Sharing _shared;
  final String key;
  @override
  Object get gateKey => key;
  @override
  Future<String?> read(RefusalSlot slot) => _shared.inner.read(slot);
  @override
  Future<void> write(RefusalSlot slot, String value) => _shared.inner.write(slot, value);
  @override
  Future<void> delete(RefusalSlot slot) => _shared.inner.delete(slot);
}

void main() {
  group('what a handoff reply means (decided from its own codes, never from the status alone)', () {
    HandoffRefusal c(int? status, String? code, [String? state]) =>
        classifyHandoffRefusal(status: status, errorCode: code, deviceState: state);

    test('device_not_authorized with a state that says "no" is a refusal of the DEVICE', () {
      for (final state in ['revoked', 'parish_disabled', 'not_found', 'parish_mismatch']) {
        expect(c(403, 'device_not_authorized', state), HandoffRefusal.device, reason: state);
      }
    });

    test('central_unavailable (503: "could not check") is not a refusal', () {
      expect(c(503, 'device_not_authorized', 'central_unavailable'), HandoffRefusal.none);
      expect(c(403, 'device_not_authorized', 'central_unavailable'), HandoffRefusal.none);
    });

    test('an unknown or missing device_state is NOT read as a revocation or any refusal', () {
      expect(c(403, 'device_not_authorized', 'something_new'), HandoffRefusal.none);
      expect(c(403, 'device_not_authorized', null), HandoffRefusal.none);
      expect(c(403, 'device_not_authorized', 'active'), HandoffRefusal.none);
    });

    test('403 "forbidden" is a refusal of the MODULE, not of the device', () {
      expect(c(403, 'forbidden'), HandoffRefusal.module);
    });

    test('everything else is nothing to remember: a 403 with no code, a firewall page, an expired ticket, an unknown path, a session', () {
      expect(c(403, null), HandoffRefusal.none);
      expect(c(403, 'access_denied'), HandoffRefusal.none);
      expect(c(400, 'invalid_path'), HandoffRefusal.none);
      expect(c(401, null), HandoffRefusal.none);
      expect(c(401, 'forbidden'), HandoffRefusal.none, reason: 'the code alone is not enough: the status must agree');
      expect(c(404, 'forbidden'), HandoffRefusal.none);
      expect(c(500, 'device_not_authorized', 'revoked'), HandoffRefusal.none);
      expect(c(null, null), HandoffRefusal.none);
    });
  });

  group('the device refusal', () {
    late _MapStorage storage;
    late AccessRefusals refusals;
    setUp(() {
      storage = _MapStorage();
      refusals = AccessRefusals(storage, clock: () => DateTime.utc(2026, 10, 22, 9));
    });

    Future<RefusalCheck> check(String? token, {bool tokenReadFailed = false}) async =>
        (await refusals.checkDevice(deviceToken: token, tokenReadFailed: tokenReadFailed)).check;

    test('is remembered for the token it was received for, with its source and time', () async {
      expect(await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401'), isTrue);
      final c = await refusals.checkDevice(deviceToken: 'token-A');
      expect(c.check, RefusalCheck.blocked);
      expect(c.refusal!.source, 'central_401');
      expect(c.refusal!.at, DateTime.utc(2026, 10, 22, 9));
    });

    test('holds no token: only a short fingerprint', () async {
      await refusals.blockDevice(deviceToken: 'token-A-secret-value', source: 'central_401');
      final raw = storage.data[RefusalSlot.device]!;
      expect(raw, isNot(contains('token-A-secret-value')));
      expect(raw.toLowerCase(), isNot(contains('bearer')));
      expect((jsonDecode(raw) as Map)['tf'], hasLength(16));
    });

    test('does not apply to a different token (a new activation) and is dropped when seen', () async {
      await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
      // A fresh object: nothing held in memory, only what the storage says.
      final fresh = AccessRefusals(storage);
      expect((await fresh.checkDevice(deviceToken: 'token-B')).check, RefusalCheck.clear);
      expect(storage.data.containsKey(RefusalSlot.device), isFalse);
      expect((await fresh.checkDevice(deviceToken: 'token-A')).check, RefusalCheck.clear, reason: 'it is gone, not merely hidden');
    });

    test('a record for another token that cannot be tidied away still does not refuse this one', () async {
      await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
      storage.failDeletes = true;
      expect(await check('token-B'), RefusalCheck.clear);
    });

    test('not activated (no token, nothing failed) is clear; a token that could not be READ is unknown', () async {
      await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
      expect(await check(null), RefusalCheck.clear);
      expect(await check(null, tokenReadFailed: true), RefusalCheck.unknown);
    });

    test('liftDevice removes it and says so', () async {
      await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
      expect(await refusals.liftDevice(deviceToken: 'token-A'), LiftResult.done);
      expect(await check('token-A'), RefusalCheck.clear);
      expect(storage.data, isEmpty);
    });

    test('a source that is not a short machine label is not stored as given', () async {
      await refusals.blockDevice(deviceToken: 'token-A', source: 'https://x/?session=abc');
      expect((await refusals.checkDevice(deviceToken: 'token-A')).refusal!.source, 'unknown');
    });

    group('damaged records, read by a FRESH instance with nothing in memory', () {
      const goodAt = '2026-10-22T09:00:00.000Z';
      final fpA = AccessRefusals.fingerprint('token-A');
      Future<RefusalCheck> fresh(String raw, {String token = 'token-A'}) async {
        storage.data[RefusalSlot.device] = raw;
        return (await AccessRefusals(storage).checkDevice(deviceToken: token)).check;
      }

      test('valid JSON of the wrong shape is "cannot tell" and is NOT deleted', () async {
        for (final raw in [
          '{}',
          '{"tf":"$fpA"}',
          '{"src":"central_401","at":"$goodAt"}', // no tf: the bug read this as "another token" and deleted it
          '{"tf":123,"src":"central_401","at":"$goodAt"}',
          '{"tf":"$fpA","src":7,"at":"$goodAt"}',
          '{"tf":"$fpA","src":"central_401","at":42}',
          '{"tf":"$fpA","src":"central_401","at":"not a date"}',
          '{"tf":"short","src":"central_401","at":"$goodAt"}',
          '{"tf":"$fpA","src":"has spaces and /slashes","at":"$goodAt"}',
          'null',
          '[]',
        ]) {
          expect(await fresh(raw), RefusalCheck.unknown, reason: raw);
          expect(storage.data[RefusalSlot.device], raw, reason: 'a damaged record is kept, not tidied away: $raw');
        }
      });

      test('and for a DIFFERENT token too: damage is not "belongs to another token"', () async {
        expect(await fresh('{}', token: 'token-B'), RefusalCheck.unknown);
        expect(storage.data[RefusalSlot.device], '{}');
      });

      test('only a COMPLETE record of another token is dropped and read as clear', () async {
        final other = AccessRefusals.fingerprint('token-B');
        expect(await fresh('{"tf":"$other","src":"central_401","at":"$goodAt"}'), RefusalCheck.clear);
        expect(storage.data.containsKey(RefusalSlot.device), isFalse);
      });

      test('a complete record of this token is a block', () async {
        expect(await fresh('{"tf":"$fpA","src":"central_401","at":"$goodAt"}'), RefusalCheck.blocked);
      });
    });

    group('a record that cannot be read is NOT "no refusal"', () {
      test('damaged text, or text of the wrong shape: unknown', () async {
        for (final raw in ['{not json', '[1,2]', '"x"', '{"tf":"${AccessRefusals.fingerprint('token-A')}"}']) {
          storage.data[RefusalSlot.device] = raw;
          expect(await check('token-A'), RefusalCheck.unknown, reason: raw);
        }
      });

      test('a store that cannot be read: unknown', () async {
        storage.failReads = true;
        expect(await check('token-A'), RefusalCheck.unknown);
      });

      test('and the answer is repeated, not cached as "clear"', () async {
        storage.failReads = true;
        expect(await check('token-A'), RefusalCheck.unknown);
        expect(await check('token-A'), RefusalCheck.unknown);
        storage.failReads = false;
        expect(await check('token-A'), RefusalCheck.clear, reason: 'readable again, and nothing is stored');
      });

      test('a damaged record is removed by a verified ACTIVE (liftDevice), which ends "unknown"', () async {
        storage.data[RefusalSlot.device] = '{not json';
        expect(await refusals.liftDevice(deviceToken: 'token-A'), LiftResult.done);
        expect(await check('token-A'), RefusalCheck.clear);
      });
    });

    test('a keystore call that is slow is cut off for the caller ("unknown"), and the next call waits for it to really finish', () async {
      final quick = AccessRefusals(storage, storageTimeout: const Duration(milliseconds: 50));
      storage.readGate = Completer<void>();
      expect((await quick.checkDevice(deviceToken: 'token-A')).check, RefusalCheck.unknown);
      // The first read is still running: nothing new is started on that record, and the answer is
      // again "cannot tell" rather than an answer from an overlapping call.
      expect((await quick.checkDevice(deviceToken: 'token-A')).check, RefusalCheck.unknown);
      storage.readGate!.complete();
      storage.readGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect((await quick.checkDevice(deviceToken: 'token-A')).check, RefusalCheck.clear);
    });

    group('a refusal that cannot be WRITTEN still stands in this process', () {
      test('blockDevice reports false, and the next checks still see the block', () async {
        storage.failWrites = true;
        expect(await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401'), isFalse);
        expect(await check('token-A'), RefusalCheck.blocked);
        expect(await check('token-A'), RefusalCheck.blocked, reason: 'and again, on a later attempt');
      });

      test('also when the store then becomes unreadable (the way offline often looks)', () async {
        storage.failWrites = true;
        await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
        storage.failReads = true;
        expect(await check('token-A'), RefusalCheck.blocked, reason: 'not "unknown", and certainly not "clear"');
      });

      test('it does not apply to another token', () async {
        storage.failWrites = true;
        await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
        expect(await check('token-B'), RefusalCheck.clear);
      });

      test('a new process knows nothing of it: the limit is stated, not hidden', () async {
        storage.failWrites = true;
        await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
        expect((await AccessRefusals(storage).checkDevice(deviceToken: 'token-A')).check, RefusalCheck.clear);
      });

      test('with no readable token the refusal still stands for the process, whatever token is read later', () async {
        await refusals.blockDeviceWithoutToken(source: 'parish_revoked');
        expect(await check('token-A'), RefusalCheck.blocked);
        expect(await check(null, tokenReadFailed: true), RefusalCheck.blocked);
      });
    });

    group('a lift that fails is reported, and the block is not claimed to be gone', () {
      test('liftDevice returns failed when the record cannot be deleted', () async {
        await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
        storage.failDeletes = true;
        expect(await refusals.liftDevice(deviceToken: 'token-A'), LiftResult.failed);
        expect(await check('token-A'), RefusalCheck.blocked, reason: 'the record is still there, and so is the block');
      });

      test('the memory is released only by a lift that worked', () async {
        storage.failWrites = true;
        await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
        storage.failDeletes = true;
        expect(await refusals.liftDevice(deviceToken: 'token-A'), LiftResult.failed);
        expect(await check('token-A'), RefusalCheck.blocked);
        storage.failDeletes = false;
        expect(await refusals.liftDevice(deviceToken: 'token-A'), LiftResult.done);
        expect(await check('token-A'), RefusalCheck.clear);
      });
    });
  });

  group('a lift is for the activation it was asked for, and real storage calls never overlap', () {
    late _MapStorage storage;
    final recordB = '{"tf":"${AccessRefusals.fingerprint('token-B')}","src":"central_401","at":"2026-10-22T09:00:00.000Z"}';
    setUp(() => storage = _MapStorage());

    test('a record of ANOTHER activation is not removed by an ACTIVE for this one', () async {
      storage.data[RefusalSlot.device] = recordB;
      final refusals = AccessRefusals(storage);
      expect(await refusals.liftDevice(deviceToken: 'token-A'), LiftResult.done);
      expect(storage.data[RefusalSlot.device], recordB, reason: 'not its to remove');
      expect((await refusals.checkDevice(deviceToken: 'token-B')).check, RefusalCheck.blocked);
    });

    test('the activation changed before the answer arrived: nothing is touched (superseded)', () async {
      final refusals = AccessRefusals(storage);
      await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
      // Re-activated meanwhile: the token this answer was for is no longer the device's.
      final result = await refusals.liftDevice(deviceToken: 'token-A', stillCurrent: () async => false);
      expect(result, LiftResult.superseded);
      expect(storage.data.containsKey(RefusalSlot.device), isTrue);
      expect(storage.deletesStarted, 0);
      expect((await refusals.checkDevice(deviceToken: 'token-A')).check, RefusalCheck.blocked, reason: 'memory too');
    });

    test('the check of "still current" happens INSIDE the queue, right before the removal', () async {
      final refusals = AccessRefusals(storage, storageTimeout: const Duration(seconds: 2));
      await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
      var asked = 0;
      await refusals.liftDevice(deviceToken: 'token-A', stillCurrent: () async {
        asked++;
        expect(storage.deletesStarted, 0, reason: 'asked before anything is removed');
        return true;
      });
      expect(asked, 1);
      expect(storage.deletesStarted, 1);
    });

    test('a removal that finishes AFTER the caller gave up cannot remove a refusal written later', () async {
      final refusals = AccessRefusals(storage, storageTimeout: const Duration(milliseconds: 50));
      await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401');
      storage.events.clear();
      storage.deleteGate = Completer<void>();

      // The lift is cut off for the caller, but the delete is still running inside the keystore.
      expect(await refusals.liftDevice(deviceToken: 'token-A'), LiftResult.failed);
      expect(storage.events, ['delete-started']);

      // A new refusal arrives meanwhile. NO write may be issued while the delete is unfinished: it
      // could be removed by it. The block still stands in this process.
      expect(await refusals.blockDevice(deviceToken: 'token-A', source: 'parish_revoked'), isFalse);
      expect(storage.events, ['delete-started'], reason: 'no write overlapped the running delete');
      expect((await refusals.checkDevice(deviceToken: 'token-A')).check, RefusalCheck.blocked);

      // The delete finishes. Nothing of the newer refusal existed in storage to be removed.
      storage.deleteGate!.complete();
      storage.deleteGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(storage.events, ['delete-started', 'delete-done']);

      // Now writing is allowed again, and what is written stays.
      expect(await refusals.blockDevice(deviceToken: 'token-A', source: 'parish_revoked'), isTrue);
      expect(storage.events.last, 'write');
      expect((await AccessRefusals(storage).checkDevice(deviceToken: 'token-A')).check, RefusalCheck.blocked);
    });

    test('the same for a module record: a late removal cannot take a newer block with it', () async {
      final refusals = AccessRefusals(storage, storageTimeout: const Duration(milliseconds: 50));
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      storage.events.clear();
      storage.deleteGate = Completer<void>();
      expect(await refusals.liftModule(parishId: 'p1', userId: 'u1', path: '/public/users.php'), LiftResult.failed);
      expect(await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/ranking.php'), isFalse);
      expect(storage.events, ['delete-started']);
      storage.deleteGate!.complete();
      storage.deleteGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/ranking.php'), isTrue);
      expect(await AccessRefusals(storage).checkModule(parishId: 'p1', userId: 'u1', path: '/public/ranking.php'), RefusalCheck.blocked);
    });

    test('a read that is still running holds back the next write (nothing overlaps)', () async {
      final refusals = AccessRefusals(storage, storageTimeout: const Duration(milliseconds: 50));
      storage.readGate = Completer<void>();
      expect((await refusals.checkDevice(deviceToken: 'token-A')).check, RefusalCheck.unknown);
      expect(await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401'), isFalse, reason: 'a read is still running');
      storage.readGate!.complete();
      storage.readGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await refusals.blockDevice(deviceToken: 'token-A', source: 'central_401'), isTrue);
    });
  });

  group('the queue belongs to the STORAGE, so it holds across a rebuild of the services', () {
    late _MapStorage storage;
    setUp(() => storage = _MapStorage());

    test('old delete still running -> NEW instance writes a refusal -> old delete ends: the write is NOT lost (third, fresh instance sees it)', () async {
      final oldInstance = AccessRefusals(storage, storageTimeout: const Duration(milliseconds: 50));
      await oldInstance.blockDevice(deviceToken: 'token-A', source: 'central_401');
      storage.events.clear();
      storage.deleteGate = Completer<void>();

      // The old instance lifts, is cut off after 50 ms, and its delete is still running in the keystore.
      expect(await oldInstance.liftDevice(deviceToken: 'token-A'), LiftResult.failed);
      expect(storage.events, ['delete-started']);

      // The services are rebuilt: a NEW instance in front of the same storage writes a refusal.
      final newInstance = AccessRefusals(storage, storageTimeout: const Duration(seconds: 5));
      final writing = newInstance.blockDevice(deviceToken: 'token-A', source: 'parish_revoked');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(storage.events, ['delete-started'], reason: 'the new instance waits: no write overlaps the old delete');

      // The old delete finishes; only then does the new write go.
      storage.deleteGate!.complete();
      storage.deleteGate = null;
      expect(await writing, isTrue);
      expect(storage.events, ['delete-started', 'delete-done', 'write']);

      // A THIRD, fresh instance has no memory of anything: what it reads is what survived in storage.
      final third = AccessRefusals(storage);
      final check = await third.checkDevice(deviceToken: 'token-A');
      expect(check.check, RefusalCheck.blocked);
      expect(check.refusal!.source, 'parish_revoked');
    });

    test('if the old delete is still running when the new instance gives up, nothing is written to be lost; the block stands in memory', () async {
      final oldInstance = AccessRefusals(storage, storageTimeout: const Duration(milliseconds: 50));
      await oldInstance.blockDevice(deviceToken: 'token-A', source: 'central_401');
      storage.events.clear();
      storage.deleteGate = Completer<void>();
      expect(await oldInstance.liftDevice(deviceToken: 'token-A'), LiftResult.failed);

      final newInstance = AccessRefusals(storage, storageTimeout: const Duration(milliseconds: 50));
      expect(await newInstance.blockDevice(deviceToken: 'token-A', source: 'parish_revoked'), isFalse);
      expect(storage.events, ['delete-started'], reason: 'no write was issued beside the running delete');
      expect((await newInstance.checkDevice(deviceToken: 'token-A')).check, RefusalCheck.blocked, reason: 'memory floor');

      storage.deleteGate!.complete();
      storage.deleteGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(storage.events, ['delete-started', 'delete-done']);
      // And a later write by the new instance goes through and survives for a fresh one.
      expect(await newInstance.blockDevice(deviceToken: 'token-A', source: 'parish_revoked'), isTrue);
      expect((await AccessRefusals(storage).checkDevice(deviceToken: 'token-A')).check, RefusalCheck.blocked);
    });

    test('the same for a module record', () async {
      final oldInstance = AccessRefusals(storage, storageTimeout: const Duration(milliseconds: 50));
      await oldInstance.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      storage.events.clear();
      storage.deleteGate = Completer<void>();
      expect(await oldInstance.liftModule(parishId: 'p1', userId: 'u1', path: '/public/users.php'), LiftResult.failed);
      final newInstance = AccessRefusals(storage, storageTimeout: const Duration(seconds: 5));
      final writing = newInstance.blockModule(parishId: 'p1', userId: 'u1', path: '/public/ranking.php');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      storage.deleteGate!.complete();
      storage.deleteGate = null;
      expect(await writing, isTrue);
      expect(await AccessRefusals(storage).checkModule(parishId: 'p1', userId: 'u1', path: '/public/ranking.php'), RefusalCheck.blocked);
    });

    test('instances in front of DIFFERENT storages do not wait for each other', () async {
      final other = _MapStorage();
      storage.deleteGate = Completer<void>(); // never completed in this test's first part
      final a = AccessRefusals(storage, storageTimeout: const Duration(milliseconds: 50));
      await a.blockDevice(deviceToken: 'token-A', source: 'central_401');
      expect(await a.liftDevice(deviceToken: 'token-A'), LiftResult.failed);
      final b = AccessRefusals(other, storageTimeout: const Duration(milliseconds: 50));
      expect(await b.blockDevice(deviceToken: 'token-A', source: 'central_401'), isTrue);
      storage.deleteGate!.complete();
    });

    test('storages that name the same physical place (the platform keystore) share one queue even as separate objects', () async {
      final shared = _Sharing();
      final one = _SharedView(shared, 'k');
      final two = _SharedView(shared, 'k');
      final old = AccessRefusals(one, storageTimeout: const Duration(milliseconds: 50));
      await old.blockDevice(deviceToken: 'token-A', source: 'central_401');
      shared.inner.events.clear();
      shared.inner.deleteGate = Completer<void>();
      expect(await old.liftDevice(deviceToken: 'token-A'), LiftResult.failed);
      final fresh = AccessRefusals(two, storageTimeout: const Duration(seconds: 5));
      final writing = fresh.blockDevice(deviceToken: 'token-A', source: 'parish_revoked');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(shared.inner.events, ['delete-started']);
      shared.inner.deleteGate!.complete();
      shared.inner.deleteGate = null;
      expect(await writing, isTrue);
      expect((await AccessRefusals(two).checkDevice(deviceToken: 'token-A')).check, RefusalCheck.blocked);
    });
  });

  group('the module refusal: scoped to one module, one user, one parish', () {
    late _MapStorage storage;
    late AccessRefusals refusals;
    setUp(() {
      storage = _MapStorage();
      refusals = AccessRefusals(storage);
    });

    Future<RefusalCheck> state(String p, String u, String path) => refusals.checkModule(parishId: p, userId: u, path: path);
    Future<bool> blocked(String p, String u, String path) async => (await state(p, u, path)) == RefusalCheck.blocked;

    test('blocks that module for that user and parish and nothing else', () async {
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      expect(await blocked('p1', 'u1', '/public/users.php'), isTrue);
      expect(await blocked('p1', 'u1', '/public/dashboard.php'), isFalse, reason: 'another module of the same user');
      expect(await blocked('p1', 'u2', '/public/users.php'), isFalse, reason: 'another user');
      expect(await blocked('p2', 'u1', '/public/users.php'), isFalse, reason: 'another parish');
    });

    test('is lifted for that module only', () async {
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/points.php');
      await refusals.liftModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      expect(await blocked('p1', 'u1', '/public/users.php'), isFalse);
      expect(await blocked('p1', 'u1', '/public/points.php'), isTrue);
    });

    test('lifting the last one leaves no record behind', () async {
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      await refusals.liftModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      expect(storage.data.containsKey(RefusalSlot.modules), isFalse);
    });

    test('lifting what was never blocked changes nothing and writes nothing', () async {
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      final writes = storage.writes;
      await refusals.liftModule(parishId: 'p1', userId: 'u2', path: '/public/users.php');
      expect(storage.writes, writes);
      expect(await blocked('p1', 'u1', '/public/users.php'), isTrue);
    });

    test('blocking twice keeps one record; many simultaneous blocks all survive', () async {
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      expect((jsonDecode(storage.data[RefusalSlot.modules]!) as List), hasLength(1));
      await Future.wait([
        for (var i = 0; i < 10; i++) refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/m$i.php'),
      ]);
      for (var i = 0; i < 10; i++) {
        expect(await blocked('p1', 'u1', '/public/m$i.php'), isTrue, reason: 'm$i');
      }
    });

    group('a full register never makes room by dropping a refusal', () {
      String full() => jsonEncode([
            for (var i = 0; i < AccessRefusals.maxModuleRecords; i++)
              {'p': 'p', 'u': 'u', 'm': '/public/m$i.php', 'at': '2026-10-22T09:00:00.000Z'},
          ]);

      test('the one that does not fit is held for this process and reported as not stored; nothing stored is removed', () async {
        storage.data[RefusalSlot.modules] = full();
        final before = storage.data[RefusalSlot.modules];
        expect(await refusals.blockModule(parishId: 'p', userId: 'u', path: '/public/overflow.php'), isFalse);
        expect(storage.data[RefusalSlot.modules], before, reason: 'storage untouched: the oldest is still there');
        // BEFORE a restart: this instance still blocks both the oldest and the new one.
        expect(await blocked('p', 'u', '/public/m0.php'), isTrue);
        expect(await blocked('p', 'u', '/public/overflow.php'), isTrue);
      });

      test('AFTER a restart (a fresh instance): every stored refusal still stands, the oldest included', () async {
        storage.data[RefusalSlot.modules] = full();
        await refusals.blockModule(parishId: 'p', userId: 'u', path: '/public/overflow.php');
        final restarted = AccessRefusals(storage);
        for (final i in [0, 1, AccessRefusals.maxModuleRecords - 1]) {
          expect(await restarted.checkModule(parishId: 'p', userId: 'u', path: '/public/m$i.php'), RefusalCheck.blocked, reason: 'm$i');
        }
        // The stated limit: the refusal that did not fit was never stored, so a restart does not know it
        // (the same as for a write that failed). It is reported by blockModule() == false.
        expect(await restarted.checkModule(parishId: 'p', userId: 'u', path: '/public/overflow.php'), RefusalCheck.clear);
      });

      test('a block that already has its record is rewritten in place even when the register is full', () async {
        storage.data[RefusalSlot.modules] = full();
        expect(await refusals.blockModule(parishId: 'p', userId: 'u', path: '/public/m5.php'), isTrue);
        expect(jsonDecode(storage.data[RefusalSlot.modules]!) as List, hasLength(AccessRefusals.maxModuleRecords));
      });

      test('room made by a LIFT (an accepted handoff) lets a later one be stored', () async {
        storage.data[RefusalSlot.modules] = full();
        expect(await refusals.liftModule(parishId: 'p', userId: 'u', path: '/public/m3.php'), LiftResult.done);
        expect(await refusals.blockModule(parishId: 'p', userId: 'u', path: '/public/overflow.php'), isTrue);
        expect(await AccessRefusals(storage).checkModule(parishId: 'p', userId: 'u', path: '/public/overflow.php'), RefusalCheck.blocked);
      });
    });

    test('a store that cannot be read, or holds damaged text, is UNKNOWN: not clear, not an exception', () async {
      storage.failReads = true;
      expect(await state('p1', 'u1', '/public/users.php'), RefusalCheck.unknown);
      storage.failReads = false;
      for (final raw in ['garbage', '{"p":"p1"}', '"x"', '7']) {
        storage.data[RefusalSlot.modules] = raw;
        expect(await state('p1', 'u1', '/public/users.php'), RefusalCheck.unknown, reason: raw);
      }
    });

    group('damaged module records, read by a FRESH instance', () {
      const good = '{"p":"p1","u":"u1","m":"/public/users.php","at":"2026-10-22T09:00:00.000Z"}';
      Future<RefusalCheck> fresh(String raw, {String path = '/public/users.php'}) async {
        storage.data[RefusalSlot.modules] = raw;
        return AccessRefusals(storage).checkModule(parishId: 'p1', userId: 'u1', path: path);
      }

      test('[{}] and other lists with a damaged element are "cannot tell", never "not blocked"', () async {
        for (final raw in [
          '[{}]',
          '[1]',
          '[null]',
          '[{"p":"p1"}]',
          '[{"p":"p1","u":"u1","m":"/public/users.php"}]', // no time
          '[{"p":1,"u":"u1","m":"/public/users.php","at":"2026-10-22T09:00:00.000Z"}]',
          '[{"p":"","u":"u1","m":"/public/users.php","at":"2026-10-22T09:00:00.000Z"}]',
          '[{"p":"p1","u":"u1","m":"/public/users.php","at":"nope"}]',
          '[$good,{}]', // one valid and one damaged: the damaged one could have been the block that matters
          '[{},$good]',
        ]) {
          expect(await fresh(raw), RefusalCheck.unknown, reason: raw);
          expect(await fresh(raw, path: '/public/other.php'), RefusalCheck.unknown, reason: 'another module: $raw');
          expect(storage.data[RefusalSlot.modules], raw, reason: 'kept as it was: $raw');
        }
      });

      test('complete records are read as before', () async {
        expect(await fresh('[$good]'), RefusalCheck.blocked);
        expect(await fresh('[$good]', path: '/public/other.php'), RefusalCheck.clear);
        expect(await fresh('[]'), RefusalCheck.clear);
      });

      test('a block over a list with a damaged element does not rewrite (and so does not drop) it', () async {
        storage.data[RefusalSlot.modules] = '[{}]';
        final writes = storage.writes;
        expect(await AccessRefusals(storage).blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php'), isFalse);
        expect(storage.writes, writes);
        expect(storage.data[RefusalSlot.modules], '[{}]');
      });
    });

    test('no record at all is clear', () async {
      expect(await state('p1', 'u1', '/public/users.php'), RefusalCheck.clear);
    });

    test('a block that cannot be written still stands in this process, for later attempts too', () async {
      storage.failWrites = true;
      expect(await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php'), isFalse);
      storage.failReads = true;
      expect(await state('p1', 'u1', '/public/users.php'), RefusalCheck.blocked);
      expect(await state('p1', 'u1', '/public/users.php'), RefusalCheck.blocked);
      expect(await state('p1', 'u1', '/public/other.php'), RefusalCheck.unknown, reason: 'other modules: cannot be told, not cleared');
    });

    test('blocking over a damaged record does not pretend to have stored it', () async {
      storage.data[RefusalSlot.modules] = 'garbage';
      expect(await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php'), isFalse);
      expect(await state('p1', 'u1', '/public/users.php'), RefusalCheck.blocked);
    });

    test('liftModule says whether it worked', () async {
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      storage.failDeletes = true;
      expect(await refusals.liftModule(parishId: 'p1', userId: 'u1', path: '/public/users.php'), LiftResult.failed);
      expect(await blocked('p1', 'u1', '/public/users.php'), isTrue, reason: 'the block that could not be removed is still there');
      storage.failDeletes = false;
      expect(await refusals.liftModule(parishId: 'p1', userId: 'u1', path: '/public/users.php'), LiftResult.done);
      expect(await blocked('p1', 'u1', '/public/users.php'), isFalse);
    });

    test('a lift whose rewrite fails (more than one module blocked) is reported too', () async {
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/a.php');
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/b.php');
      storage.failWrites = true;
      expect(await refusals.liftModule(parishId: 'p1', userId: 'u1', path: '/public/a.php'), LiftResult.failed);
      expect(await blocked('p1', 'u1', '/public/a.php'), isTrue);
    });

    test('a lift over a store that cannot be read is failed, never "done"', () async {
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      storage.failReads = true;
      expect(await refusals.liftModule(parishId: 'p1', userId: 'u1', path: '/public/users.php'), LiftResult.failed);
    });

    test('clearAll removes both records', () async {
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      await refusals.blockDevice(deviceToken: 't', source: 'central_401');
      expect(await refusals.clearAll(), isTrue);
      expect(storage.data, isEmpty);
      expect(await state('p1', 'u1', '/public/users.php'), RefusalCheck.clear, reason: 'memory is cleared with it');
    });

    test('a device refusal and a module refusal do not touch each other', () async {
      await refusals.blockDevice(deviceToken: 't', source: 'central_401');
      await refusals.blockModule(parishId: 'p1', userId: 'u1', path: '/public/users.php');
      expect(await refusals.liftDevice(deviceToken: 'token-A'), LiftResult.done);
      expect(await blocked('p1', 'u1', '/public/users.php'), isTrue, reason: 'a verified ACTIVE confirms the device, not the role');
    });
  });
}
