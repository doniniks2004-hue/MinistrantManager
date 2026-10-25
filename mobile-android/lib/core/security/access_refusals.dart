import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

/// Where [AccessRefusals] keeps its two records. The production implementation is the
/// Keystore/Keychain (see SecureStorageService.refusalStorage); tests use a map.
abstract class RefusalStorage {
  Future<String?> read(RefusalSlot slot);
  Future<void> write(RefusalSlot slot, String value);
  Future<void> delete(RefusalSlot slot);
}

enum RefusalSlot { device, modules }

/// A storage that is one physical place however many objects stand in front of it (the platform
/// keystore: every `AccessRefusals` built after a rebuild of the services reaches the SAME one).
/// Instances whose storages report the same [gateKey] share one queue of operations.
abstract interface class SharedRefusalStorage {
  Object get gateKey;
}

/// The queue of operations on one physical storage: one chain per record, and the real calls that
/// are still running. Shared by EVERY [AccessRefusals] in front of that storage, so that a call that
/// an old instance gave up on (and that is still running) is waited for by a new instance before it
/// touches the same record: an old delete cannot finish after, and remove, a newer write.
class _Gate {
  final serial = <RefusalSlot, Future<void>>{
    for (final slot in RefusalSlot.values) slot: Future<void>.value(),
  };
  final inFlight = <RefusalSlot, Set<Future<void>>>{};

  static final _byKey = <Object, _Gate>{};
  static final _byStorage = Expando<_Gate>('refusal storage gate');

  static _Gate of(RefusalStorage storage) {
    if (storage is SharedRefusalStorage) {
      return _byKey.putIfAbsent(storage.gateKey, _Gate.new);
    }
    return _byStorage[storage] ??= _Gate();
  }
}

/// What a handoff reply means for the saved copy. Decided from the reply's own machine fields,
/// never from the status code alone: the same 403 means a revoked device, a role without a module,
/// a wrong parish, a used ticket, or a hosting firewall, and only some of those are a refusal this
/// app may act on.
enum HandoffRefusal {
  /// Not an unambiguous refusal: nothing is remembered and nothing is blocked.
  none,

  /// The parish server says THIS DEVICE is not authorized, with a state that says so.
  device,

  /// The server says this USER's role has no access to THIS MODULE.
  module,

  /// Not a reply of the server: THIS APP could not find out whether a refusal stands (the local
  /// record cannot be read, or is damaged). Treated like a block for what it protects (no saved
  /// copy is opened), but nothing is erased and nothing is remembered; trying again can settle it.
  unknown,
}

/// The three answers to "is there a refusal in force?". Never two: a record that cannot be read is
/// neither "no refusal" nor "a refusal", and acting as though it were either is the mistake.
enum RefusalCheck {
  /// Nothing stands in the way.
  clear,

  /// A refusal stands.
  blocked,

  /// It could not be found out (storage error, damaged record). Saved data is not handed out.
  unknown,
}

/// What lifting a refusal came to. A lift that failed leaves the persistent record where it was,
/// and the caller must know it (a block that could not be removed is not "lifted").
enum LiftResult {
  /// Removed (or there was nothing of this activation's to remove).
  done,

  /// The record may still be there.
  failed,

  /// The answer that asked for the lift no longer belongs to the current activation (the token
  /// changed while it was on its way). NOTHING was touched: what is stored is not its to remove.
  superseded,
}

/// The device check: the verdict, and the refusal itself when there is one.
class DeviceRefusalCheck {
  const DeviceRefusalCheck(this.check, [this.refusal]);
  final RefusalCheck check;
  final DeviceRefusal? refusal;
}

/// `device_state` values (parish `DeviceAuthorizationService`, centrally decided by
/// `DeviceValidationEvaluator`) that are a definite "no" for the device.
/// `central_unavailable` is deliberately NOT here: it is "could not check", and arrives as 503.
const deviceStatesThatRefuse = {'revoked', 'parish_disabled', 'not_found', 'parish_mismatch'};

