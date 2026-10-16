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

  /// [directory] is for tests; the app uses its documents folder.
  static Future<void> record(String screen, {Directory? directory}) async {
    if (directory == null && !(kDebugMode || _inAnyBuild)) return;
    StartupTrace.mark('ui_$screen');
    debugPrint('ui: $screen shown');
    try {
      final dir = directory ?? await getApplicationDocumentsDirectory();
      await File('${dir.path}/mm_ui_marker.json').writeAsString(
        jsonEncode({
          'screen': screen,
          'marks': {for (final m in StartupTrace.marks) m.$1: m.$2},
        }),
        flush: true,
      );
    } catch (_) {
      // A marker that cannot be written must never affect the app.
    }
  }
}
