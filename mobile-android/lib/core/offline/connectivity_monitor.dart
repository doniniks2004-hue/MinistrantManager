import 'dart:async';

import '../network/network_signal.dart';

enum ConnectivityEventKind {
  /// The device has no usable network. Act at once.
  lost,

  /// There is a network but the system itself says it does not reach the
  /// internet (Wi-Fi without internet). Check the server now.
  doubtful,

  /// The network is back (or the system now validates it). The server must
  /// still be confirmed before going online; this only says "ask now".
  returned,
}

class ConnectivityEvent {
  const ConnectivityEvent(this.kind);
  final ConnectivityEventKind kind;

  @override
  String toString() => 'ConnectivityEvent(${kind.name})';
}

/// Turns the raw stream of network states into a few decisions, the same way
/// on every platform.
///
/// What it guarantees:
///  * a loss is reported after a very short grace period ([lossGrace]) — a
///    handover from Wi-Fi to mobile data is a loss followed by an arrival
///    within milliseconds, and must not look like an outage;
///  * "returned" is reported once per loss, never for a state that did not
///    change;
///  * a connection that flaps (more than [flapLimit] changes within
///    [flapWindow]) is held in its last decision for [flapHold] before
///    "returned" is reported, so the app cannot be driven into switching
///    back and forth;
///  * it NEVER claims the server is reachable. "returned" means "check".
class ConnectivityMonitor {
  ConnectivityMonitor(
    this._signal, {
    this.lossGrace = const Duration(milliseconds: 250),
    this.flapWindow = const Duration(seconds: 10),
    this.flapLimit = 4,
    this.flapHold = const Duration(seconds: 3),
  });

  final NetworkSignal _signal;
  final Duration lossGrace;
  final Duration flapWindow;
  final int flapLimit;
  final Duration flapHold;

  final _events = StreamController<ConnectivityEvent>.broadcast();
  StreamSubscription<NetworkState>? _subscription;
  Timer? _graceTimer;
  Timer? _holdTimer;
  Timer? _windowTimer;

  bool _started = false;
  bool _lossReported = false;
  bool _doubtful = false;
  int _changes = 0;
  NetworkState? _latest;

  Stream<ConnectivityEvent> get events => _events.stream;

  /// Safe to call more than once.
  void start() {
    if (_started) return;
    _started = true;
    _subscription = _signal.changes.listen(_onState);
    // The state at start is taken as the baseline: it is not a "change".
    unawaited(
      _signal.current().then((state) {
        if (state != null && _latest == null) _onState(state, baseline: true);
      }),
    );
  }

  void dispose() {
    _subscription?.cancel();
    _graceTimer?.cancel();
    _holdTimer?.cancel();
    _windowTimer?.cancel();
    _events.close();
  }

  void _emit(ConnectivityEventKind kind) {
    if (!_events.isClosed) _events.add(ConnectivityEvent(kind));
  }

  void _countChange() {
    _changes++;
    _windowTimer ??= Timer(flapWindow, () {
      _changes = 0;
      _windowTimer = null;
    });
  }

  void _onState(NetworkState state, {bool baseline = false}) {
    final previous = _latest;
    _latest = state;
    if (previous == state) return;
    if (!baseline) _countChange();

    if (!state.hasInterface) {
      _holdTimer?.cancel();
      if (_lossReported || _graceTimer != null) return;
      _graceTimer = Timer(lossGrace, () {
        _graceTimer = null;
        final latest = _latest;
        if (latest != null && !latest.hasInterface && !_lossReported) {
          _lossReported = true;
          _emit(ConnectivityEventKind.lost);
        }
      });
      return;
    }

    // There is an interface: a loss still inside its grace period was a
    // handover and is forgotten.
    _graceTimer?.cancel();
    _graceTimer = null;

    if (_lossReported) {
      _lossReported = false;
      _doubtful = false;
      _reportReturned();
      return;
    }

    if (state.validated == false) {
      if (!_doubtful) {
        _doubtful = true;
        _emit(ConnectivityEventKind.doubtful);
      }
    } else if (_doubtful) {
      _doubtful = false;
      _reportReturned();
    }
  }

  void _reportReturned() {
    if (_changes <= flapLimit) {
      _emit(ConnectivityEventKind.returned);
      return;
    }
    // Flapping: wait until it has been quiet, then report what is true NOW.
    _holdTimer?.cancel();
    _holdTimer = Timer(flapHold, () {
      _holdTimer = null;
      final latest = _latest;
      if (latest != null && latest.hasInterface && latest.validated != false) {
        _emit(ConnectivityEventKind.returned);
      }
    });
  }
}
