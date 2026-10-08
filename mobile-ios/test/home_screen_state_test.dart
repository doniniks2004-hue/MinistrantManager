import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/offline/connectivity_probe.dart';
import 'package:ministrant_manager/core/offline/local_snapshot_server.dart';
import 'package:ministrant_manager/core/offline/offline_page_coordinator.dart';
import 'package:ministrant_manager/core/offline/page_resource_downloader.dart';
import 'package:ministrant_manager/core/offline/snapshot_capture_service.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/sync/offline_lease.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart';
import 'package:ministrant_manager/features/auth/user_session_service.dart';
import 'package:ministrant_manager/features/config/config_service.dart';
import 'package:ministrant_manager/features/home/home_screen.dart';
import 'package:ministrant_manager/features/revocation/revocation_handler.dart';
import 'package:ministrant_manager/features/webview/webview_handoff_service.dart';

/// HomeScreen states that used to be an indefinite spinner: the first local
/// read failing, and a signed-in user whose parish / server address is
/// missing or unusable. The page-showing path is not exercised here (it
/// needs a web view); only that these states now say what is wrong and
/// offer a way out.

class _AlwaysWithinLease extends OfflineLease {
  const _AlwaysWithinLease();
  @override
  bool isWithinLease(DateTime? lastAuthorizationCheck, {int? leaseHours, DateTime? now}) => true;
}

class _OfflineSyncEngine extends SyncEngine {
  _OfflineSyncEngine({
    required super.db,
    required super.api,
    required super.secureStorage,
    super.offlineLease,
  });

  @override
  Future<DeviceStatusResult?> checkDeviceStatus({
    required String appVersion,
    required String osVersion,
  }) async => null;
}

class _NoConfig extends ConfigService {
  _NoConfig({required super.db, required super.api});

  @override
  Future<Map<String, dynamic>?> loadClientConfig() async => null;
}

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
final _encryptor = SnapshotEncryptor(hexKey: 'b' * 64);

Widget _home(AppDatabase db) {
  final secure = SecureStorageService();
  final api = ApiClient(secure);
  final snapshotStore = SnapshotStore(encryptor: _encryptor);
  return MaterialApp(
    home: HomeScreen(
      db: db,
      syncEngine: _OfflineSyncEngine(
        db: db,
        api: api,
        secureStorage: secure,
        offlineLease: const _AlwaysWithinLease(),
      ),
      configService: _NoConfig(db: db, api: api),
      revocationHandler: RevocationHandler(
        db: db,
        secureStorage: secure,
        snapshotStore: snapshotStore,
      ),
      userSessionService: UserSessionService(
        api: api,
        secureStorage: secure,
        db: db,
        snapshotStore: snapshotStore,
      ),
      offlinePageCoordinator: OfflinePageCoordinator(
        connectivityProbe: ConnectivityProbe(),
        captureService: SnapshotCaptureService(
          downloader: PageResourceDownloader(),
          store: snapshotStore,
        ),
        snapshotStore: snapshotStore,
        localServer: LocalSnapshotServer(encryptor: _encryptor),
        handoffService: WebviewHandoffService(api: api, secureStorage: secure),
      ),
      onRevoked: () {},
      appVersion: '1.0.0',
      osVersion: 'test',
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  late AppDatabase sharedDb;
  final store = <String, String>{};
  var failReads = false;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sharedDb = AppDatabase.forTesting();
  });

  tearDownAll(() async {
    await sharedDb.close();
  });

  setUp(() {
    store.clear();
    failReads = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = call.arguments as Map?;
      final key = args?['key'] as String?;
      switch (call.method) {
        case 'read':
          if (failReads) throw PlatformException(code: 'keystore-unavailable');
          return key == null ? null : store[key];
        case 'write':
          final value = args?['value'] as String?;
          if (key != null && value != null) store[key] = value;
          return null;
        case 'delete':
          if (key != null) store.remove(key);
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  const spinner = CircularProgressIndicator;
  const missingData = 'Brakuje danych potrzebnych do otwarcia strony';

  testWidgets('a signed-in user with no parish or server address gets an error with a way out, not a spinner', (
    tester,
  ) async {
    store['mobile_user_token'] = 'token';
    store['current_user_id'] = '7';
    // parish_id and server_url are missing.

    await tester.pumpWidget(_home(sharedDb));
    await _settle(tester);

    expect(find.byType(spinner), findsNothing);
    expect(find.textContaining(missingData), findsOneWidget);
    expect(find.text('SPRÓBUJ PONOWNIE'), findsOneWidget);
    expect(find.text('WYLOGUJ'), findsOneWidget);
    // The device-settings entry (change parish) stays reachable.
    expect(find.byTooltip('Urządzenie / Parafia'), findsOneWidget);
  });

  testWidgets('a server address with no usable host is the same error (a malformed one used to throw inside build)', (
    tester,
  ) async {
    store['mobile_user_token'] = 'token';
    store['current_user_id'] = '7';
    store['parish_id'] = 'szarlej';

    // 'https://[invalid' makes Uri.parse throw FormatException, which the
    // old Uri.parse(_serverUrl!).host did inside build(); 'https://' parses
    // but has no host, which used to produce an unusable allowedHost.
    for (final url in ['https://[invalid', 'https://']) {
      store['server_url'] = url;
      await tester.pumpWidget(_home(sharedDb));
      await _settle(tester);

      expect(tester.takeException(), isNull, reason: url);
      expect(find.byType(spinner), findsNothing, reason: url);
      expect(find.textContaining(missingData), findsOneWidget, reason: url);

      await tester.pumpWidget(const SizedBox()); // dispose before the next case
    }
  });

  testWidgets('an unreadable first local read ends in an error with a retry, and the retry re-reads', (
    tester,
  ) async {
    failReads = true;
    store['mobile_user_token'] = 'token';
    store['current_user_id'] = '7';

    await tester.pumpWidget(_home(sharedDb));
    await _settle(tester);

    expect(find.byType(spinner), findsNothing);
    expect(
      find.textContaining('Nie udało się odczytać danych aplikacji'),
      findsOneWidget,
    );

    failReads = false; // the storage recovers
    await tester.tap(find.text('SPRÓBUJ PONOWNIE'));
    await _settle(tester);

    // The retry really re-read local state: the first-read error is gone,
    // and what it found (a user with no parish) is reported on its own.
    expect(find.textContaining('Nie udało się odczytać danych aplikacji'), findsNothing);
    expect(find.textContaining(missingData), findsOneWidget);
    expect(find.byType(spinner), findsNothing);
  });
}
