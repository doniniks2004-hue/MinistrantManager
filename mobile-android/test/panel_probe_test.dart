import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/panel_probe.dart';

/// Computed independently, in Python:
///   json.dumps(spec, separators=(',',':')) -> base64 -> sha256 -> first 12 hex.
const specB64 =
    'eyJwYXRoIjoiL3B1YmxpYy9kYXNoYm9hcmQucGhwIiwicmVxdWlyZWQiOlsiI3BhbmVsIl0sImZvcmJpZGRlbiI6WyJpbnB1dFt0eXBlPXBhc3N3b3JkXSJdLCJzdHlsZXMiOlt7InNlbGVjdG9yIjoiYm9keSIsInByb3BlcnR5IjoiYmFja2dyb3VuZC1jb2xvciIsIm5vdCI6InJnYmEoMCwgMCwgMCwgMCkifV19';
const specId = '08e9cf523dae';

String enc(Object? json) => base64.encode(utf8.encode(jsonEncode(json)));

void main() {
  group('PanelSpec', () {
    test('reads the owner\'s spec, and its id is the one computed outside Dart', () {
      final spec = PanelSpec.fromBase64(specB64)!;
      expect(spec.id, specId);
      expect(PanelSpec.idOf(specB64), specId);
      expect(spec.path, '/public/dashboard.php');
      expect(spec.required, ['#panel']);
      expect(spec.forbidden, ['input[type=password]']);
      expect(spec.styles.single.property, 'background-color');
      expect(spec.styles.single.not, 'rgba(0, 0, 0, 0)');
    });

    test('the id follows the text: another spec, another id', () {
      final other = enc({'required': ['#other']});
      expect(PanelSpec.fromBase64(other)!.id, isNot(specId));
    });

    test('not base64, not JSON, not an object: no spec', () {
      expect(PanelSpec.fromBase64(''), isNull);
      expect(PanelSpec.fromBase64('!!!not base64!!!'), isNull);
      expect(PanelSpec.fromBase64(base64.encode(utf8.encode('not json'))), isNull);
      expect(PanelSpec.fromBase64(base64.encode(utf8.encode('[1,2]'))), isNull);
    });

    test('a spec that names no required element identifies nothing: no spec', () {
      expect(PanelSpec.fromBase64(enc({'required': []})), isNull);
      expect(PanelSpec.fromBase64(enc({'forbidden': ['.x']})), isNull);
      expect(PanelSpec.fromBase64(enc({})), isNull);
    });

    test('wrong types and limits: no spec', () {
      expect(PanelSpec.fromBase64(enc({'required': '#a'})), isNull);
      expect(PanelSpec.fromBase64(enc({'required': [1]})), isNull);
      expect(PanelSpec.fromBase64(enc({'required': ['']})), isNull);
      expect(PanelSpec.fromBase64(enc({'required': ['a' * 201]})), isNull);
      expect(PanelSpec.fromBase64(enc({'required': List.filled(21, '#a')})), isNull);
      expect(PanelSpec.fromBase64(enc({'required': ['#a\nb']})), isNull);
      expect(PanelSpec.fromBase64(enc({'required': ['#a'], 'path': 'no-slash'})), isNull);
      expect(PanelSpec.fromBase64(enc({'required': ['#a'], 'path': 5})), isNull);
      expect(PanelSpec.fromBase64('A' * (PanelSpec.maxEncodedLength + 1)), isNull);
    });

    test('a style check has exactly one of not / equals and a plain property name', () {
      expect(PanelSpec.fromBase64(enc({'required': ['#a'], 'styles': [{'selector': 'body', 'property': 'color'}]})), isNull);
      expect(
        PanelSpec.fromBase64(enc({'required': ['#a'], 'styles': [{'selector': 'body', 'property': 'color', 'not': 'x', 'equals': 'y'}]})),
        isNull,
      );
      expect(
        PanelSpec.fromBase64(enc({'required': ['#a'], 'styles': [{'selector': 'body', 'property': 'color; x', 'not': 'x'}]})),
        isNull,
      );
      expect(
        PanelSpec.fromBase64(enc({'required': ['#a'], 'styles': [{'selector': 'body', 'property': 'color', 'equals': 'rgb(0, 0, 0)'}]})),
        isNotNull,
      );
    });
  });

  group('the probe script', () {
    final spec = PanelSpec.fromBase64(specB64)!;

    test('reports twice at most: through two animation frames, or the fallback timer, whichever is first', () {
      final js = buildPanelProbe(nav: 7, channel: 'MM_Paint', spec: spec);
      expect(js, contains('requestAnimationFrame'));
      expect(js, contains("report('raf')"));
      expect(js, contains("report('timer')"));
      expect(js, contains('if (done) return;'));
      expect(js, contains('nav: 7'));
    });

    test('carries the spec and its id, and nothing is left unreplaced', () {
      final js = buildPanelProbe(nav: 1, channel: 'MM_Paint', spec: spec);
      expect(js, contains("spec: '$specId'"));
      expect(js, contains('"#panel"'));
      expect(js, contains('input[type=password]'));
      expect(js, isNot(contains('__')));
    });

    test('without a spec it says so (verdict none) and carries no spec', () {
      final js = buildPanelProbe(nav: 1, channel: 'MM_Paint');
      expect(js, contains('var spec = null;'));
      expect(js, contains("spec: '-'"));
    });

    test('checks that required elements are SHOWN (not just present), and that styles are computed values', () {
      final js = buildPanelProbe(nav: 1, channel: 'MM_Paint', spec: spec);
      expect(js, contains("cs.display === 'none'"));
      expect(js, contains("cs.visibility === 'hidden'"));
      expect(js, contains('getComputedStyle(el).getPropertyValue'));
      expect(js, contains('document.hidden'));
    });
  });
}
