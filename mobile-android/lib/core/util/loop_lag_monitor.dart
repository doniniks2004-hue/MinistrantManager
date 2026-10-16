import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

/// Reports stretches in which the isolate that runs the interface did nothing
/// but one long piece of work.
///
/// HYPOTHESIS, NOT A FINDING. An asynchronous read of a 34 KB file reported
/// "read = 240 ms" in a cold start. One explanation is that the read finished
/// early and the isolate could not look at the result because other work held
/// it (a database being opened, a key being derived, a build); another is that
/// the file system was simply slow on a cold emulator. The read time alone does
/// not tell them apart. This measures the isolate directly: if it was busy, here
/// is for how long and when; if it never was, the hypothesis is wrong and the
/// time went elsewhere. It names no culprit either way.
///
/// A timer is asked to fire every [period]; every time it fires LATER than
/// that by more than [reportAbove], the gap is reported. Debug traces only.
class LoopLagMonitor {
  LoopLagMonitor({
    required this.log,
    this.period = const Duration(milliseconds: 10),
    this.reportAbove = const Duration(milliseconds: 100),
    this.window = const Duration(seconds: 20),
  });

  /// Debug builds, and any build made with `--dart-define=MM_TRACE=true`.
  static void startIfTracing() {
    if (kDebugMode || const bool.fromEnvironment('MM_TRACE')) {
      LoopLagMonitor(log: debugPrint).start();
    }
  }

  final void Function(String message) log;
  final Duration period;
  final Duration reportAbove;
  final Duration window;

  Timer? _timer;
  Timer? _windowTimer;
  Duration? _last;
  Duration _worst = Duration.zero;
  Duration _worstAt = Duration.zero;
  final _clock = Stopwatch();

  /// Starts watching for [window], then reports the worst gap and stops.
  void start() {
    if (_timer != null) return;
    _clock.start();
    _last = Duration.zero;
    _timer = Timer.periodic(period, (_) => recordTick(_clock.elapsed));
    _windowTimer = Timer(window, stop);
  }

  void stop() {
    final timer = _timer;
    if (timer == null) return;
    timer.cancel();
    _windowTimer?.cancel();
    _timer = null;
    log('loop-lag: worst gap ${_worst.inMilliseconds} ms, ending at +${_worstAt.inMilliseconds} ms '
        '(watched ${window.inSeconds} s)');
  }

  /// One tick, [now] on this monitor's own clock. Public so the arithmetic can
  /// be tested without making a real isolate wait.
  void recordTick(Duration now) {
    final last = _last ?? Duration.zero;
    _last = now;
    final late = now - last - period;
    if (late <= Duration.zero) return;
    if (late > _worst) {
      _worst = late;
      _worstAt = now;
    }
    if (late >= reportAbove) {
      log('loop-lag: the interface isolate was busy for ${late.inMilliseconds} ms, ending at +${now.inMilliseconds} ms');
    }
  }
}
