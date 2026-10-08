import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/page_identity.dart';

/// Contract between this app and the MobileAPI deployed next to it.
///
/// The server only issues a handoff ticket for the paths in its module
/// registry, and answers anything else with 400 invalid_path. The app must
/// therefore only ever ask for a ticket for a path that is in that registry.
/// These tests read the registry from the repository copy of the server, so
/// a change on either side that breaks the agreement fails here instead of
/// on a phone. (They check the repository copy; whether the file deployed on
/// a parish server matches it is a deployment question.)
void main() {
  final registryFile = File(
    '../mobileapi-core-deployment/mobileapi-core/ParishAdapters/Witosa/modules_builder.php',
  );
  final homeScreenFile = File('lib/features/home/home_screen.dart');

  late String registrySource;
  late Set<String> registryPaths;

  setUpAll(() {
    expect(
      registryFile.existsSync(),
      isTrue,
      reason: 'run from the app directory (the repo root is its parent)',
    );
    registrySource = registryFile.readAsStringSync();
    registryPaths = RegExp(r"'path' => '(/public/[A-Za-z0-9_./-]+)'")
        .allMatches(registrySource)
        .map((m) => m.group(1)!)
        .toSet();
  });

  test('the registry could be read', () {
    expect(registryPaths.length, greaterThan(20));
  });

  test('the entry page the app hands off through is in the server allowlist', () {
    final match = RegExp(
      r"targetPath: '(/public/[A-Za-z0-9_./-]+)'",
    ).firstMatch(homeScreenFile.readAsStringSync());
    expect(match, isNotNull, reason: 'HomeScreen no longer names its entry page');

    expect(
      registryPaths,
      contains(match!.group(1)),
      reason: 'a ticket for the entry page would be refused with 400 invalid_path',
    );
  });

  test('the entry page is hidden: a handoff target, never a tile', () {
    final entry = RegExp(
      r"'dashboard' => \[[^\]]*\]",
      dotAll: true,
    ).firstMatch(registrySource);
    expect(entry, isNotNull);
    expect(entry!.group(0), contains("'hidden' => true"));
  });

  test('every allowlisted page is one the app can save and reopen offline', () {
    for (final path in registryPaths) {
      expect(
        snapshotPagePath(Uri.parse(path)),
        isNotNull,
        reason: '$path is allowlisted but the app would never save a copy of it',
      );
    }
  });

  test('no login, logout or handoff page is ever allowlisted', () {
    for (final path in registryPaths) {
      final leaf = path.split('/').last.toLowerCase();
      expect(
        const {'login.php', 'logout.php', 'mobile_handoff.php', 'session_login.php'},
        isNot(contains(leaf)),
        reason: path,
      );
    }
  });
}
