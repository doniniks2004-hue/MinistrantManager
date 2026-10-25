import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a bootstrap response arriving after logout cannot repopulate SQLite',
    () async {
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final values = <String, String>{
        'server_url': 'https://szarlej.ministrant.eu',
        'installation_id': 'test-installation',
        'mobile_user_token': 'test-token',
        'current_user_id': '1',
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map;
            final key = args['key'] as String;
            if (call.method == 'read') return values[key];
            if (call.method == 'delete') values.remove(key);
            return null;
          });
      final storage = SecureStorageService();
      final api = ApiClient(storage);
      final db = AppDatabase.forTesting();
      final requested = Completer<void>();
      final release = Completer<void>();
      final dio = await api.parish();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            requested.complete();
            await release.future;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'events': [],
                  'schedule': [],
                  'generated_at': '2026-10-06T00:00:00Z',
                },
              ),
            );
          },
        ),
      );
      try {
        final engine = SyncEngine(db: db, api: api, secureStorage: storage);
        final fetch = engine.fetchAndApplySnapshot();
        await requested.future;
        await storage.clearUserSession();
        final rejected = expectLater(fetch, throwsStateError);
        release.complete();
        await rejected;
        expect((await db.select(db.events).get()), isEmpty);
        expect((await db.ensureSyncMetadata()).lastSyncAt, isNull);
      } finally {
        await db.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
}