HandoffRefusal classifyHandoffRefusal({int? status, String? errorCode, String? deviceState}) {
  if (status == 403 && errorCode == 'device_not_authorized' && deviceStatesThatRefuse.contains(deviceState)) {
    return HandoffRefusal.device;
  }
  if (status == 403 && errorCode == 'forbidden') return HandoffRefusal.module;
  return HandoffRefusal.none;
}

/// A device refusal that was RECEIVED and is still in force.
class DeviceRefusal {
  const DeviceRefusal({required this.source, required this.at});

  /// A short machine label of where it came from, e.g. `central_401` or `parish_revoked`.
  final String source;
  final DateTime at;
}

/// A record of refusals the server has given, kept across restarts, so that a LATER start with no
/// connection cannot open the saved copy as though the refusal had never been received.
///
/// What it is not:
///  - not a revocation. Nothing here erases data. Revocation is the central server's explicit
///    DEVICE_REVOKED / PARISH_DISABLED answer and is handled by RevocationHandler.
///  - not a guess. It records only replies that are unambiguous (see [classifyHandoffRefusal] and
///    SyncEngine), and an unknown status never adds to it nor removes from it.
///
/// Two kinds, each lifted only by the evidence that answers it:
///  - DEVICE: bound to a fingerprint of the device token it was received for. Lifted by a verified
///    ACTIVE from the central server (SyncEngine) for that token; a different token (a new
///    activation) is not covered by it and is dropped when seen.
///  - MODULE: bound to parish + user + the module's entry path. Lifted only by a handoff that the
///    server accepts for that module: central ACTIVE says the device is fine, not that the user's
///    role may open the module.
///
/// Nothing in it is a secret: no token, cookie, password or URL. A fingerprint is the first 16 hex
/// characters of the token's SHA-256.
class AccessRefusals {
  AccessRefusals(this._rawStorage, {DateTime Function()? clock, this.storageTimeout = const Duration(seconds: 4)})
      : _clock = clock ?? DateTime.now;

  final RefusalStorage _rawStorage;
  late final _Gate _gate = _Gate.of(_rawStorage);
  late final _TimedStorage _storage = _TimedStorage(_rawStorage, storageTimeout, _gate);

  /// A keystore call that does not answer in this time counts as a failure (unknown / not written /
  /// not lifted) for whoever asked. The call itself is NOT cancelled (a platform call cannot be), so
  /// nothing new is started on that record until it has really finished ([_TimedStorage.settled]):
  /// a delete that is still running cannot end up removing a refusal written after it was given up on.
  final Duration storageTimeout;
  final DateTime Function() _clock;

  /// The most module refusals that are kept in storage. A full register is NOT made room in by
  /// dropping an old refusal: that would turn a refusal that was received into "no refusal" after
  /// the next restart. The one that does not fit is held for this process only and [blockModule]
  /// says so (false), exactly like a write that failed; every stored record stays.
  static const maxModuleRecords = 256;

  static final _label = RegExp(r'^[a-z0-9_]{1,40}$');

