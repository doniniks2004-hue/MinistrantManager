import 'package:meta/meta.dart';

/// Milliseconds, from the first Dart code of this process, at which the
/// start-up reached each stage. Each name is recorded ONCE (the first time):
/// it describes the cold start, not every later screen change.
///
/// It exists so a slow or black start on a real phone can be explained with
/// numbers read off the device (device settings -> diagnostics), instead of
/// guessed at or inferred from a log nobody can attach. It does not include
/// Android's own process/engine start-up, which happens before any Dart runs.
class StartupTrace {
  StartupTrace._();

  static final Stopwatch _clock = Stopwatch()..start();
  static final List<(String, int)> _marks = [];

  static void mark(String name) {
    if (_marks.any((m) => m.$1 == name)) return;
    _marks.add((name, _clock.elapsedMilliseconds));
  }

  static List<(String, int)> get marks => List.unmodifiable(_marks);

  /// One "stage: N ms" per line, in the order reached.
  static String format() => _marks.isEmpty
      ? 'brak danych'
      : _marks.map((m) => '${m.$1}: ${m.$2} ms').join('\n');

  @visibleForTesting
  static void reset() => _marks.clear();
}
