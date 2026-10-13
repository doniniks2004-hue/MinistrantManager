import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/local_snapshot_server.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';

/// Counts (and can slow down) the decryptions the server asks for.
class _CountingEncryptor extends SnapshotEncryptor {
  _CountingEncryptor() : super(hexKey: '1' * 64);

  int decrypts = 0;
  Duration delay = Duration.zero;

  @override
  Future<List<int>> decryptBytesInBackground(List<int> packed) async {
    decrypts++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return decryptBytes(packed);
  }
}

/// The first opening of a saved page decrypted ~260 KB (page, stylesheet,
/// script, logo) in plain Dart on the interface's isolate, and a retry did all
/// of it again. These pin what replaced that: once per file version, never
/// again for the same bytes, never served once the file is gone, never kept
/// after sign-out.
void main() {
  late Directory root;
  late _CountingEncryptor encryptor;
  late LocalSnapshotServer server;
  late HttpClient client;

  File put(String name, String content) {
    final file = File('${root.path}/$name')..createSync(recursive: true);
    file.writeAsBytesSync(encryptor.encryptBytes(utf8.encode(content)));
    return file;
  }

  Future<(int, String)> get(String name) async {
    final request = await client.getUrl(server.urlFor('/$name'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (response.statusCode, body);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mm_decrypt_cache_');
    encryptor = _CountingEncryptor();
    server = LocalSnapshotServer(encryptor: encryptor);
    await server.start();
    server.rootDirectory = root;
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await root.delete(recursive: true);
  });

  test('the first request decrypts; the second is served from memory', () async {
    put('snapshot.html', '<html>dashboard</html>');
    expect(await get('snapshot.html'), (200, '<html>dashboard</html>'));
    expect(encryptor.decrypts, 1);
    expect(await get('snapshot.html'), (200, '<html>dashboard</html>'));
    expect(encryptor.decrypts, 1, reason: 'nothing was decrypted again');
  });

  test('requests that arrive together share ONE decryption', () async {
    put('snapshot.html', 'x' * 500);
    encryptor.delay = const Duration(milliseconds: 150);
    final results = await Future.wait([for (var i = 0; i < 5; i++) get('snapshot.html')]);
    expect(results.every((r) => r.$1 == 200 && r.$2 == 'x' * 500), isTrue);
    expect(encryptor.decrypts, 1);
  });

  test('a page prepared ahead costs nothing when it is opened', () async {
    put('snapshot.html', '<html>page</html>');
    put('assets/public/css/style.css', 'body{}');
    put('assets/public/js/script.js', 'var a;');
    put('manifest.json', '{"not":"served"}');

    await server.prewarm(root);
    final decryptedByPrewarm = encryptor.decrypts;
    expect(decryptedByPrewarm, 3, reason: 'every file of the page except the manifest');

    await get('snapshot.html');
    await get('assets/public/css/style.css');
    await get('assets/public/js/script.js');
    expect(encryptor.decrypts, decryptedByPrewarm, reason: 'opening the page decrypted nothing');
  });

  test('a file that was REPLACED is decrypted again, and the new bytes are served', () async {
    final file = put('snapshot.html', 'old');
    expect((await get('snapshot.html')).$2, 'old');
    file.writeAsBytesSync(encryptor.encryptBytes(utf8.encode('new and longer')));
    expect((await get('snapshot.html')).$2, 'new and longer');
    expect(encryptor.decrypts, 2);
  });

  test('a DELETED file is a 404 even though its plaintext is in memory', () async {
    final file = put('snapshot.html', 'secret page');
    await get('snapshot.html');
    expect(server.hasDecrypted(file), isTrue);
    file.deleteSync(); // logout, revocation
    expect((await get('snapshot.html')).$1, 404);
  });

  test('clearing the root (sign-out, lease expiry) forgets everything', () async {
    final file = put('snapshot.html', 'page');
    await get('snapshot.html');
    expect(server.hasDecrypted(file), isTrue);

    server.rootDirectory = null;
    expect(server.hasDecrypted(file), isFalse);

    server.rootDirectory = root;
    await get('snapshot.html');
    expect(encryptor.decrypts, 2, reason: 'decrypted again, not remembered');
  });

  test('a decryption that was RUNNING when the cache was cleared is not put back', () async {
    final file = put('snapshot.html', 'page');
    encryptor.delay = const Duration(milliseconds: 250);
    final pending = get('snapshot.html').catchError((_) => (0, ''));
    await Future<void>.delayed(const Duration(milliseconds: 60)); // it is decrypting
    server.rootDirectory = null; // sign-out
    await pending;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(server.hasDecrypted(file), isFalse);
  });

  test('stop() forgets everything too', () async {
    final file = put('snapshot.html', 'page');
    await get('snapshot.html');
    await server.stop();
    expect(server.hasDecrypted(file), isFalse);
  });

  test('memory is BOUNDED: the least recently used page goes first', () async {
    final small = LocalSnapshotServer(encryptor: encryptor, cacheLimitBytes: 100);
    addTearDown(small.stop);
    await small.start();
    small.rootDirectory = root;

    final a = put('a.html', 'a' * 60);
    final b = put('b.html', 'b' * 60);
    Future<void> fetch(String name) async {
      final r = await client.getUrl(small.urlFor('/$name'));
      await (await r.close()).drain<void>();
    }

    await fetch('a.html');
    await fetch('b.html');
    expect(small.hasDecrypted(b), isTrue);
    expect(small.hasDecrypted(a), isFalse, reason: '60 + 60 > 100: the older one made room');
  });

  test('a file bigger than the whole limit is served but not kept', () async {
    final small = LocalSnapshotServer(encryptor: encryptor, cacheLimitBytes: 50);
    addTearDown(small.stop);
    await small.start();
    small.rootDirectory = root;
    final big = put('big.html', 'z' * 200);
    final r = await client.getUrl(small.urlFor('/big.html'));
    final response = await r.close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    expect(small.hasDecrypted(big), isFalse);
  });

  test('a file that cannot be decrypted is a 500, and is not remembered', () async {
    final file = File('${root.path}/snapshot.html')..writeAsBytesSync(List.filled(64, 7));
    expect((await get('snapshot.html')).$1, 500);
    expect(server.hasDecrypted(file), isFalse);
  });

  test('every served file leaves one line in the trace: memory or decrypted, with the cost', () async {
    put('snapshot.html', 'page');
    final lines = <String>[];
    server.trace = lines.add;
    await get('snapshot.html');
    await get('snapshot.html');
    expect(lines, hasLength(2));
    expect(lines[0], allOf(contains('snapshot.html'), contains('decrypted'), contains('decrypt=')));
    expect(lines[1], allOf(contains('snapshot.html'), contains('memory')));
  });
}
