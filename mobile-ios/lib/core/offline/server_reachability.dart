import 'dart:async';
import 'dart:io';

/// What a quick TCP connection to the server says about the path to it.
enum Reachability {
  /// The connection was accepted.
  reachable,

  /// The system has no route to the server (network off, no address).
  /// Unambiguous and immediate: the Wi-Fi or mobile data is gone.
  noRoute,

  /// The name could not be resolved. Without a network this is what the
  /// resolver says, but a healthy network can also hiccup on DNS once, so
  /// it counts only when it repeats.
  dnsFailure,

  /// The host answered "nothing listens here" (connection refused).
  refused,

  /// No answer in time.
  timedOut,
}

/// Android/Linux errno values the classification relies on.
const _enetunreach = 101;
const _ehostunreach = 113;
const _eaddrnotavail = 99;
const _econnrefused = 111;
const _etimedout = 110;

/// Sorts a failed connection attempt. Pure, so the mapping is testable
/// without a network. Anything not recognised is [Reachability.timedOut]:
/// the weakest verdict, which needs repeating before anyone acts on it.
Reachability classifySocketException(SocketException error) {
  final code = error.osError?.errorCode;
  final text = '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();

  if (code == _enetunreach ||
      code == _ehostunreach ||
      code == _eaddrnotavail ||
      text.contains('network is unreachable') ||
      text.contains('no route to host')) {
    return Reachability.noRoute;
  }
  if (text.contains('failed host lookup') ||
      text.contains('no address associated') ||
      text.contains('name or service not known')) {
    return Reachability.dnsFailure;
  }
  if (code == _econnrefused || text.contains('connection refused')) {
    return Reachability.refused;
  }
  if (code == _etimedout || text.contains('timed out')) {
    return Reachability.timedOut;
  }
  return Reachability.timedOut;
}

typedef SocketConnector = Future<Socket> Function(
  String host,
  int port, {
  Duration? timeout,
});

/// A real check that the server can be reached: a TCP connection to its
/// HTTPS port, closed at once. Cheap enough to repeat every second or two,
/// and — unlike waiting for a page request to fail — it tells a lost network
/// apart from a slow or refusing server within a moment, with the page
/// sitting idle.
class ServerReachability {
  const ServerReachability({
    this.port = 443,
    this.timeout = const Duration(milliseconds: 1500),
    SocketConnector? connect,
  }) : _connect = connect ?? _defaultConnect;

  final int port;
  final Duration timeout;
  final SocketConnector _connect;

  static Future<Socket> _defaultConnect(
    String host,
    int port, {
    Duration? timeout,
  }) => Socket.connect(host, port, timeout: timeout);

  Future<Reachability> check(String host) async {
    Future<Socket>? attempt;
    try {
      attempt = _connect(host, port, timeout: timeout);
      // The platform's own timeout is not trusted to be the only bound.
      final socket = await attempt.timeout(
        timeout + const Duration(milliseconds: 300),
      );
      socket.destroy();
      return Reachability.reachable;
    } on SocketException catch (e) {
      return classifySocketException(e);
    } on TimeoutException {
      // The attempt is still running and may yet connect: close whatever it
      // opens, so a late answer leaves no socket behind.
      unawaited(
        attempt?.then((socket) => socket.destroy()).catchError((_) {}) ??
            Future<void>.value(),
      );
      return Reachability.timedOut;
    } catch (_) {
      return Reachability.timedOut;
    }
  }
}
