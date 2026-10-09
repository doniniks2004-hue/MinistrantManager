import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/server_reachability.dart';

void main() {
  group('classifySocketException', () {
    Reachability classify(String message, [int? code, String os = '']) =>
        classifySocketException(
          SocketException(
            message,
            osError: code == null ? null : OSError(os, code),
          ),
        );

    test('no route: the system itself says there is no way out', () {
      expect(classify('Connection failed', 101, 'Network is unreachable'), Reachability.noRoute);
      expect(classify('Connection failed', 113, 'No route to host'), Reachability.noRoute);
      expect(classify('Connection failed', 99, 'Cannot assign requested address'), Reachability.noRoute);
      // By text alone, when no code is given.
      expect(classify('Network is unreachable'), Reachability.noRoute);
    });

    test('a name that cannot be resolved is its own, weaker, verdict', () {
      expect(
        classify(
          "Failed host lookup: 'szarlej.ministrant.eu'",
          7,
          'No address associated with hostname',
        ),
        Reachability.dnsFailure,
      );
      expect(classify('Failed host lookup'), Reachability.dnsFailure);
    });

    test('refused', () {
      expect(classify('Connection failed', 111, 'Connection refused'), Reachability.refused);
    });

    test('timed out', () {
      expect(classify('Connection timed out'), Reachability.timedOut);
      expect(classify('Connection failed', 110, 'Connection timed out'), Reachability.timedOut);
    });

    test('anything unrecognised is the WEAKEST verdict, which must repeat before anyone acts', () {
      expect(classify('something odd'), Reachability.timedOut);
      expect(classify('x', 12345, 'y'), Reachability.timedOut);
    });
  });

  group('ServerReachability.check', () {
    test('reachable: a real socket that is listening', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final reachability = ServerReachability(port: server.port);
      expect(await reachability.check('127.0.0.1'), Reachability.reachable);
    });

    test('refused: a real port nothing listens on', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final reachability = ServerReachability(port: port);
      expect(await reachability.check('127.0.0.1'), Reachability.refused);
    });

    test('no route is reported as such', () async {
      final reachability = ServerReachability(
        connect: (host, port, {timeout}) => Future<Socket>.error(
          SocketException('Connection failed', osError: OSError('Network is unreachable', 101)),
        ),
      );
      expect(await reachability.check('szarlej.ministrant.eu'), Reachability.noRoute);
    });

    test('a connection that never answers is cut off by the check itself', () async {
      final reachability = ServerReachability(
        timeout: const Duration(milliseconds: 50),
        // Ignores its own timeout, like a platform that failed to honour it.
        connect: (host, port, {timeout}) => Completer<Socket>().future,
      );
      final watch = Stopwatch()..start();
      expect(await reachability.check('x'), Reachability.timedOut);
      expect(watch.elapsedMilliseconds, lessThan(1500));
    });

    test('an unexpected error never escapes', () async {
      final reachability = ServerReachability(
        connect: (host, port, {timeout}) => Future<Socket>.error(StateError('boom')),
      );
      expect(await reachability.check('x'), Reachability.timedOut);
    });

    test('the socket opened for the check is closed again', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = <Socket>[];
      server.listen(accepted.add);
      await ServerReachability(port: server.port).check('127.0.0.1');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(accepted, hasLength(1));
      // The client side went away: reading ends instead of waiting forever.
      await accepted.single.timeout(
        const Duration(seconds: 2),
        onTimeout: (sink) => sink.close(),
      ).drain<void>();
    });
  });
}
