import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/features/auth/login_screen.dart';
import 'package:ministrant_manager/features/auth/user_session_service.dart';

class _FailingSession extends UserSessionService {
  _FailingSession({required super.api, required super.secureStorage,
    required super.db, required super.snapshotStore, required this.passwordChange});
  final bool passwordChange;
  @override
  Future<UserLoginResult> login({required String username, required String password}) async {
    if (passwordChange) return const UserLoginPasswordChangeRequired();
    throw StateError('local failure');
  }
  @override
  Future<UserLoginResult> changeRequiredPassword({required String username,
    required String currentPassword, required String newPassword}) async =>
      throw StateError('local failure');
}

void main() {
  for (final change in [false, true]) {
    testWidgets('unexpected exception unlocks login controls (change=$change)', (tester) async {
      final directory = Directory.systemTemp.createTempSync('login_failure_');
      final storage = SecureStorageService();
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      addTearDown(() => directory.deleteSync(recursive: true));
      final service = _FailingSession(api: ApiClient(storage), secureStorage: storage,
        db: db, snapshotStore: SnapshotStore(rootOverride: directory,
          encryptor: SnapshotEncryptor(hexKey: 'e' * 64)), passwordChange: change);
      var loggedIn = false;
      await tester.pumpWidget(MaterialApp(home: LoginScreen(userSessionService: service,
        onLoggedIn: () => loggedIn = true)));
      await tester.enterText(find.byType(TextField).at(0), 'test');
      await tester.enterText(find.byType(TextField).at(1), 'password');
      await tester.tap(find.text('ZALOGUJ'));
      await tester.pumpAndSettle();
      if (change) {
        await tester.enterText(find.byType(TextField).at(0), 'new-password');
        await tester.enterText(find.byType(TextField).at(1), 'new-password');
        await tester.tap(find.text('ZAPISZ NOWE HASŁO'));
        await tester.pumpAndSettle();
      }
      expect(loggedIn, isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
      expect(find.text('Nie udało się zapisać sesji na urządzeniu. Spróbuj ponownie.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
