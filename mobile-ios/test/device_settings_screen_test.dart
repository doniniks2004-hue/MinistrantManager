import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/features/device_settings/device_settings_screen.dart';
import 'package:ministrant_manager/features/revocation/revocation_handler.dart';

/// Offline-architecture milestone, P9. Unlike the WebView screens
/// elsewhere in this project, DeviceSettingsScreen is plain Material —
/// genuinely testable via flutter_test's widget-testing support, no
/// platform channel needed.
class _FakeRevocationHandler extends RevocationHandler {
  _FakeRevocationHandler()
      : callCount = 0,
        super(
          db: AppDatabase.forTesting(),
          secureStorage: SecureStorageService(),
          snapshotStore: SnapshotStore(encryptor: SnapshotEncryptor(hexKey: '1' * 64)),
        );

  int callCount;
  bool shouldThrow = false;

  @override
  Future<void> resetParishManually() async {
    callCount++;
    if (shouldThrow) throw Exception('simulated failure');
  }
}

void main() {
  testWidgets('tapping "Zmień parafię" shows the exact required confirmation text', (tester) async {
    final handler = _FakeRevocationHandler();
    await tester.pumpWidget(MaterialApp(
      home: DeviceSettingsScreen(revocationHandler: handler, parishSlug: 'witosa', onParishReset: () {}),
    ));

    await tester.tap(find.text('Zmień parafię'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Zmiana parafii usunie lokalne dane i zapisane dane offline obecnej parafii. '
        'Tej operacji nie można cofnąć.',
      ),
      findsOneWidget,
    );
    expect(handler.callCount, 0, reason: 'showing the dialog must never itself trigger the reset');
  });

  testWidgets('tapping ANULUJ never calls resetParishManually or onParishReset', (tester) async {
    final handler = _FakeRevocationHandler();
    var resetCalled = false;
    await tester.pumpWidget(MaterialApp(
      home: DeviceSettingsScreen(revocationHandler: handler, parishSlug: 'witosa', onParishReset: () => resetCalled = true),
    ));

    await tester.tap(find.text('Zmień parafię'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ANULUJ'));
    await tester.pumpAndSettle();

    expect(handler.callCount, 0);
    expect(resetCalled, isFalse);
  });

  testWidgets('confirming calls resetParishManually, then onParishReset once it succeeds', (tester) async {
    final handler = _FakeRevocationHandler();
    var resetCalled = false;
    await tester.pumpWidget(MaterialApp(
      home: DeviceSettingsScreen(revocationHandler: handler, parishSlug: 'witosa', onParishReset: () => resetCalled = true),
    ));

    await tester.tap(find.text('Zmień parafię'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ZMIEŃ PARAFIĘ'));
    await tester.pumpAndSettle();

    expect(handler.callCount, 1);
    expect(resetCalled, isTrue);
  });

  testWidgets('if resetParishManually throws, onParishReset is never called and the user sees an error', (tester) async {
    final handler = _FakeRevocationHandler()..shouldThrow = true;
    var resetCalled = false;
    await tester.pumpWidget(MaterialApp(
      home: DeviceSettingsScreen(revocationHandler: handler, parishSlug: 'witosa', onParishReset: () => resetCalled = true),
    ));

    await tester.tap(find.text('Zmień parafię'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ZMIEŃ PARAFIĘ'));
    await tester.pumpAndSettle();

    expect(handler.callCount, 1);
    expect(resetCalled, isFalse, reason: 'a failed reset must never pretend to have succeeded by still rebuilding app state');
    expect(find.text('Nie udało się zmienić parafii. Spróbuj ponownie.'), findsOneWidget);
  });

  testWidgets('shows the current parish slug', (tester) async {
    final handler = _FakeRevocationHandler();
    await tester.pumpWidget(MaterialApp(
      home: DeviceSettingsScreen(revocationHandler: handler, parishSlug: 'szarlej', onParishReset: () {}),
    ));

    expect(find.text('szarlej'), findsOneWidget);
  });
}
