import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/local_snapshot_server.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';

/// Slows the decryption of a page down so that a request is in flight.
class _SlowEncryptor extends SnapshotEncryptor {
  _SlowEncryptor() : super(hexKey: '1' * 64);

  @override
  Future<List<int>> decryptBytesInBackground(List<int> packed) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return decryptBytes(packed);
  }
}

/// ensureHealthy() repairs a listener the system closed. Its repair is
/// destructive: stop() closes the listener under whatever page is loading from
/// it. A loopback connect that is merely SLOW (a busy emulator) must therefore
/// never be taken for a dead socket.
void main() {
  late Directory root;
  late _SlowEncryptor encryptor;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mm_health_');
    encryptor = _SlowEncryptor();
    File('${root.path}/snapshot.html').writeAsBytesSync(encryptor.encryptBytes(utf8.encode('<html>page</html>')));
  });

  tearDown(() async => root.delete(recursive: true));

  Future<LocalSnapshotServer> started(Future<bool> Function(int) probe) async {
    final server = LocalSnapshotServer(encryptor: encryptor, healthProbe: probe);
    addTearDown(server.stop);
    await server.start();
    server.rootDirectory = root;
    return server;
  }

  test('REGRESSION: a probe that FAILS while a page is being served does not tear the server down', () async {
    var probes = 0;
    final server = await started((_) async {
      probes++;
      return false; // as if the loopback connect were too slow
    });
    final port = server.port;
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final response = client.getUrl(server.urlFor('/snapshot.html')).then((r) => r.close());
    await Future<void>.delayed(const Duration(milliseconds: 150)); // the request is in flight

    expect(await server.ensureHealthy(), port, reason: 'a server that is serving is alive');
    expect(probes, 0, reason: 'and is not even probed');
    expect((await response).statusCode, 200, reason: 'the page that was loading finishes');
  });

  test('a server that served a moment ago is not torn down by one slow probe', () async {
    final server = await started((_) async => false);
    final port = server.port;
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    await (await (await client.getUrl(server.urlFor('/snapshot.html'))).close()).drain<void>();

    expect(await server.ensureHealthy(), port);
    expect(server.isRunning, isTrue);
  });

  test('an idle server needs TWO failed probes in a row: one slow answer is forgiven', () async {
    var probes = 0;
    final server = await started((_) async => ++probes > 1); // fails once, then answers
    final port = server.port;
    expect(await server.ensureHealthy(), port, reason: 'not restarted');
    expect(probes, 2);
  });

  test('an idle server whose socket is really gone IS repaired (two failures)', () async {
    var probes = 0;
    final server = await started((_) async {
      probes++;
      return false;
    });
    await server.debugKillListenerForTest();
    final port = await server.ensureHealthy();
    expect(probes, 2);
    expect(server.isRunning, isTrue);
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
    socket.destroy();
  });

  test('a healthy idle server is probed once and left alone', () async {
    var probes = 0;
    final server = await started((_) async {
      probes++;
      return true;
    });
    final port = server.port;
    expect(await server.ensureHealthy(), port);
    expect(probes, 1);
  });
}
