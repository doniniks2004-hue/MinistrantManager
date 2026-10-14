import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';
import 'package:ministrant_manager/core/offline/snapshot_manifest.dart';

/// A write that can be held half-way, like the one that follows every page
/// load (the page is captured and encrypted).
class _GatedEncryptor extends SnapshotEncryptor {
  _GatedEncryptor() : super(hexKey: '1' * 64);

  Completer<void>? gate;

  @override
  Future<List<int>> encryptBytesInBackground(List<int> plaintext) async {
    final held = gate;
    if (held != null) await held.future;
    return encryptBytes(plaintext);
  }
}

/// The first switch to the saved copy happens right after a page load, and a
/// page load starts a write. Reading the copy that is ALREADY on disk must not
/// wait for the write of its successor.
void main() {
  late Directory root;
  late _GatedEncryptor encryptor;
  late SnapshotStore store;

  Future<void> write(String html) => store.writeSnapshot(
    parishId: 'p',
    userId: 'u',
    pagePath: '/public/dashboard.php',
    html: html,
    assets: {'public/css/style.css': List<int>.filled(100, 1)},
  );

  Future<SnapshotManifest?> read() => store.readManifestFor(
    parishId: 'p',
    userId: 'u',
    pagePath: '/public/dashboard.php',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mm_read_during_write_');
    encryptor = _GatedEncryptor();
    store = SnapshotStore(encryptor: encryptor, rootOverride: root);
  });

  tearDown(() async => root.delete(recursive: true));

  test('REGRESSION: the existing copy is read while the next one is still being written', () async {
    await write('v1');

    encryptor.gate = Completer<void>(); // the next write is held half-way
    final writing = write('v2');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final manifest = await read().timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('the read waited for the write in progress'),
    );
    expect(manifest, isNotNull, reason: 'v1 is complete on disk and readable');

    encryptor.gate!.complete();
    await writing;
    expect(await read(), isNotNull);
  });

  test('with NO copy yet the read does wait for the write that is creating it', () async {
    encryptor.gate = Completer<void>();
    final writing = write('v1');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    var answered = false;
    final reading = read().then((m) {
      answered = true;
      return m;
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(answered, isFalse, reason: 'there was nothing to read yet, so it waits');

    encryptor.gate!.complete();
    await writing;
    expect(await reading, isNotNull, reason: 'and then reads what was just written');
  });

  test('the directory of the page is reported ready without waiting, too', () async {
    await write('v1');
    encryptor.gate = Completer<void>();
    final writing = write('v2');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final dir = await store
        .getPageDirectoryIfReady(parishId: 'p', userId: 'u', pagePath: '/public/dashboard.php')
        .timeout(const Duration(seconds: 2), onTimeout: () => fail('waited for the write'));
    expect(dir, isNotNull);

    encryptor.gate!.complete();
    await writing;
  });
}
