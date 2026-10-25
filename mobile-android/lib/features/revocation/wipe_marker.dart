import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Why a wipe was started. Only these three start one: the central server's explicit
/// DEVICE_REVOKED / PARISH_DISABLED, and the user's own "Zmień parafię". A plain 401, an
/// unknown status, a parish `device_state` or a missing module role never does.
enum WipeReason { revoked, parishDisabled, manualReset }

/// "A wipe was started and not yet confirmed complete."
///
/// Written BEFORE anything is deleted, removed only after every required step is confirmed, and
/// read at the very start of the app, before any data can be shown. It holds no secret: a reason,
/// the parish whose saved pages must go (the activation that names it is cleared during the wipe),
/// and a time.
class WipeMarker {
  const WipeMarker({required this.reason, required this.parishId, required this.startedAt});

  /// Null when the stored text cannot be read: a marker that is THERE still means "finish the
  /// wipe", whatever it says.
  final WipeReason? reason;
  final String? parishId;
  final DateTime? startedAt;

  String encode() => jsonEncode({
    'v': 1,
    'reason': reason?.name,
    'parish': parishId,
    'at': startedAt?.toUtc().toIso8601String(),
  });

  /// Never throws. Unreadable text yields a marker with nothing in it, which is still a marker.
  static WipeMarker decode(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is Map) {
        final reason = map['reason'];
        final parish = map['parish'];
        final at = map['at'];
        return WipeMarker(
          reason: WipeReason.values.where((r) => r.name == reason).firstOrNull,
          parishId: parish is String && parish.isNotEmpty ? parish : null,
          startedAt: at is String ? DateTime.tryParse(at) : null,
        );
      }
    } catch (_) {}
    return const WipeMarker(reason: null, parishId: null, startedAt: null);
  }
}

/// One place a marker can live. Every method THROWS when it cannot do what was asked: a store that
/// cannot be read has not said "there is no marker".
abstract class WipeMarkerStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// The fallback place: a small file in the app's own storage, so that a Keystore that refuses the
/// marker does not leave a wipe with nothing to resume it. Holds exactly what the marker holds:
/// a reason, a parish id and a time. No token, key, cookie or URL, so a plain file is the right
/// kind of place for it.
class FileWipeMarkerStore implements WipeMarkerStore {
  FileWipeMarkerStore({Future<Directory> Function()? directory}) : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  static const fileName = 'wipe_in_progress.json';

  Future<File> _file() async => File(p.join((await _directory()).path, fileName));

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(value, flush: true);
  }

  @override
  Future<void> delete() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}

/// The marker kept in several places at once (the Keystore, and a file), so that one that fails does
/// not leave a wipe with nothing to resume it.
///
///  - [write] says whether the marker was stored ANYWHERE. When it says false, nothing will resume
///    that wipe, and no caller may claim otherwise.
///  - [read] returns a marker found in any place. When none has one but a place could not be read,
///    it THROWS: "no marker" is not known then.
///  - [delete] removes it from every place and throws if any could not be cleared (a marker left
///    behind would erase whatever is activated next).
class WipeMarkers {
  WipeMarkers(this.stores);
  final List<WipeMarkerStore> stores;

  Future<bool> write(String value) async {
    var stored = false;
    for (final store in stores) {
      try {
        await store.write(value);
        stored = true;
      } catch (_) {}
    }
    return stored;
  }

  Future<String?> read() async {
    Object? failure;
    for (final store in stores) {
      try {
        final value = await store.read();
        if (value != null) return value;
      } catch (e) {
        failure ??= e;
      }
    }
    if (failure != null) throw failure;
    return null;
  }

  Future<void> delete() async {
    Object? failure;
    for (final store in stores) {
      try {
        await store.delete();
      } catch (e) {
        failure ??= e;
      }
    }
    if (failure != null) throw failure;
  }
}

/// The wipe could not be confirmed complete. Thrown at startup so that the app stops on the
/// retryable error screen instead of showing data that is half erased.
class WipeIncompleteException implements Exception {
  const WipeIncompleteException();
  @override
  String toString() => 'WipeIncompleteException';
}