  // One queue per record, so the read-modify-write of one never interleaves with another call on
  // the same record, while the device record and the module record can be read at the same time.
  // The queue belongs to the STORAGE (see [_Gate]), not to this instance: after the services are
  // rebuilt a new instance queues behind what the old one left running.
  Future<T> _exclusive<T>(RefusalSlot slot, Future<T> Function() action) {
    final run = _gate.serial[slot]!.then((_) => action());
    _gate.serial[slot] = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Waits until every storage call already made on [slot] has really finished, for at most
  /// [storageTimeout]; throws TimeoutException when one is still running. Called inside the
  /// try-block of an action, before it touches the storage.
  Future<void> _settled(RefusalSlot slot) => _storage.settled(slot).timeout(storageTimeout);

  static String fingerprint(String deviceToken) =>
      sha256.convert(utf8.encode(deviceToken)).toString().substring(0, 16);

  // ---- what this PROCESS knows ----
  //
  // A refusal that was received is held here too, whether or not it could be written. A write that
  // fails (the Keystore is unavailable) must not turn a refusal into "nothing happened" for the rest
  // of the run: the next check, and the switch to offline, still see it. Memory is only a floor:
  // it never decides "clear" on its own, and it is dropped only by a lift (or clearAll).
  final _memDevice = <String, DeviceRefusal>{};
  DeviceRefusal? _memDeviceWithoutToken;
  final _memModules = <String>{};

  static String _moduleKey(String parishId, String userId, String path) => jsonEncode([parishId, userId, path]);

  // ---- device ----

  /// Remembers that the server refused THIS device token: in this process at once, and in storage.
  /// Returns whether it could be WRITTEN. When it could not, the block stands for this run anyway.
  Future<bool> blockDevice({required String deviceToken, required String source}) => _exclusive(RefusalSlot.device, () async {
        final label = _label.hasMatch(source) ? source : 'unknown';
        final now = _clock();
        _memDevice[fingerprint(deviceToken)] = DeviceRefusal(source: label, at: now);
        try {
          await _settled(RefusalSlot.device);
          final record = jsonEncode({
            'tf': fingerprint(deviceToken),
            'src': label,
            'at': now.toUtc().toIso8601String(),
          });
          await _storage.write(RefusalSlot.device, record);
          return true;
        } catch (_) {
          return false;
        }
      });

  /// The device was refused but its token could not even be read, so nothing can be bound to it:
  /// the refusal stands for this process, whatever token is read later. Not persisted.
  Future<void> blockDeviceWithoutToken({required String source}) => _exclusive(RefusalSlot.device, () async {
        _memDeviceWithoutToken = DeviceRefusal(
          source: _label.hasMatch(source) ? source : 'unknown',
          at: _clock(),
        );
      });

  /// Whether a refusal is in force for [deviceToken]. [tokenReadFailed] says the token could not be
  /// read at all (then nothing can be compared: unless this process already knows of a refusal, the
  /// answer is [RefusalCheck.unknown]). A null token with no failure is "not activated": clear.
  ///
  /// A record made for another token is not in force (and is dropped): a new activation starts
  /// clean. A record that cannot be read or parsed is [RefusalCheck.unknown], not clear.
  Future<DeviceRefusalCheck> checkDevice({required String? deviceToken, bool tokenReadFailed = false}) =>
      _exclusive(RefusalSlot.device, () async {
        final any = _memDeviceWithoutToken;
        if (any != null) return DeviceRefusalCheck(RefusalCheck.blocked, any);
        if (deviceToken == null) {
          return DeviceRefusalCheck(tokenReadFailed ? RefusalCheck.unknown : RefusalCheck.clear);
        }
        final fp = fingerprint(deviceToken);
        final inMemory = _memDevice[fp];
        if (inMemory != null) return DeviceRefusalCheck(RefusalCheck.blocked, inMemory);
        try {
          await _settled(RefusalSlot.device);
          final raw = await _storage.read(RefusalSlot.device);
          if (raw == null) return const DeviceRefusalCheck(RefusalCheck.clear);
          // The WHOLE record is checked first. Only a complete, valid record can be said to belong to
          // another token; anything else (`{}`, a missing field, the wrong type) is damaged, which is
          // "cannot tell", and is neither deleted nor read as clear.
          final record = _parseDeviceRecord(raw);
          if (record == null) return const DeviceRefusalCheck(RefusalCheck.unknown);
          if (record.tf != fp) {
            try {
              await _storage.delete(RefusalSlot.device);
            } catch (_) {
              // A record for another token does not apply to this one; failing to tidy it is no reason to refuse.
            }
            return const DeviceRefusalCheck(RefusalCheck.clear);
          }
          return DeviceRefusalCheck(RefusalCheck.blocked, DeviceRefusal(source: record.src, at: record.at));
        } catch (_) {
          return const DeviceRefusalCheck(RefusalCheck.unknown);
        }
      });

  static final _fingerprintShape = RegExp(r'^[0-9a-f]{16}$');

  /// The record, or null unless every field is present, of the right type and shape.
  static ({String tf, String src, DateTime at})? _parseDeviceRecord(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final tf = map['tf'];
      final src = map['src'];
      final at = map['at'];
      if (tf is! String || !_fingerprintShape.hasMatch(tf)) return null;
      if (src is! String || !_label.hasMatch(src)) return null;
      if (at is! String) return null;
      final time = DateTime.tryParse(at);
      if (time == null) return null;
      return (tf: tf, src: src, at: time);
    } catch (_) {
      return null;
    }
  }

