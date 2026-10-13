import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The server issues a handoff ticket only for the pages in its module
/// registry and answers every other path with 400 invalid_path, while the
/// panel links to real pages that are not in it. Opening such a page,
/// refreshing it, or returning to it must therefore never ask for a ticket
/// FOR IT: a ticket is only ever requested for the registered entry page, and
/// the page itself is opened afterwards with the session that ticket creates.
///
/// This pins where tickets may be requested, so a new caller cannot
/// reintroduce the 400 without a test failing and someone deciding.
void main() {
  final libDir = Directory('lib');

  List<File> dartFiles() => libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  String norm(String path) => path.replaceAll('\\', '/');

  test('only the coordinator (and the unused legacy screen) call the handoff service', () {
    final callers = dartFiles()
        .where((f) => f.readAsStringSync().contains('.requestHandoffUrl('))
        .map((f) => norm(f.path))
        .toSet();

    expect(callers, {
      'lib/core/offline/offline_page_coordinator.dart',
      'lib/features/webview/legacy_module_screen.dart',
    });
  });

  test('the legacy screen, which asks for a ticket for its own path, is not used anywhere', () {
    for (final file in dartFiles()) {
      final path = norm(file.path);
      if (path == 'lib/features/webview/legacy_module_screen.dart') continue;
      final code = file.readAsStringSync()
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code, isNot(contains('LegacyModuleScreen(')), reason: path);
    }
  });

  test('the page screen requests tickets for its entry page only', () {
    final screen = File('lib/features/webview/offline_aware_page_screen.dart')
        .readAsStringSync();

    // Opening / refreshing / retrying / signing in again / returning:
    expect(screen, contains('handoffPath: widget.targetPath,'));
    // The background check for the connection coming back:
    expect(
      RegExp(r'probeOnline\([^)]*targetPath:\s*widget\.targetPath', dotAll: true)
          .hasMatch(screen),
      isTrue,
      reason: 'the reconnect check must ask for the entry page',
    );
    // ...and nothing in the screen asks for a ticket in any other way.
    expect(screen, isNot(contains('requestHandoffUrl(')));
  });

  test('the coordinator asks for the page it was told to hand off through, never its target', () {
    final coordinator = File('lib/core/offline/offline_page_coordinator.dart')
        .readAsStringSync();
    expect(coordinator, contains('.requestHandoffUrl(entryPath)'));
    // _probe receives the entry page from the screen; it must not widen it.
    expect(coordinator, contains('.requestHandoffUrl(path, timeout: timeout)'));
  });
}
