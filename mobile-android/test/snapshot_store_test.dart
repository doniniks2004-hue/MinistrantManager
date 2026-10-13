import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_manifest.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';

/// Offline-architecture milestone, P8.2: SnapshotStore now requires a
/// SnapshotEncryptor — every file it writes is encrypted. A fixed,
/// valid 64-character hex test key, built programmatically rather than
/// as a hand-counted literal (P8.1's own lesson: a hand-typed long hex
/// literal is a real, recurring risk of an off-by-a-couple-characters
/// mistake in this sandbox).
final _testEncryptor = SnapshotEncryptor(hexKey: 'a' * 64);

/// This file's tests assert against the exact PLAINTEXT content a real
/// caller would see — reading the raw (now-encrypted) bytes directly
/// and decrypting them here is what proves encryption is actually
/// transparent to a correctly-configured reader, not just "a method got
/// called somewhere".
Future<String> _readDecryptedString(String path) async {
  final encryptedBytes = await File(path).readAsBytes();
  return utf8.decode(_testEncryptor.decryptBytes(encryptedBytes));
}

void main() {
  late Directory tempRoot;
  late SnapshotStore store;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('snapshot_store_test_');
    store = SnapshotStore(encryptor: _testEncryptor, rootOverride: tempRoot);
  });

  tearDown(() async {
    // Review round fix (real bug, caught by CI): the clearAll() test
    // deletes tempRoot itself (it IS the overridden cache root), so by
    // the time tearDown runs for that test the directory is already
    // gone — only ignore THAT specific, expected case, never swallow
    // any other failure here.
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('SnapshotStore', () {
    test(
      'a capture begun before logout cannot recreate the cleared cache',
      () async {
        final generation = store.generation;
        await store.clearForUser(parishId: 'p', userId: 'u');
        await store.writeSnapshot(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/dashboard.php',
          html: 'Old user data',
          assets: {},
          expectedGeneration: generation,
        );
        expect(
          await store.readManifestFor(
            parishId: 'p',
            userId: 'u',
            pagePath: '/public/dashboard.php',
          ),
          isNull,
        );
      },
    );

    test('logout wins over a snapshot commit already in progress', () async {
      final write = store.writeSnapshot(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/dashboard.php',
        html: 'Old user data',
        assets: {},
      );
      final clear = store.clearForUser(parishId: 'p', userId: 'u');
      await Future.wait([write, clear]);
      expect(
        await store.getPageDirectoryIfReady(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/dashboard.php',
        ),
        isNull,
      );
    });

    test(
      'asset traversal is rejected without replacing the previous snapshot',
      () async {
        await store.writeSnapshot(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/dashboard.php',
          html: 'Good',
          assets: {},
        );
        await expectLater(
          store.writeSnapshot(
            parishId: 'p',
            userId: 'u',
            pagePath: '/public/dashboard.php',
            html: 'Bad',
            assets: {
              '../../escape': [1],
            },
          ),
          throwsFormatException,
        );
        final dir = await store.getPageDirectoryIfReady(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/dashboard.php',
        );
        expect(
          await _readDecryptedString('${dir!.path}/snapshot.html'),
          'Good',
        );
      },
    );

    test('a page that was never written reads back as not ready', () async {
      final dir = await store.getPageDirectoryIfReady(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
      );
      expect(dir, isNull);
    });

    test(
      'writes a snapshot and reads it back with the exact manifest fields',
      () async {
        await store.writeSnapshot(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/dashboard.php',
          html: '<html><body>Dashboard</body></html>',
          assets: {'css/style.css': 'body{color:red}'.codeUnits},
          capturedAt: DateTime.utc(2026, 10, 1, 12, 0, 0),
        );

        final dir = await store.getPageDirectoryIfReady(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/dashboard.php',
        );
        expect(dir, isNotNull);
        expect(
          await _readDecryptedString('${dir!.path}/snapshot.html'),
          '<html><body>Dashboard</body></html>',
        );
        expect(
          await _readDecryptedString('${dir.path}/assets/css/style.css'),
          'body{color:red}',
        );

        final manifest = await store.readManifestFor(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/dashboard.php',
        );
        expect(manifest, isNotNull);
        expect(manifest!.parishId, 'witosa');
        expect(manifest.userId, '9001');
        expect(manifest.path, '/public/dashboard.php');
        expect(manifest.capturedAt, DateTime.utc(2026, 10, 1, 12, 0, 0));
        expect(manifest.resources, ['assets/css/style.css']);
      },
    );

    test('review round requirement: a second write REPLACES the first entirely — no leftover files from the old snapshot', () async {
      await store.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html>v1</html>',
        assets: {
          'img/logo.png': [1, 2, 3],
          'css/old-only.css': 'x'.codeUnits,
        },
      );

      await store.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html>v2</html>',
        assets: {'css/style.css': 'y'.codeUnits},
      );

      final dir = await store.getPageDirectoryIfReady(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
      );
      expect(
        await _readDecryptedString('${dir!.path}/snapshot.html'),
        '<html>v2</html>',
      );
      expect(
        await _readDecryptedString('${dir.path}/assets/css/style.css'),
        'y',
      );
      expect(
        await File('${dir.path}/assets/css/old-only.css').exists(),
        isFalse,
        reason: 'a file that existed ONLY in v1 must be gone after v2 — otherwise this is a merge, not a replace',
      );
      expect(await File('${dir.path}/assets/img/logo.png').exists(), isFalse);

      // No orphaned .tmp-*/.trash-* directories left behind alongside
      // the real one after a clean, successful write.
      final parentDir = dir.parent;
      final siblingNames = parentDir
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .toList();
      expect(
        siblingNames.where((n) => n.contains('.tmp-') || n.contains('.trash-')),
        isEmpty,
      );
    });

    test('isolation: clearForUser never touches a different user in the same parish', () async {
      await store.writeSnapshot(
        parishId: 'witosa',
        userId: 'admin-1',
        pagePath: '/public/dashboard.php',
        html: '<html>Admin</html>',
        assets: {},
      );
      await store.writeSnapshot(
        parishId: 'witosa',
        userId: 'ministrant-5',
        pagePath: '/public/dashboard.php',
        html: '<html>Ministrant</html>',
        assets: {},
      );

      await store.clearForUser(parishId: 'witosa', userId: 'admin-1');

      expect(
        await store.getPageDirectoryIfReady(
          parishId: 'witosa',
          userId: 'admin-1',
          pagePath: '/public/dashboard.php',
        ),
        isNull,
      );
      expect(
        await store.getPageDirectoryIfReady(
          parishId: 'witosa',
          userId: 'ministrant-5',
          pagePath: '/public/dashboard.php',
        ),
        isNotNull,
        reason: 'clearing admin-1 must never remove ministrant-5\'s snapshot',
      );
    });

    test(
      'isolation: clearForParish never touches a different parish',
      () async {
        await store.writeSnapshot(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/dashboard.php',
          html: '<html>Witosa</html>',
          assets: {},
        );
        await store.writeSnapshot(
          parishId: 'szarlej',
          userId: '9001',
          pagePath: '/public/dashboard.php',
          html: '<html>Szarlej</html>',
          assets: {},
        );

        await store.clearForParish(parishId: 'witosa');

        expect(
          await store.getPageDirectoryIfReady(
            parishId: 'witosa',
            userId: '9001',
            pagePath: '/public/dashboard.php',
          ),
          isNull,
        );
        expect(
          await store.getPageDirectoryIfReady(
            parishId: 'szarlej',
            userId: '9001',
            pagePath: '/public/dashboard.php',
          ),
          isNotNull,
          reason: 'review round point 13/20: Panewniki (or any other parish) must never lose data when Szarlej\'s cache is cleared',
        );
      },
    );

    test('a manifest.json that fails to parse reads back as not-ready, never throws', () async {
      await store.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html>v1</html>',
        assets: {},
      );
      final dir = await store.getPageDirectoryIfReady(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
      );
      await File('${dir!.path}/manifest.json').writeAsString('{not valid json');

      final manifest = await store.readManifest(dir);
      expect(manifest, isNull);
      final dirAfterCorruption = await store.getPageDirectoryIfReady(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
      );
      expect(
        dirAfterCorruption,
        isNull,
        reason: 'a corrupt manifest must read as "no snapshot", never crash the caller',
      );
    });

    test(
      'different pages for the same user never collide with each other',
      () async {
        await store.writeSnapshot(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/dashboard.php',
          html: '<html>Dashboard</html>',
          assets: {},
        );
        await store.writeSnapshot(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/schedule.php',
          html: '<html>Schedule</html>',
          assets: {},
        );

        final dashboardDir = await store.getPageDirectoryIfReady(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/dashboard.php',
        );
        final scheduleDir = await store.getPageDirectoryIfReady(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/schedule.php',
        );

        expect(
          await _readDecryptedString('${dashboardDir!.path}/snapshot.html'),
          '<html>Dashboard</html>',
        );
        expect(
          await _readDecryptedString('${scheduleDir!.path}/snapshot.html'),
          '<html>Schedule</html>',
        );
        expect(dashboardDir.path, isNot(scheduleDir.path));
      },
    );

    test('clearAll removes every parish', () async {
      await store.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html></html>',
        assets: {},
      );
      await store.writeSnapshot(
        parishId: 'szarlej',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html></html>',
        assets: {},
      );

      await store.clearAll();

      expect(
        await store.getPageDirectoryIfReady(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/dashboard.php',
        ),
        isNull,
      );
      expect(
        await store.getPageDirectoryIfReady(
          parishId: 'szarlej',
          userId: '9001',
          pagePath: '/public/dashboard.php',
        ),
        isNull,
      );
    });
  });

  group('F6: a process killed in the middle of replacing a snapshot', () {
    Future<Directory> saved(String html) async {
      await store.writeSnapshot(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/dashboard.php',
        html: html,
        assets: {},
      );
      return (await store.getPageDirectoryIfReady(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/dashboard.php',
      ))!;
    }

    Future<SnapshotManifest?> manifest() => store.readManifestFor(
      parishId: 'p',
      userId: 'u',
      pagePath: '/public/dashboard.php',
    );

    test('the old copy set aside before the crash comes back, complete', () async {
      final real = await saved('old copy');
      // The state a kill between the two renames leaves: the old directory
      // moved aside, the new one not yet in place (a half-written temp one
      // is lying around too).
      final trash = Directory('${real.path}.trash-abc123');
      await real.rename(trash.path);
      await Directory('${real.path}.tmp-def456').create();
      expect(await real.exists(), isFalse);

      expect(await manifest(), isNotNull, reason: 'the copy is readable again');
      expect(await real.exists(), isTrue);
      expect(await trash.exists(), isFalse);
      expect(
        await Directory('${real.path}.tmp-def456').exists(),
        isFalse,
        reason: 'the half-written leftover is gone',
      );
    });

    test('the page directory is reported ready after recovery, with the same content', () async {
      final real = await saved('old copy');
      await real.rename('${real.path}.trash-1');

      final dir = await store.getPageDirectoryIfReady(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/dashboard.php',
      );
      expect(dir?.path, real.path);
    });

    test('with several set-aside copies the newest one is restored', () async {
      final real = await saved('first');
      final older = Directory('${real.path}.trash-older');
      await real.rename(older.path);
      // "newer" is created and written strictly after "older" last changed.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final newer = Directory('${real.path}.trash-newer');
      await newer.create();
      await File('${newer.path}/marker').writeAsString('newer');

      await store.readManifestFor(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/dashboard.php',
      );
      expect(await File('${real.path}/marker').exists(), isTrue);
      expect(await older.exists(), isFalse);
    });

    test('no set-aside copy: nothing is invented', () async {
      expect(await manifest(), isNull);
      expect(
        await store.getPageDirectoryIfReady(
          parishId: 'p',
          userId: 'u',
          pagePath: '/public/dashboard.php',
        ),
        isNull,
      );
    });

    test('a healthy page is left alone, trash and all', () async {
      final real = await saved('healthy');
      final stray = Directory('${real.path}.trash-stray')..createSync();
      expect(await manifest(), isNotNull);
      expect(await real.exists(), isTrue);
      expect(await stray.exists(), isTrue, reason: 'only a MISSING page triggers recovery');
    });

    test('a reader waits for a write under way instead of seeing its middle', () async {
      await saved('v1');
      final write = store.writeSnapshot(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/dashboard.php',
        html: 'v2',
        assets: {},
      );
      // Asked while the write is in the queue: must answer from a complete copy.
      final read = manifest();
      await write;
      expect(await read, isNotNull);
    });
  });
}