  /// Lifts the device refusal for [deviceToken]. Only a verified ACTIVE from the central server may
  /// call this, and only for the token that answer was FOR.
  ///
  /// [stillCurrent] is asked inside the queue, right before anything is removed: when the activation
  /// has changed while the answer was on its way, nothing is touched ([LiftResult.superseded]). A
  /// stored record that belongs to another token is never removed by it either.
  /// [LiftResult.failed] means the persistent record may still be there: the caller must say so (the
  /// device is not confirmed free of the block) and must not report the lift as done.
  Future<LiftResult> liftDevice({required String deviceToken, Future<bool> Function()? stillCurrent}) =>
      _exclusive(RefusalSlot.device, () async {
        final fp = fingerprint(deviceToken);
        try {
          await _settled(RefusalSlot.device);
          if (stillCurrent != null && !await stillCurrent()) return LiftResult.superseded;
          String? raw;
          try {
            raw = await _storage.read(RefusalSlot.device);
          } catch (_) {
            // Cannot tell whose it is; the activation was just confirmed current, so it is removed.
          }
          if (raw != null) {
            final record = _parseDeviceRecord(raw);
            // A complete record of ANOTHER token is not this answer's to remove. A damaged one is
            // removed: nothing can be said to belong to anyone, and this token was just confirmed ACTIVE.
            if (record != null && record.tf != fp) {
              _memDevice.remove(fp);
              _memDeviceWithoutToken = null;
              return LiftResult.done;
            }
          }
          await _storage.delete(RefusalSlot.device);
        } catch (_) {
          return LiftResult.failed;
        }
        _memDevice.remove(fp);
        _memDeviceWithoutToken = null;
        return LiftResult.done;
      });

  // ---- modules ----

  static Map<String, Object?> _entry(String parishId, String userId, String path) =>
      {'p': parishId, 'u': userId, 'm': path};

  /// The stored records. Throws when the stored text is not a list: damaged is not empty.
  Future<List<Map<String, Object?>>> _readModules() async {
    final raw = await _storage.read(RefusalSlot.modules);
    if (raw == null) return [];
    final list = jsonDecode(raw);
    if (list is! List) throw const FormatException('module refusals are damaged');
    // Every element must be a complete record. One that is not is damage, and damage is reported
    // (the caller sees "cannot tell"), never filtered out: an element that vanished silently could
    // have been the block that mattered.
    return [
      for (final e in list)
        if (e is Map &&
            e['p'] is String &&
            (e['p'] as String).isNotEmpty &&
            e['u'] is String &&
            (e['u'] as String).isNotEmpty &&
            e['m'] is String &&
            (e['m'] as String).isNotEmpty &&
            e['at'] is String &&
            DateTime.tryParse(e['at'] as String) != null)
          Map<String, Object?>.from(e)
        else
          throw const FormatException('module refusals are damaged'),
    ];
  }

  bool _same(Map<String, Object?> e, String parishId, String userId, String path) =>
      e['p'] == parishId && e['u'] == userId && e['m'] == path;

  /// Blocks one module for one user: in this process at once, and in storage. Returns whether it
  /// could be written; when not, the block still stands for this run.
  Future<bool> blockModule({required String parishId, required String userId, required String path}) =>
      _exclusive(RefusalSlot.modules, () async {
        _memModules.add(_moduleKey(parishId, userId, path));
        try {
          await _settled(RefusalSlot.modules);
          final list = await _readModules();
          list.removeWhere((e) => _same(e, parishId, userId, path));
          // Nothing is ever dropped to make room. A refusal that already has its record is rewritten
          // in place (the removeWhere above is its own old record, so the count does not grow).
          if (list.length >= maxModuleRecords) return false;
          list.add({..._entry(parishId, userId, path), 'at': _clock().toUtc().toIso8601String()});
          await _storage.write(RefusalSlot.modules, jsonEncode(list));
          return true;
        } catch (_) {
          return false;
        }
      });

