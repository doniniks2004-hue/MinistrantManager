import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/util/store_link_launcher.dart';
import 'package:ministrant_manager/features/config/config_service.dart';
import 'package:ministrant_manager/features/preflight/preflight_gate.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      secureStorageChannel,
      (call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  ConfigService offlineConfigService(AppDatabase db) {
    final api = ApiClient(SecureStorageService());
    api.central.interceptors
        .add(InterceptorsWrapper(onRequest: (request, handler) {
      handler.reject(DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
        error: 'Simulated offline network',
      ));
    }));
    return ConfigService(db: db, api: api);
  }

  Future<ConfigService> configServiceWithCached(
      Map<String, dynamic> cachedConfig) async {
    final db = AppDatabase.forTesting();
    addTearDown(db.close);
    await db.saveClientConfig(jsonEncode(cachedConfig));
    return offlineConfigService(db);
  }

  // Review round 2, point 5: PreflightGate must sit in front of BOTH
  // ActivationScreen and HomeScreen — these tests exercise it directly
  // with a child marker widget, independent of which screen it wraps.
  testWidgets(
      'maintenance_mode blocks the child entirely, even before activation',
      (tester) async {
    final configService = await configServiceWithCached({
      'maintenance_mode': true,
      'maintenance_message': 'Przerwa techniczna',
    });

    await tester.pumpWidget(MaterialApp(
      home: PreflightGate(
        configService: configService,
        appVersion: '1.0.0',
        child: const Text('SHOULD_NOT_APPEAR'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Przerwa techniczna'), findsOneWidget);
    expect(find.text('SHOULD_NOT_APPEAR'), findsNothing);
  });

  testWidgets(
      'a global forced update blocks the child when the app version is below the platform minimum',
      (tester) async {
    final configService = await configServiceWithCached({
      'maintenance_mode': false,
      'minimum_supported_android_version': '2.0.0',
      'minimum_supported_ios_version': '2.0.0',
      'android_store_url': '',
      'ios_store_url': '',
    });

    await tester.pumpWidget(MaterialApp(
      home: PreflightGate(
        configService: configService,
        appVersion: '1.0.0', // below the 2.0.0 minimum
        child: const Text('SHOULD_NOT_APPEAR'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Dostępna jest wymagana aktualizacja Ministrant Manager.'),
        findsOneWidget);
    expect(find.text('SHOULD_NOT_APPEAR'), findsNothing);
  });

  testWidgets(
      'a satisfied version + no maintenance mode lets the child through',
      (tester) async {
    final configService = await configServiceWithCached({
      'maintenance_mode': false,
      'minimum_supported_android_version': '1.0.0',
      'minimum_supported_ios_version': '1.0.0',
    });

    await tester.pumpWidget(MaterialApp(
      home: PreflightGate(
        configService: configService,
        appVersion: '1.5.0',
        child: const Text('ACTIVATION_OR_HOME'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('ACTIVATION_OR_HOME'), findsOneWidget);
  });

  testWidgets(
      'no cache and no network (first launch, offline) does NOT block — the explicit instruction',
      (tester) async {
    // No cached config, and a deterministic transport failure before
    // any real network request is sent.
    final db = AppDatabase.forTesting();
    addTearDown(db.close);
    final configService = offlineConfigService(db);

    await tester.pumpWidget(MaterialApp(
      home: PreflightGate(
        configService: configService,
        appVersion: '1.0.0',
        child: const Text('FIRST_ACTIVATION_ALLOWED'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('FIRST_ACTIVATION_ALLOWED'), findsOneWidget);
  });

  testWidgets(
      'tapping AKTUALIZUJ on the forced-update screen launches the correct store URL',
      (tester) async {
    // Review round point 6: this button used to be a hollow placeholder
    // (`onPressed: () {/* url_launcher ... */}`) — this test fails against
    // that old code (nothing captured) and passes against the real fix.
    Uri? capturedUri;
    StoreLinkLauncher.launchUrlOverride =
        (uri, {mode = LaunchMode.platformDefault}) async {
      capturedUri = uri;
      return true;
    };
    addTearDown(() => StoreLinkLauncher.launchUrlOverride = null);

    final configService = await configServiceWithCached({
      'maintenance_mode': false,
      'minimum_supported_android_version': '2.0.0',
      'minimum_supported_ios_version': '2.0.0',
      'android_store_url':
          'https://play.google.com/store/apps/details?id=eu.ministrant.manager',
      'ios_store_url': 'https://apps.apple.com/app/id0000000000',
    });

    await tester.pumpWidget(MaterialApp(
      home: PreflightGate(
        configService: configService,
        appVersion:
            '1.0.0', // below the 2.0.0 minimum — forces the update screen
        child: const Text('SHOULD_NOT_APPEAR'),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('AKTUALIZUJ'));
    await tester.pumpAndSettle();

    expect(capturedUri, isNotNull);
    expect(capturedUri.toString(), contains('play.google.com'));
  });
}
