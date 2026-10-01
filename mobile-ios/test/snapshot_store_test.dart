import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';

void main() {
  late Directory tempRoot;
  late SnapshotStore store;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('snapshot_store_test_');
    store = SnapshotStore(rootOverride: tempRoot);
  });

  tearDown(() async {
    await tempRoot.delete(recursive: true);
  });

  group('SnapshotStore', () {
    test('a page that was never written reads back as not ready', () async {
      final dir = await store.getPageDirectoryIfReady(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
      );
      expect(dir, isNull);
    });

    test('writes a snapshot and reads it back with the exact manifest fields', () async {
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
      expect(await File('${dir!.path}/snapshot.html').readAsString(), '<html><body>Dashboard</body></html>');
      expect(await File('${dir.path}/assets/css/style.css').readAsString(), 'body{color:red}');

      final manifest = await store.readManifestFor(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php');
      expect(manifest, isNotNull);
      expect(manifest!.parishId, 'witosa');
      expect(manifest.userId, '9001');
      expect(manifest.path, '/public/dashboard.php');
      expect(manifest.capturedAt, DateTime.utc(2026, 10, 1, 12, 0, 0));
      expect(manifest.resources, ['assets/css/style.css']);
    });

    test(
      'review round requirement: a second write REPLACES the first entirely — no leftover files from the old snapshot',
      () async {
        await store.writeSnapshot(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/dashboard.php',
          html: '<html>v1</html>',
          assets: {'img/logo.png': [1, 2, 3], 'css/old-only.css': 'x'.codeUnits},
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
        expect(await File('${dir!.path}/snapshot.html').readAsString(), '<html>v2</html>');
        expect(await File('${dir.path}/assets/css/style.css').readAsString(), 'y');
        expect(
          await File('${dir.path}/assets/css/old-only.css').exists(),
          isFalse,
          reason: 'a file that existed ONLY in v1 must be gone after v2 — otherwise this is a merge, not a replace',
        );
        expect(await File('${dir.path}/assets/img/logo.png').exists(), isFalse);

        // No orphaned .tmp-*/.trash-* directories left behind alongside
        // the real one after a clean, successful write.
        final parentDir = dir.parent;
        final siblingNames = parentDir.listSync().map((e) => _basename(e.path)).toList();
        expect(siblingNames.where((n) => n.contains('.tmp-') || n.contains('.trash-')), isEmpty);
      },
    );

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
        await store.getPageDirectoryIfReady(parishId: 'witosa', userId: 'admin-1', pagePath: '/public/dashboard.php'),
        isNull,
      );
      expect(
        await store.getPageDirectoryIfReady(parishId: 'witosa', userId: 'ministrant-5', pagePath: '/public/dashboard.php'),
        isNotNull,
        reason: 'clearing admin-1 must never remove ministrant-5\'s snapshot',
      );
    });

    test('isolation: clearForParish never touches a different parish', () async {
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
        await store.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php'),
        isNull,
      );
      expect(
        await store.getPageDirectoryIfReady(parishId: 'szarlej', userId: '9001', pagePath: '/public/dashboard.php'),
        isNotNull,
        reason: 'review round point 13/20: Panewniki (or any other parish) must never lose data when Szarlej\'s cache is cleared',
      );
    });

    test('a manifest.json that fails to parse reads back as not-ready, never throws', () async {
      await store.writeSnapshot(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
        html: '<html>v1</html>',
        assets: {},
      );
      final dir = await store.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php');
      await File('${dir!.path}/manifest.json').writeAsString('{not valid json');

      final manifest = await store.readManifest(dir);
      expect(manifest, isNull);
      final dirAfterCorruption = await store.getPageDirectoryIfReady(
        parishId: 'witosa',
        userId: '9001',
        pagePath: '/public/dashboard.php',
      );
      expect(dirAfterCorruption, isNull, reason: 'a corrupt manifest must read as "no snapshot", never crash the caller');
    });

    test('different pages for the same user never collide with each other', () async {
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

      final dashboardDir =
          await store.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php');
      final scheduleDir =
          await store.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/schedule.php');

      expect(await File('${dashboardDir!.path}/snapshot.html').readAsString(), '<html>Dashboard</html>');
      expect(await File('${scheduleDir!.path}/snapshot.html').readAsString(), '<html>Schedule</html>');
      expect(dashboardDir.path, isNot(scheduleDir.path));
    });

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
        await store.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php'),
        isNull,
      );
      expect(
        await store.getPageDirectoryIfReady(parishId: 'szarlej', userId: '9001', pagePath: '/public/dashboard.php'),
        isNull,
      );
    });
  });
}

String _basename(String path) => path.split(Platform.pathSeparator).last;
