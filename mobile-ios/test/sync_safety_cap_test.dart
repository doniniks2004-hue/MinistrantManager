import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart';

/// Builds a bare Dio with an interceptor that resolves every
/// `/mobile/sync` request without touching real network I/O — each call
/// returns whatever the next entry in [responses] says, in order. This is
/// what lets `SyncEngine._drainSyncPages()` (exposed for testing via
/// `drainSyncPagesForTesting`) be exercised deterministically for both
/// "genuinely reaches the end" and "hits the safety cap while more pages
/// remain" without a real parish server.
Dio _fakeDio(List<Map<String, dynamic>> responses) {
  final dio = Dio();
  var callIndex = 0;
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    final data = responses[callIndex.clamp(0, responses.length - 1)];
    callIndex++;
    handler.resolve(Response(requestOptions: options, data: data, statusCode: 200));
  }));
  return dio;
}

void main() {
  test('a fully-drained sync (has_more becomes false before the cap) marks lastSyncAt and reports completed', () async {
    final db = AppDatabase.forTesting();
    final engine = SyncEngine(
      db: db,
      api: ApiClient(SecureStorageService()),
      secureStorage: SecureStorageService(),
      maxPagesPerRun: 10, // small cap, irrelevant here since we finish before it
    );

    final dio = _fakeDio([
      {'cursor': 'c1', 'changes': <String, dynamic>{}, 'deleted': <String, dynamic>{}, 'has_more': true},
      {'cursor': 'c2', 'changes': <String, dynamic>{}, 'deleted': <String, dynamic>{}, 'has_more': false},
    ]);

    final completed = await engine.drainSyncPagesForTesting(dio);

    expect(completed, isTrue);
    final meta = await db.ensureSyncMetadata();
    expect(meta.lastSyncAt, isNotNull, reason: 'a genuinely complete sync must mark lastSyncAt');
    expect(meta.cursor, 'c2');
  });

  test(
    'final micro-round point 2: hitting the safety cap while has_more is still true does NOT mark lastSyncAt, and reports incomplete',
    () async {
      final db = AppDatabase.forTesting();
      const cap = 3;
      final engine = SyncEngine(
        db: db,
        api: ApiClient(SecureStorageService()),
        secureStorage: SecureStorageService(),
        maxPagesPerRun: cap,
      );

      // A "misbehaving" (or just very large) change log that ALWAYS says
      // has_more: true — the exact scenario from the review report.
      final dio = _fakeDio(List.generate(
        cap + 5,
        (i) => {'cursor': 'c${i + 1}', 'changes': <String, dynamic>{}, 'deleted': <String, dynamic>{}, 'has_more': true},
      ));

      final completed = await engine.drainSyncPagesForTesting(dio);

      expect(completed, isFalse, reason: 'the cap was hit while pages genuinely remained — this must NOT be reported as success');
      final meta = await db.ensureSyncMetadata();
      expect(meta.lastSyncAt, isNull, reason: 'lastSyncAt must stay unset — a premature "done" here is exactly the bug being fixed');
      expect(meta.cursor, 'c$cap', reason: 'the cursor still advances to wherever the cap stopped, so the NEXT sync continues from there');
    },
  );
}
