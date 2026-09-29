import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/features/dashboard/module_descriptor.dart';

void main() {
  group('ModuleDescriptor.fromJson', () {
    test('parses a native module descriptor', () {
      final m = ModuleDescriptor.fromJson({
        'id': 'schedule', 'title': 'Mój grafik', 'type': 'native', 'screen': 'my_schedule',
        'icon': 'calendar', 'order': 10, 'enabled': true, 'requires_online': false, 'required_role': null,
      });
      expect(m.type, ModuleType.native);
      expect(m.screen, 'my_schedule');
      expect(m.path, isNull);
    });

    test('parses a webview module descriptor', () {
      final m = ModuleDescriptor.fromJson({
        'id': 'triduum', 'title': 'Triduum', 'type': 'webview', 'path': '/public/triduum.php',
        'icon': 'church', 'order': 100, 'enabled': true, 'requires_online': true, 'required_role': [1, 2],
      });
      expect(m.type, ModuleType.webview);
      expect(m.path, '/public/triduum.php');
      expect(m.requiredRoles, [1, 2]);
    });

    test(
      'review round point 23: an unrecognized type never throws — becomes ModuleType.unknown, safe-fallback territory',
      () {
        final m = ModuleDescriptor.fromJson({'id': 'mystery', 'title': 'Mystery', 'type': 'holographic'});
        expect(m.type, ModuleType.unknown);
      },
    );

    test('missing type entirely is also unknown, not a crash', () {
      final m = ModuleDescriptor.fromJson({'id': 'x', 'title': 'X'});
      expect(m.type, ModuleType.unknown);
    });
  });

  group('ModuleDescriptor.visibleFor (review round point 22 — display filter only)', () {
    test('required_role null is visible to every signed-in role', () {
      final m = ModuleDescriptor.fromJson({'id': 'schedule', 'title': 'X', 'type': 'native', 'screen': 'my_schedule', 'enabled': true});
      expect(m.visibleFor(5), isTrue);
      expect(m.visibleFor(1), isTrue);
    });

    test('required_role restricts to listed roles only', () {
      final m = ModuleDescriptor.fromJson({
        'id': 'users_admin', 'title': 'Users', 'type': 'webview', 'path': '/public/users.php',
        'enabled': true, 'required_role': [1, 2],
      });
      expect(m.visibleFor(1), isTrue, reason: 'Admin');
      expect(m.visibleFor(2), isTrue, reason: 'Ksiądz');
      expect(m.visibleFor(5), isFalse, reason: 'Ministrant — not in the allowed list');
      expect(m.visibleFor(null), isFalse, reason: 'no role known at all');
    });

    test('a disabled module is never visible regardless of role', () {
      final m = ModuleDescriptor.fromJson({'id': 'x', 'title': 'X', 'type': 'native', 'screen': 'y', 'enabled': false});
      expect(m.visibleFor(1), isFalse);
      expect(m.visibleFor(null), isFalse);
    });
  });

  group('ModuleDescriptor.parseList', () {
    test('sorts by order, not input order', () {
      final list = ModuleDescriptor.parseList([
        {'id': 'b', 'title': 'B', 'type': 'native', 'screen': 'b', 'order': 20, 'enabled': true},
        {'id': 'a', 'title': 'A', 'type': 'native', 'screen': 'a', 'order': 10, 'enabled': true},
      ]);
      expect(list.map((m) => m.id).toList(), ['a', 'b']);
    });
  });

  group('ModuleDescriptor.section (legacy inventory milestone — mirrors real sidebar.php\'s "Konfiguracja" grouping)', () {
    test('parses the section field when present', () {
      final m = ModuleDescriptor.fromJson({
        'id': 'groups_admin', 'title': 'Zarządzaj grupami', 'type': 'webview', 'path': '/public/groups.php',
        'enabled': true, 'required_role': [1, 2], 'section': 'config',
      });
      expect(m.section, 'config');
    });

    test('section is null when absent — an everyday module, not grouped', () {
      final m = ModuleDescriptor.fromJson({
        'id': 'schedule', 'title': 'Mój grafik', 'type': 'native', 'screen': 'my_schedule', 'enabled': true,
      });
      expect(m.section, isNull);
    });
  });
}
