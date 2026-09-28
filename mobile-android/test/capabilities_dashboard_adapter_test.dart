import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/features/config/capabilities_dashboard_adapter.dart';

void main() {
  group('CapabilitiesDashboardAdapter (hybrid dashboard milestone — produces module-descriptor shape)', () {
    test('only capabilities set to true produce a module, in the SAME shape modules_builder.php uses', () {
      final modules = CapabilitiesDashboardAdapter.toModuleList({
        'capabilities': {
          'schedule': true,
          'attendance': false,
          'points': false,
          'ranking': false,
          'substitutions': false,
          'announcements': false,
        },
      });

      // schedule + the always-present profile tile.
      expect(modules.length, 2);
      expect(modules[0]['id'], 'schedule');
      expect(modules[0]['type'], 'native');
      expect(modules[0]['screen'], 'my_schedule');
      expect(modules[0]['title'], 'Mój grafik');
      expect(modules.last['id'], 'profile');
    });

    test('no capabilities at all still yields the profile tile, not an error', () {
      final modules = CapabilitiesDashboardAdapter.toModuleList({'capabilities': <String, dynamic>{}});
      expect(modules.length, 1);
      expect(modules.single['id'], 'profile');
    });

    test('a missing capabilities key entirely does not throw', () {
      final modules = CapabilitiesDashboardAdapter.toModuleList({});
      expect(modules.length, 1, reason: 'still just the profile tile');
    });

    test('tile order matches the fixed known-modules order, not map iteration order', () {
      final modules = CapabilitiesDashboardAdapter.toModuleList({
        'capabilities': {
          'announcements': true,
          'schedule': true,
          'points': true,
        },
      });
      final order = modules.map((m) => m['id']).toList();
      expect(order, ['schedule', 'points', 'announcements', 'profile'], reason: 'fixed order: schedule, attendance, points, ranking, substitutions, announcements, then profile last');
    });
  });
}
