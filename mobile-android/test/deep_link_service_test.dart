import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/deeplink/deep_link_service.dart';

void main() {
  final service = DeepLinkService();

  group('DeepLinkService — review round 2 point 6 (host/scheme validation)', () {
    test('accepts a genuine https://app.ministrant.eu/activate/{token} link', () {
      final token = service.extractTokenForTesting(Uri.parse('https://app.ministrant.eu/activate/abc123'));
      expect(token, 'abc123');
    });

    test('rejects a spoofed host, even with the right path shape', () {
      final token = service.extractTokenForTesting(Uri.parse('https://evil.example.com/activate/abc123'));
      expect(token, isNull);
    });

    test('rejects a non-https scheme, even against the trusted host', () {
      final token = service.extractTokenForTesting(Uri.parse('http://app.ministrant.eu/activate/abc123'));
      expect(token, isNull);
    });

    test('rejects a custom scheme masquerading as an app link', () {
      final token = service.extractTokenForTesting(Uri.parse('myapp://app.ministrant.eu/activate/abc123'));
      expect(token, isNull);
    });

    test('rejects a trusted host with no /activate/ segment at all', () {
      final token = service.extractTokenForTesting(Uri.parse('https://app.ministrant.eu/some/other/path'));
      expect(token, isNull);
    });

    test('rejects a trusted https link where /activate/ has no token after it', () {
      final token = service.extractTokenForTesting(Uri.parse('https://app.ministrant.eu/activate/'));
      expect(token, isNull);
    });

    test('a null Uri (no link at all) is handled without throwing', () {
      expect(service.extractTokenForTesting(null), isNull);
    });
  });
}
