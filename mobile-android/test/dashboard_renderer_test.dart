import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/features/dashboard/dashboard_renderer.dart';

void main() {
  // Spec §17 / decision #13, non-negotiable: an unrecognized component
  // must render a safe fallback and must NEVER crash the whole dashboard.
  testWidgets('an unknown component renders a safe fallback, not a crash', (tester) async {
    final config = {
      'schema_version': 1,
      'dashboard': {
        'layout': 'grid', 'columns': 2,
        'items': [
          {'module_id': 'schedule', 'title': 'Grafik', 'order': 1},
          {'module_id': 'weird_new_thing', 'title': 'Coś nowego', 'order': 2},
        ],
      },
      'modules': [
        {'id': 'schedule', 'component': 'event_list'},
        {'id': 'weird_new_thing', 'component': 'video_player'}, // NOT in the known component list
      ],
    };

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DashboardRenderer(config: config, deviceAppVersion: '1.0.0')),
    ));

    // The known component renders its normal tile.
    expect(find.text('Grafik'), findsOneWidget);

    // The unknown component renders the fallback (its title text still
    // shows, via a "?" icon tile) rather than throwing during pumpWidget
    // (if it threw, tester.takeException() below would be non-null and
    // the widget tree wouldn't have built at all).
    expect(find.text('Coś nowego'), findsOneWidget);
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a dashboard item referencing a module_id absent from modules[] also falls back safely', (tester) async {
    final config = {
      'schema_version': 1,
      'dashboard': {
        'columns': 1,
        'items': [
          {'module_id': 'ghost_module', 'title': 'Duch', 'order': 1},
        ],
      },
      'modules': <Map<String, dynamic>>[], // deliberately empty — "ghost_module" doesn't exist here
    };

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DashboardRenderer(config: config, deviceAppVersion: '1.0.0')),
    ));

    expect(find.text('Duch'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a module requiring a newer app version than the device has shows the update-gated tile, not the real module', (tester) async {
    final config = {
      'schema_version': 1,
      'dashboard': {
        'columns': 1,
        'items': [
          {'module_id': 'triduum', 'title': 'Triduum', 'order': 1},
        ],
      },
      'modules': [
        {'id': 'triduum', 'component': 'event_list', 'min_app_version': '2.4.0'},
      ],
    };

    // Device is on 2.1.0 — verbatim spec §18 example, older than the 2.4.0 requirement.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DashboardRenderer(config: config, deviceAppVersion: '2.1.0')),
    ));

    expect(find.text('Zaktualizuj aplikację, aby korzystać z tej funkcji.'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('an empty dashboard (no enabled items) shows an explanatory message, not a blank/broken screen', (tester) async {
    final config = {
      'schema_version': 1,
      'dashboard': {'columns': 1, 'items': <Map<String, dynamic>>[]},
      'modules': <Map<String, dynamic>>[],
    };

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DashboardRenderer(config: config, deviceAppVersion: '1.0.0')),
    ));

    expect(find.text('Brak skonfigurowanych modułów.'), findsOneWidget);
  });
}
