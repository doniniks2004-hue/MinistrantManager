import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/features/config/capabilities_dashboard_adapter.dart';

void main() {
  group('CapabilitiesDashboardAdapter (review round, point 9)', () {
    test('only capabilities set to true produce a dashboard tile', () {
      final result = CapabilitiesDashboardAdapter.toDashboardConfig({
        'capabilities': {
          'events': true,
          'schedule': true,
          'attendance': false,
          'points': false,
          'ranking': false,
          'substitutions': false,
          'announcements': false,
        },
      });

      final items = (result['dashboard'] as Map)['items'] as List;
      final modules = result['modules'] as List;

      expect(items.length, 1, reason: 'only "schedule" is true — events has no tile of its own, everything else is false');
      expect((items[0] as Map)['module_id'], 'schedule');
      expect((items[0] as Map)['title'], 'Mój grafik');
      expect(modules.length, 1);
      expect((modules[0] as Map)['id'], 'schedule');
      expect((modules[0] as Map)['component'], 'event_list');
    });

    test('no capabilities at all produces an empty dashboard, not an error', () {
      final result = CapabilitiesDashboardAdapter.toDashboardConfig({'capabilities': <String, dynamic>{}});
      final items = (result['dashboard'] as Map)['items'] as List;
      expect(items, isEmpty);
    });

    test('a missing capabilities key entirely does not throw', () {
      final result = CapabilitiesDashboardAdapter.toDashboardConfig({});
      final items = (result['dashboard'] as Map)['items'] as List;
      expect(items, isEmpty);
    });

    test('tile order matches the fixed known-modules order, not map iteration order', () {
      final result = CapabilitiesDashboardAdapter.toDashboardConfig({
        'capabilities': {
          'announcements': true,
          'schedule': true,
          'points': true,
        },
      });
      final items = (result['dashboard'] as Map)['items'] as List<dynamic>;
      final order = items.map((i) => (i as Map)['module_id']).toList();
      expect(order, ['schedule', 'points', 'announcements'], reason: 'fixed order: schedule, attendance, points, ranking, substitutions, announcements');
    });
  });
}
