import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:path_provider/path_provider.dart';

import 'startup_trace.dart';

/// Says which screen the app has reached, to a CI job that launches it on a
/// simulator and cannot see the screen: a line in the log and a small file in
/// the app's documents folder. Debug builds and builds made with
/// `--dart-define=MM_TRACE=true` only; a release build writes nothing.
///
/// What it records is the name of a screen and the start-up marks (names and
/// milliseconds). No address, no user, no token.
class UiMarker {
  static const _inAnyBuild = bool.fromEnvironment('MM_TRACE');

  /// Every screen reached since the process began, in order. A CI job has to tell
  /// "the app never drew a frame" from "it drew one and stopped at its error
  /// screen" from "it reached the activation screen": the last name alone cannot.
  static final List<String> _screens = [];

  /// Name of the first-frame mark. It says only that something was drawn; it
  /// never replaces a screen that was reached (see [_current]).
  static const firstFrame = 'first_frame';

  /// One write at a time, in the order the calls were made. record() is called
  /// without await (from a frame callback, from the error handler), so two calls
  /// can overlap; without this chain a slow first write could finish AFTER a
  /// later one and put the older state on disk.
  static Future<void> _writes = Future<void>.value();

  /// Tests only: runs just before each file write, so a test can hold the first
  /// write back and check that a later one does not overtake it.
  static Future<void> Function()? debugBeforeWrite;

  /// Tests only.
  static void debugReset() {
    _screens.clear();
    _details.clear();
    _writes = Future<void>.value();
    debugBeforeWrite = null;
  }

  /// The screen the app is on: the last REAL screen reached. first_frame counts
  /// only while nothing else has been reached, so a late first-frame callback can
  /// not push the file back from "activation_screen" to "first_frame".
  static String _current() {
    for (var i = _screens.length - 1; i >= 0; i--) {
      if (_screens[i] != firstFrame) return _screens[i];
    }
    return _screens.isEmpty ? firstFrame : _screens.last;
  }

  /// Only words, digits and a few separators survive, at most 120 characters.
  /// The detail is meant to come from startupErrorDetail(); this is the second
  /// line of defence, not the first.
  static String _safe(String text) {
    final cleaned = text.replaceAll(RegExp(r'[^A-Za-z0-9 _:()\-\.,]'), '');
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }

  /// [directory] is for tests; the app uses its documents folder. [detail] is a
  /// short, safe description (see startupErrorDetail). The returned future
  /// completes when THIS state (or a later one) is on disk.
  static Future<void> record(String screen, {String? detail, Directory? directory}) {
    if (directory == null && !(kDebugMode || _inAnyBuild)) return Future<void>.value();
    StartupTrace.mark('ui_$screen');
    _screens.add(screen);
    final safeDetail = detail == null ? null : _safe(detail);
    // The detail belongs to the screen it came with; a later screen without one
    // clears it.
    _details[screen] = safeDetail;
    debugPrint('ui: $screen shown${safeDetail == null ? '' : ' ($safeDetail)'}');
    final next = _writes.then((_) => _write(directory)).catchError((_) {});
    _writes = next;
    return next;
  }

  static final Map<String, String?> _details = {};

  /// Writes the LATEST state (not the state at the time of the call), to a
  /// temporary file first and then renames it over the real one, so a reader
  /// (the CI job polls the file) sees the old file or the new one, never half.
  static Future<void> _write(Directory? directory) async {
    try {
      final hook = debugBeforeWrite;
      if (hook != null) await hook();
      final dir = directory ?? await getApplicationDocumentsDirectory();
      final current = _current();
      final detail = _details[current];
      final body = jsonEncode({
        'screen': current,
        'screens': List<String>.of(_screens),
        if (detail != null) 'detail': detail,
        'marks': {for (final m in StartupTrace.marks) m.$1: m.$2},
      });
      final tmp = File('${dir.path}/mm_ui_marker.json.tmp');
      await tmp.writeAsString(body, flush: true);
      await tmp.rename('${dir.path}/mm_ui_marker.json');
    } catch (_) {
      // A marker that cannot be written must never affect the app.
    }
  }
}
