import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/features/dashboard/module_version_gate.dart';

void main() {
  group('ModuleVersionGate', () {
    test('device version older than minimum -> gated (verbatim spec §18 example)', () {
      expect(ModuleVersionGate.isOlderThan('2.1.0', '2.4.0'), isTrue);
      expect(ModuleVersionGate.isSupported('2.1.0', '2.4.0'), isFalse);
    });

    test('device version equal to minimum -> supported', () {
      expect(ModuleVersionGate.isSupported('2.4.0', '2.4.0'), isTrue);
    });

    test('device version newer than minimum -> supported', () {
      expect(ModuleVersionGate.isSupported('3.0.0', '2.4.0'), isTrue);
    });

    test('no minimum version (null) -> always supported', () {
      expect(ModuleVersionGate.isSupported('0.0.1', null), isTrue);
    });

    test('handles version strings with fewer/more than 3 components gracefully', () {
      expect(ModuleVersionGate.isSupported('2.4', '2.4.0'), isTrue);
      expect(ModuleVersionGate.isSupported('2', '2.4.0'), isFalse);
    });
  });
}
