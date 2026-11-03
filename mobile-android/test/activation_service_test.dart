import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/features/activation/activation_service.dart';

class _ActivationAdapter implements HttpClientAdapter {
  _ActivationAdapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async => respond(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body), status,
  headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
);

void main() {
  // extractTokenFromQr() touches no I/O (no secure storage read/write, no
  // network call) — constructing the real collaborators is safe here
  // without mocking platform channels, since Dart doesn't invoke them
  // until a method that actually needs them is called.
  final service = ActivationService(
    api: ApiClient(SecureStorageService()),
    secureStorage: SecureStorageService(),
  );


  group('activation API responses', () {
    late ApiClient api;
    late ActivationService activation;
    setUp(() {
      final storage = SecureStorageService();
      api = ApiClient(storage);
      activation = ActivationService(api: api, secureStorage: storage);
    });
    tearDown(() => api.central.close(force: true));

    test('requests JSON and resolves parish without following a website redirect', () async {
      api.central.httpClientAdapter = _ActivationAdapter((request) {
        expect(request.followRedirects, isFalse);
        // Models Laravel's content negotiation observed on the live endpoint.
        if (request.headers['Accept'] != Headers.jsonContentType) {
          return ResponseBody.fromString('<html>redirect</html>', 302);
        }
        return _json(200, {'parish': {
          'name': 'Szarlej', 'server_url': 'https://szarlej.ministrant.eu',
        }});
      });
      final result = await activation.checkCode(displayCode: 'TEST-CODE');
      expect(result.parishName, 'Szarlej');
      expect(result.serverUrl, 'https://szarlej.ministrant.eu');
    });

    for (final scenario in <(int, Object, String)>[
      (422, {'errors': {'code': ['invalid']}}, 'Kod aktywacyjny jest nieprawidłowy'),
      (429, {'message': 'limited'}, 'Odczekaj 10 minut'),
      (503, {'message': 'unavailable'}, 'HTTP 503'),
      (302, {'message': 'redirect'}, 'HTTP 302'),
      (422, {'errors': {'installation_id': ['invalid']}}, 'Serwer odrzucił dane'),
      (200, {'unexpected': true}, 'nieprawidłową odpowiedź'),
    ]) {
      test('classifies ${scenario.$1}: ${scenario.$3}', () async {
        api.central.httpClientAdapter = _ActivationAdapter((_) => _json(scenario.$1, scenario.$2));
        await expectLater(activation.checkCode(displayCode: 'TEST-CODE'),
          throwsA(isA<ActivationError>().having((e) => e.message, 'message', contains(scenario.$3))));
      });
    }

    test('network timeout does not blame the activation code', () async {
      api.central.httpClientAdapter = _ActivationAdapter((request) {
        throw DioException(requestOptions: request, type: DioExceptionType.connectionTimeout);
      });
      await expectLater(activation.checkCode(displayCode: 'TEST-CODE'),
        throwsA(isA<ActivationError>().having((e) => e.message, 'message',
          contains('Nie udało się połączyć'))));
    });

    test('authenticated central requests also request JSON and reject redirects', () {
      final client = api.centralWithAuth('test-token');
      expect(client.options.headers['Accept'], Headers.jsonContentType);
      expect(client.options.followRedirects, isFalse);
      client.close();
    });
  });

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
