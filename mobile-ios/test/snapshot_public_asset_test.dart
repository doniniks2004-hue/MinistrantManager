import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ministrant_manager/core/offline/local_snapshot_server.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';

/// Counts the cipher work the server asks for (a hash-checked public resource
/// must not ask for any).
class _CountingEncryptor extends SnapshotEncryptor {
  _CountingEncryptor({String? hexKey}) : super(hexKey: hexKey ?? '1' * 64);
  int decrypts = 0;

  @override
  Future<List<int>> decryptBytesInBackground(List<int> packed) {
    decrypts++;
    return super.decryptBytesInBackground(packed);
  }
}

/// A write that can be held half-way.
class _GatedEncryptor extends _CountingEncryptor {
  Completer<void>? gate;

  @override
  Future<List<int>> encryptBytesInBackground(List<int> plaintext) async {
    final held = gate;
    if (held != null) await held.future;
    return encryptBytes(plaintext);
  }
}

Uint8List _bytes(int n, [int seed = 7]) {
  final random = Random(seed);
  return Uint8List.fromList(List<int>.generate(n, (_) => random.nextInt(256)));
}

void main() {
  group('SnapshotEncryptor: a resource fetched anonymously is authenticated, not encrypted', () {
    final e = SnapshotEncryptor(hexKey: 'a' * 64);

    test('seals and opens under the same label', () {
      final body = _bytes(5000);
      final stored = e.sealPublic('assets/public/ikona.png', body);
      expect(e.isPublicFormat(stored), isTrue);
      expect(e.openPublic('assets/public/ikona.png', stored), body);
    });

    test('it is NOT encrypted: the bytes are there, authenticated (documented, deliberate)', () {
      final stored = e.sealPublic('assets/x.css', utf8.encode('body{color:red}'));
      expect(utf8.decode(stored.sublist(36)), 'body{color:red}');
    });

    test('a changed byte is refused', () {
      final stored = Uint8List.fromList(e.sealPublic('assets/x.js', _bytes(300)));
      stored[100] ^= 1;
      expect(e.openPublic('assets/x.js', stored), isNull);
    });

    test('a changed checksum is refused', () {
      final stored = Uint8List.fromList(e.sealPublic('assets/x.js', _bytes(300)));
      stored[10] ^= 1;
      expect(e.openPublic('assets/x.js', stored), isNull);
    });

    test('the SAME bytes under ANOTHER name are refused (a file cannot be swapped for another)', () {
      final stored = e.sealPublic('assets/public/js/script.js', _bytes(300));
      expect(e.openPublic('assets/public/css/style.css', stored), isNull);
    });

    test('another device key is refused', () {
      final stored = e.sealPublic('assets/x.js', _bytes(300));
      expect(SnapshotEncryptor(hexKey: 'b' * 64).openPublic('assets/x.js', stored), isNull);
    });

    test('an empty resource and a plain List<int> input work', () {
      final stored = e.sealPublic('assets/empty', const <int>[]);
      expect(e.openPublic('assets/empty', stored.toList()), isEmpty);
    });

    test('too short, or not the format, is simply "not that format"', () {
      expect(e.isPublicFormat(Uint8List(10)), isFalse);
      expect(e.openPublic('assets/x', Uint8List(10)), isNull);
      expect(e.isPublicFormat(e.encryptBytes(_bytes(100))), isFalse, reason: 'a legacy AES-GCM file');
    });

    test('files in the earlier format (all AES-GCM) are still readable', () async {
      final legacy = e.encryptBytes(_bytes(9000));
      expect(await e.decryptBytesInBackground(legacy), _bytes(9000));
    });

    test('MEASURED: what checking a whole dashboard costs (printed; loose bound)', () {
      const sizes = [22327, 20696, 157789]; // style.css, script.js, ikona.png
      final bodies = [for (final n in sizes) _bytes(n)];
      final watch = Stopwatch()..start();
      final stored = [for (var i = 0; i < sizes.length; i++) e.sealPublic('assets/$i', bodies[i])];
      final sealMs = watch.elapsedMilliseconds;
      watch.reset();
      for (var i = 0; i < sizes.length; i++) {
        expect(e.openPublic('assets/$i', stored[i]), bodies[i]);
      }
      final openMs = watch.elapsedMilliseconds;
      // ignore: avoid_print
      print('PUBLIC-ASSET-COST ${sizes.reduce((a, b) => a + b)} B (stylesheet, script, logo): seal=$sealMs ms, verify=$openMs ms '
          '(the same three files cost 842 + 324 + 2387 = 3553 ms to decrypt on the K12)');
      expect(sealMs + openMs, lessThan(20000));
    });
  });

  group('LocalSnapshotServer', () {
    late Directory root;
    late _CountingEncryptor encryptor;
    late LocalSnapshotServer server;
    late HttpClient client;

    File putSealed(String relative, List<int> body) {
      final file = File('${root.path}/$relative')..createSync(recursive: true);
      file.writeAsBytesSync(encryptor.sealPublic(relative, body));
      return file;
    }

    File putLegacy(String relative, List<int> body) {
      final file = File('${root.path}/$relative')..createSync(recursive: true);
      file.writeAsBytesSync(encryptor.encryptBytes(body));
      return file;
    }

    Future<(int, List<int>)> get(String relative) async {
      final response = await (await client.getUrl(server.urlFor('/$relative'))).close();
      final body = await response.fold<List<int>>([], (a, b) => a..addAll(b));
      return (response.statusCode, body);
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mm_public_asset_');
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

    test('a public resource is served after a CHECK, with no decryption at all', () async {
      final body = _bytes(40000);
      putSealed('assets/public/ikona.png', body);
      final lines = <String>[];
      server.trace = lines.add;

      final served = await get('assets/public/ikona.png');
      expect(served.$1, 200);
      expect(served.$2, body);
      expect(encryptor.decrypts, 0, reason: 'a hash, not a cipher');
      expect(lines.single, contains('verified'));
    });

    test('and the second request is served from memory', () async {
      putSealed('assets/x.js', _bytes(500));
      await get('assets/x.js');
      final lines = <String>[];
      server.trace = lines.add;
      await get('assets/x.js');
      expect(lines.single, contains('memory'));
    });

    test('a resource that was ALTERED on disk is refused (500), never served', () async {
      final file = putSealed('assets/public/js/script.js', _bytes(800));
      final bytes = file.readAsBytesSync()..[200] ^= 0xff;
      file.writeAsBytesSync(bytes);
      expect((await get('assets/public/js/script.js')).$1, 500);
      expect(server.hasDecrypted(file), isFalse);
    });

    test('a resource SWAPPED for another under a different name is refused', () async {
      final style = putSealed('assets/public/css/style.css', utf8.encode('body{}'));
      final script = File('${root.path}/assets/public/js/script.js')..createSync(recursive: true);
      script.writeAsBytesSync(style.readAsBytesSync()); // style.css's sealed bytes, named script.js
      expect((await get('assets/public/js/script.js')).$1, 500);
    });

    test('a file that claims the format and carries nothing valid is refused', () async {
      final file = File('${root.path}/assets/x.png')..createSync(recursive: true);
      file.writeAsBytesSync([0x4d, 0x4d, 0x41, 0x31, ...List.filled(60, 3)]);
      expect((await get('assets/x.png')).$1, 500);
    });

    test('a file saved in the EARLIER format is still served (decrypted)', () async {
      final body = _bytes(9000);
      putLegacy('assets/old.png', body);
      final served = await get('assets/old.png');
      expect(served.$1, 200);
      expect(served.$2, body);
      expect(encryptor.decrypts, 1);
    });

    test('the page itself (HTML) is still decrypted, never merely checked', () async {
      putLegacy('snapshot.html', utf8.encode('<html>personal data</html>'));
      expect((await get('snapshot.html')).$1, 200);
      expect(encryptor.decrypts, 1);
    });

    test('WRITE-THROUGH: what was just written is remembered; the first request costs nothing', () async {
      final file = putLegacy('snapshot.html', utf8.encode('<html>v1</html>'));
      await server.remember(file, utf8.encode('<html>v1</html>'));
      expect(server.hasDecrypted(file), isTrue);

      final lines = <String>[];
      server.trace = lines.add;
      expect((await get('snapshot.html')).$1, 200);
      expect(encryptor.decrypts, 0, reason: 'nothing was decrypted: it was remembered');
      expect(lines.single, contains('memory'));
    });

    test('a remembered file that was REPLACED is not served stale', () async {
      final file = putLegacy('snapshot.html', utf8.encode('old'));
      await server.remember(file, utf8.encode('old'));
      file.writeAsBytesSync(encryptor.encryptBytes(utf8.encode('a newer and longer page')));
      expect(utf8.decode((await get('snapshot.html')).$2), 'a newer and longer page');
    });

    test('remembering a file that is gone, or after the cache was emptied, is ignored', () async {
      final file = putLegacy('snapshot.html', utf8.encode('x'));
      final pending = server.remember(file, utf8.encode('x'));
      server.rootDirectory = null; // sign-out while it waited for the file system
      await pending;
      expect(server.hasDecrypted(file), isFalse);

      server.rootDirectory = root;
      file.deleteSync();
      await server.remember(file, utf8.encode('x'));
      expect(server.hasDecrypted(file), isFalse);
    });
  });

  group('SnapshotStore', () {
    late Directory root;
    late _GatedEncryptor encryptor;
    late SnapshotStore store;
    final reported = <String, List<int>>{};

    Future<void> write(String html, {Map<String, List<int>>? assets}) => store.writeSnapshot(
      parishId: 'p',
      userId: 'u',
      pagePath: '/public/dashboard.php',
      html: html,
      assets: assets ?? {'public/css/style.css': utf8.encode('body{color:red}')},
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mm_public_store_');
      encryptor = _GatedEncryptor();
      store = SnapshotStore(encryptor: encryptor, rootOverride: root);
      reported.clear();
      store.onWritten = (file, bytes) => reported[file.path] = bytes;
    });

    tearDown(() async => root.delete(recursive: true));

    Future<Directory> pageDir() async => (await store.getPageDirectoryIfReady(
      parishId: 'p',
      userId: 'u',
      pagePath: '/public/dashboard.php',
    ))!;

    test('the page and the manifest stay ENCRYPTED; a public resource is authenticated', () async {
      await write('<html>Secret parishioner list</html>');
      final dir = await pageDir();

      final html = File(p.join(dir.path, 'snapshot.html')).readAsBytesSync();
      final manifest = File('${dir.path}/manifest.json').readAsBytesSync();
      expect(latin1.decode(html), isNot(contains('Secret parishioner')), reason: 'personal data is encrypted');
      expect(latin1.decode(manifest), isNot(contains('dashboard')), reason: 'the manifest is encrypted');
      expect(encryptor.isPublicFormat(html), isFalse);

      final css = File(p.join(dir.path, 'assets', 'public', 'css', 'style.css')).readAsBytesSync();
      expect(encryptor.isPublicFormat(css), isTrue);
      expect(encryptor.openPublic('assets/public/css/style.css', css), utf8.encode('body{color:red}'));
    });

    test('onWritten reports each file as it now lives, with the plaintext just written', () async {
      await write('<html>v1</html>');
      final dir = await pageDir();
      expect(reported.keys.map(p.normalize), containsAll([p.join(dir.path, 'snapshot.html'), p.join(dir.path, 'assets', 'public', 'css', 'style.css')]));
      expect(utf8.decode(reported[p.join(dir.path, 'snapshot.html')]!), '<html>v1</html>');
    });

    test('and the reported files exist at that moment (the swap is done)', () async {
      var existedWhenReported = true;
      store.onWritten = (file, bytes) => existedWhenReported &= file.existsSync();
      await write('<html>v1</html>');
      expect(existedWhenReported, isTrue);
    });

    test('NOT reported when a sign-out happened while the write was running', () async {
      encryptor.gate = Completer<void>();
      final writing = write('<html>v1</html>');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      unawaited(store.clearForUser(parishId: 'p', userId: 'u')); // logout wins
      encryptor.gate!.complete();
      await writing;
      expect(reported, isEmpty);
    });

    test('a hook that throws never fails a write that succeeded', () async {
      store.onWritten = (file, bytes) => throw StateError('boom');
      await write('<html>v1</html>');
      expect(await pageDir(), isNotNull);
    });
  });
}