  Future<RefusalCheck> checkModule({required String parishId, required String userId, required String path}) =>
      _exclusive(RefusalSlot.modules, () async {
        if (_memModules.contains(_moduleKey(parishId, userId, path))) return RefusalCheck.blocked;
        try {
          await _settled(RefusalSlot.modules);
          return (await _readModules()).any((e) => _same(e, parishId, userId, path))
              ? RefusalCheck.blocked
              : RefusalCheck.clear;
        } catch (_) {
          return RefusalCheck.unknown;
        }
      });

  /// Lifts the block on one module for one user. Only a handoff the server ACCEPTED for that
  /// module may call this. [LiftResult.failed]: the persistent block may still be there.
  Future<LiftResult> liftModule({
    required String parishId,
    required String userId,
    required String path,
    Future<bool> Function()? stillCurrent,
  }) =>
      _exclusive(RefusalSlot.modules, () async {
        try {
          await _settled(RefusalSlot.modules);
          // Asked inside the queue, right before anything is removed: an answer that belongs to
          // something that is over (a wipe started meanwhile) removes nothing.
          if (stillCurrent != null && !await stillCurrent()) return LiftResult.superseded;
          final list = await _readModules();
          final before = list.length;
          list.removeWhere((e) => _same(e, parishId, userId, path));
          if (list.length != before) {
            if (list.isEmpty) {
              await _storage.delete(RefusalSlot.modules);
            } else {
              await _storage.write(RefusalSlot.modules, jsonEncode(list));
            }
          }
        } catch (_) {
          return LiftResult.failed;
        }
        _memModules.remove(_moduleKey(parishId, userId, path));
        return LiftResult.done;
      });

  /// Both records and what this process holds, e.g. at a revocation or a reset of the activation.
  /// False when a record could not be deleted.
  Future<bool> clearAll() async {
    final results = await Future.wait([
      for (final slot in RefusalSlot.values)
        _exclusive(slot, () async {
          try {
            await _settled(slot);
            await _storage.delete(slot);
            return true;
          } catch (_) {
            return false;
          }
        }),
    ]);
    _memDevice.clear();
    _memDeviceWithoutToken = null;
    _memModules.clear();
    return results.every((ok) => ok);
  }
}

/// Every call is cut off after [timeout] for the caller (a TimeoutException, which every caller
/// above treats as "could not"). The call is NOT cancelled: it is remembered until it has really
/// finished, and [settled] waits for that. Without it a delete that was given up on could finish
/// after a newer record was written, and remove it.
class _TimedStorage implements RefusalStorage {
  _TimedStorage(this._inner, this._timeout, this._gate);
  final RefusalStorage _inner;
  final Duration _timeout;
  final _Gate _gate;
  Map<RefusalSlot, Set<Future<void>>> get _inFlight => _gate.inFlight;

  Future<T> _track<T>(RefusalSlot slot, Future<T> Function() call) {
    final raw = call();
    final set = _inFlight.putIfAbsent(slot, () => <Future<void>>{});
    late final Future<void> done;
    // Errors of a call that was already given up on must not become unhandled.
    done = raw.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      set.remove(done);
    });
    set.add(done);
    return raw.timeout(_timeout);
  }

  /// Completes when no call on [slot] is still running.
  Future<void> settled(RefusalSlot slot) async {
    while (true) {
      final running = _inFlight[slot];
      if (running == null || running.isEmpty) return;
      await Future.wait(running.toList());
    }
  }

  @override
  Future<String?> read(RefusalSlot slot) => _track(slot, () => _inner.read(slot));

  @override
  Future<void> write(RefusalSlot slot, String value) => _track(slot, () => _inner.write(slot, value));

  @override
  Future<void> delete(RefusalSlot slot) => _track(slot, () => _inner.delete(slot));
}
