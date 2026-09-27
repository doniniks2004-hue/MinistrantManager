import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/features/activation/activation_service.dart';

void main() {
  // extractTokenFromQr() touches no I/O (no secure storage read/write, no
  // network call) — constructing the real collaborators is safe here
  // without mocking platform channels, since Dart doesn't invoke them
  // until a method that actually needs them is called.
  final service = ActivationService(
    api: ApiClient(SecureStorageService()),
    secureStorage: SecureStorageService(),
  );

  group('ActivationService.extractTokenFromQr — spec §12/§35', () {
    test('extracts the token from a full https:// App Link URL', () {
      expect(
        service.extractTokenFromQr('https://app.ministrant.eu/activate/abc123def456'),
        'abc123def456',
      );
    });

    test('extracts the token from a URL with a trailing slash or query string stripped by the caller', () {
      expect(
        service.extractTokenFromQr('https://app.ministrant.eu/activate/abc123'),
        'abc123',
      );
    });

    test('a bare token/display code with no URL structure is returned trimmed, unchanged', () {
      expect(service.extractTokenFromQr('  73FK-92MX  '), '73FK-92MX');
    });

    test('a completely unrelated QR payload is still returned trimmed, not crashed on', () {
      expect(service.extractTokenFromQr('https://example.com/something-else'), 'https://example.com/something-else');
    });

    // Review round (final micro-round, point 5): verbatim scenarios from
    // the review report.
    test('an activation-shaped link on a DIFFERENT host is rejected — never extracted as if it were ours', () {
      expect(service.extractTokenFromQr('https://evil.example/activate/abc'), isNull);
    });

    test('an activation-shaped link over plain http (not https) on the right host is also rejected', () {
      expect(service.extractTokenFromQr('http://app.ministrant.eu/activate/abc'), isNull);
    });

    test('the genuine host + https still extracts normally, unaffected by the new validation', () {
      expect(service.extractTokenFromQr('https://app.ministrant.eu/activate/abc'), 'abc');
    });

    test('a bare display code is unaffected by the URL validation path at all', () {
      expect(service.extractTokenFromQr('73FK-92MX'), '73FK-92MX');
    });
  });
}
