import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/deeplink/deep_link_service.dart';
import 'package:ministrant_manager/core/startup/app_services.dart';
import 'package:ministrant_manager/main.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Startup failure paths of MinistrantManagerApp. Before these existed, any
/// throw in _init() (secure storage, opening the encrypted database,
/// wiring services) was an unhandled async error and the app stayed on its
/// spinner for good. The success path is not exercised here: it needs a
/// real encrypted database and the screens behind PreflightGate.

class _NoDeepLinks extends DeepLinkService {
  @override
  void listen(void Function(String token) onToken) {}
}

const _secureStorage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

Future<void> _pumpStartup(WidgetTester tester) async {
  // Channel replies and async hops need a few turns of the fake clock.
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  var failStorage = false;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // PackageInfo asks the platform. In testWidgets (fake clock) a call to a
    // channel nobody answers never completes, so startup would hang on its
    // very first step; give it its answer.
    PackageInfo.setMockInitialValues(
      appName: 'Ministrant Manager',
      packageName: 'eu.ministrant.manager',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    failStorage = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorage, (call) async {
      if (failStorage) throw PlatformException(code: 'keystore-unavailable');
      return null; // nothing stored: not activated
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorage, null);
  });

  const spinner = CircularProgressIndicator;

  testWidgets('a failing service build shows an error with a retry, not a spinner', (
    tester,
  ) async {
    var builds = 0;
    await tester.pumpWidget(
      MinistrantManagerApp(
        deepLinkService: _NoDeepLinks(),
        buildServices: (_, __) async {
          builds++;
          throw StateError('cannot open database');
        },
      ),
    );
    expect(find.byType(spinner), findsOneWidget, reason: 'starting up');
    await _pumpStartup(tester);

    expect(find.byType(spinner), findsNothing);
    expect(find.text('Nie udało się uruchomić aplikacji.'), findsOneWidget);
    // Only the exception TYPE is shown, never its message.
    expect(find.text('StateError'), findsOneWidget);
    expect(find.textContaining('cannot open database'), findsNothing);
    expect(find.text('SPRÓBUJ PONOWNIE'), findsOneWidget);
    expect(builds, 1);
  });

  testWidgets('an unreadable secure storage is an error too, and never reaches the database', (
    tester,
  ) async {
    failStorage = true;
    var builds = 0;
    await tester.pumpWidget(
      MinistrantManagerApp(
        deepLinkService: _NoDeepLinks(),
        buildServices: (_, __) async {
          builds++;
          throw StateError('unreachable');
        },
      ),
    );
    await _pumpStartup(tester);

    expect(find.byType(spinner), findsNothing);
    expect(find.text('Nie udało się uruchomić aplikacji.'), findsOneWidget);
    expect(find.text('PlatformException'), findsOneWidget);
    expect(builds, 0);
  });

  testWidgets('retry runs the startup again; a transient failure can recover into the next stage', (
    tester,
  ) async {
    failStorage = true;
    var builds = 0;
    await tester.pumpWidget(
      MinistrantManagerApp(
        deepLinkService: _NoDeepLinks(),
        startupTimeout: const Duration(milliseconds: 100),
        // Never completes: lets the test observe that the retry really
        // got past the storage read and into the service build.
        buildServices: (_, __) {
          builds++;
          return Completer<AppServices>().future;
        },
      ),
    );
    await _pumpStartup(tester);
    expect(find.text('PlatformException'), findsOneWidget);
    expect(builds, 0);

    failStorage = false;
    await tester.tap(find.text('SPRÓBUJ PONOWNIE'));
    await _pumpStartup(tester);

    expect(find.text('Nie udało się uruchomić aplikacji.'), findsNothing);
    expect(find.byType(spinner), findsOneWidget);
    expect(builds, 1);

    // Let this attempt's own limit expire so no timer outlives the test.
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('a startup that never finishes ends in a timeout error, and a retry starts a new attempt', (
    tester,
  ) async {
    var builds = 0;
    await tester.pumpWidget(
      MinistrantManagerApp(
        deepLinkService: _NoDeepLinks(),
        startupTimeout: const Duration(milliseconds: 100),
        buildServices: (_, __) {
          builds++;
          return Completer<AppServices>().future;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(spinner), findsOneWidget, reason: 'still within the limit');

    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(spinner), findsNothing);
    expect(find.text('Uruchamianie aplikacji trwa zbyt długo.'), findsOneWidget);
    expect(builds, 1);

    await tester.tap(find.text('SPRÓBUJ PONOWNIE'));
    await _pumpStartup(tester);
    expect(builds, 2);
    expect(find.byType(spinner), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Uruchamianie aplikacji trwa zbyt długo.'), findsOneWidget);
  });
}
