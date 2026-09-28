import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/features/config/config_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_secure_storage talks to the platform over this MethodChannel;
  // there's no real platform in `flutter test`, so every read/write must
  // be mocked or it throws MissingPluginException. Mocking 'read' to
  // always return null simulates "nothing has ever been stored" — which
  // is exactly what we need to deterministically hit ApiClient.parish()'s
  // "not activated/logged in" path below, with NO real network I/O
  // anywhere in this test file (spec §19's cache-fallback behavior tested
  // in isolation).
  const secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      secureStorageChannel,
      (call) async {
        switch (call.method) {
          case 'read':
            return null;
          case 'readAll':
            return <String, String>{};
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(secureStorageChannel, null);
  });

  test('loadModules falls back to the cached module list when not activated/logged in yet (no server_url/token)', () async {
    final db = AppDatabase.forTesting();
    final secureStorage = SecureStorageService();
    final configService = ConfigService(db: db, api: ApiClient(secureStorage));

    // Pre-seed the cache, simulating "this parish's config was fetched
    // successfully once before" (spec §19: config must survive later
    // unreachability). The cache stores the RESOLVED module list (a JSON
    // array), not the raw server response.
    await db.saveDashboardConfig(1, '[{"id":"schedule","title":"Mój grafik","type":"native","screen":"my_schedule"}]');

    // ApiClient.parish() throws StateError here (no server_url/token in
    // secure storage — the mocked channel above returns null for every
    // read) — ConfigService must catch that and fall back to the cache,
    // never let it propagate and crash the caller.
    final result = await configService.loadModules();

    expect(result, isNotNull);
    expect(result!.single['id'], 'schedule');

    await db.close();
  });

  test('loadModules returns null (not a crash) when there is NEITHER a live fetch NOR any cache yet', () async {
    final db = AppDatabase.forTesting();
    final secureStorage = SecureStorageService();
    final configService = ConfigService(db: db, api: ApiClient(secureStorage));

    // No saveDashboardConfig call this time — genuinely first run, offline.
    final result = await configService.loadModules();

    expect(result, isNull);

    await db.close();
  });
}
