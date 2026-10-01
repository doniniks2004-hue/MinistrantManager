import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/local_snapshot_server.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';

/// Offline-architecture milestone, P2 (updated P8.2). Deliberately uses
/// dart:io's own HttpClient to make REAL requests against a REAL bound
/// server on 127.0.0.1 — no mocking, since the whole point of this
/// class is its actual socket/filesystem behavior, which a mock would
/// just assume away. No new pub.dev dependency needed for this
/// (HttpClient is part of dart:io, same as HttpServer itself).
///
/// P8.2: every fixture file this test writes directly to disk is now
/// written ENCRYPTED (via the same SnapshotEncryptor the server itself
/// uses) — LocalSnapshotServer decrypts every file it serves
/// unconditionally now, so a plain/unencrypted fixture file would fail
/// to decrypt and come back as a 500, not the 200 these tests expect.
void main() {
  // A fixed, valid 64-character hex test key, built programmatically
  // (P8.1's own lesson: a hand-typed long hex literal is a real,
  // recurring risk of an off-by-a-couple-characters mistake).
  final testEncryptor = SnapshotEncryptor(hexKey: 'b' * 64);

  late Directory tempDir;
  late LocalSnapshotServer server;
  late int port;
  final client = HttpClient();

  Future<void> writeEncryptedFile(String path, List<int> plaintext) async {
    await File(path).writeAsBytes(testEncryptor.encryptBytes(plaintext));
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('snapshot_server_test_');
    await writeEncryptedFile('${tempDir.path}/dashboard.php', utf8.encode('<html><body>Dashboard</body></html>'));
    await writeEncryptedFile('${tempDir.path}/style.css', utf8.encode('body { color: red; }'));
    await Directory('${tempDir.path}/assets/img').create(recursive: true);
    await writeEncryptedFile('${tempDir.path}/assets/img/logo.png', [0x89, 0x50, 0x4E, 0x47]);

    server = LocalSnapshotServer(encryptor: testEncryptor);
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
    test('serves an existing file, DECRYPTED, with 200 and the right content', () async {
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

    test('serves nested paths correctly, decrypted back to the exact original bytes', () async {
      final resp = await request('GET', '/assets/img/logo.png');
      expect(resp.statusCode, 200);
      final bytes = await resp.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
      expect(bytes, [0x89, 0x50, 0x4E, 0x47]);
    });

    test('HEAD returns headers (with the DECRYPTED content length) but no body', () async {
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
        await writeEncryptedFile('${otherDir.path}/dashboard.php', utf8.encode('<html><body>Other user</body></html>'));

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

    test('a file that fails to decrypt (e.g. corrupted or genuinely not encrypted) is served as 500, never garbage bytes', () async {
      await File('${tempDir.path}/corrupted.html').writeAsBytes(utf8.encode('this is plain text, not a valid encrypted payload'));
      final resp = await request('GET', '/corrupted.html');
      expect(resp.statusCode, 500);
    });
  });
}
