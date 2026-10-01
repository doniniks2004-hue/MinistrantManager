import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/local_snapshot_server.dart';

/// Offline-architecture milestone, P2. Deliberately uses dart:io's own
/// HttpClient to make REAL requests against a REAL bound server on
/// 127.0.0.1 — no mocking, since the whole point of this class is its
/// actual socket/filesystem behavior, which a mock would just assume
/// away. No new pub.dev dependency needed for this (HttpClient is part
/// of dart:io, same as HttpServer itself).
void main() {
  late Directory tempDir;
  late LocalSnapshotServer server;
  late int port;
  final client = HttpClient();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('snapshot_server_test_');
    await File('${tempDir.path}/dashboard.php').writeAsString('<html><body>Dashboard</body></html>');
    await File('${tempDir.path}/style.css').writeAsString('body { color: red; }');
    await Directory('${tempDir.path}/assets/img').create(recursive: true);
    await File('${tempDir.path}/assets/img/logo.png').writeAsBytes([0x89, 0x50, 0x4E, 0x47]);

    server = LocalSnapshotServer();
    port = await server.start();
    server.rootDirectory = tempDir;
  });

  tearDown(() async {
    await server.stop();
    await tempDir.delete(recursive: true);
  });

  Future<HttpClientResponse> request(String method, String path) async {
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    return req.close();
  }

  group('LocalSnapshotServer', () {
    test('serves an existing file with 200 and the right content', () async {
      final resp = await request('GET', '/dashboard.php');
      expect(resp.statusCode, 200);
      final body = await utf8.decoder.bind(resp).join();
      expect(body, '<html><body>Dashboard</body></html>');
    });

    test('sets the correct MIME type per extension', () async {
      final html = await request('GET', '/dashboard.php');
      expect(html.headers.contentType?.mimeType, 'text/html');

      final css = await request('GET', '/style.css');
      expect(css.headers.contentType?.mimeType, 'text/css');

      final png = await request('GET', '/assets/img/logo.png');
      expect(png.headers.contentType?.mimeType, 'image/png');
    });

    test('serves nested paths correctly', () async {
      final resp = await request('GET', '/assets/img/logo.png');
      expect(resp.statusCode, 200);
      final bytes = await resp.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
      expect(bytes, [0x89, 0x50, 0x4E, 0x47]);
    });

    test('HEAD returns headers but no body', () async {
      final resp = await request('HEAD', '/dashboard.php');
      expect(resp.statusCode, 200);
      expect(resp.headers.contentLength, '<html><body>Dashboard</body></html>'.length);
      final body = await utf8.decoder.bind(resp).join();
      expect(body, isEmpty);
    });

    test('404 for a file that genuinely does not exist', () async {
      final resp = await request('GET', '/does-not-exist.php');
      expect(resp.statusCode, 404);
    });

    test(
      'review round security requirement: path traversal is rejected as a plain 404, never a distinct error that would confirm the path was understood',
      () async {
        final resp = await request('GET', '/../../../../etc/passwd');
        expect(resp.statusCode, 404);
      },
    );

    test('requesting the root directory itself (no path) is 404, never a directory listing', () async {
      final resp = await request('GET', '/');
      expect(resp.statusCode, 404);
    });

    test('POST (or any non-GET/HEAD method) is 405 without touching the filesystem', () async {
      final resp = await request('POST', '/dashboard.php');
      expect(resp.statusCode, 405);
    });

    test('404 when no rootDirectory is set at all yet', () async {
      server.rootDirectory = null;
      final resp = await request('GET', '/dashboard.php');
      expect(resp.statusCode, 404);
    });

    test(
      'rootDirectory is re-read per request — switching it (e.g. on user/parish switch) takes effect immediately, no restart needed',
      () async {
        final otherDir = await Directory.systemTemp.createTemp('snapshot_server_test_other_');
        await File('${otherDir.path}/dashboard.php').writeAsString('<html><body>Other user</body></html>');

        server.rootDirectory = otherDir;
        final resp = await request('GET', '/dashboard.php');
        final body = await utf8.decoder.bind(resp).join();
        expect(body, '<html><body>Other user</body></html>', reason: 'must serve the NEW root, not the old tempDir content');

        await otherDir.delete(recursive: true);
      },
    );

    test('calling start() twice returns the same port rather than binding again', () async {
      final secondPort = await server.start();
      expect(secondPort, port);
    });

    test('after stop(), the port is no longer accepting connections', () async {
      await server.stop();
      expect(server.isRunning, isFalse);
      await expectLater(
        client.openUrl('GET', Uri.parse('http://127.0.0.1:$port/dashboard.php')).then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
    });
  });
}
