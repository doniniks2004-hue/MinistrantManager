import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/page_resource_downloader.dart';

/// THE PREMISE of storing public resources authenticated rather than encrypted
/// (SnapshotEncryptor.sealPublic): everything the downloader fetched, it fetched
/// WITHOUT credentials, so anyone can fetch the same bytes at the same address.
/// If the downloader ever starts sending a cookie or an authorisation header,
/// that stops being true (a resource could then be personal) and this fails,
/// which is the cue to encrypt such resources again.
void main() {
  test('the downloader sends no cookie, no authorisation, nothing that identifies the user', () async {
    final seen = <String, Map<String, List<String>>>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final headers = <String, List<String>>{};
      request.headers.forEach((name, values) => headers[name.toLowerCase()] = values);
      seen[request.uri.path] = headers;
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.text;
      request.response.write('x');
      await request.response.close();
    });
    final base = Uri.parse('http://127.0.0.1:${server.port}');

    await PageResourceDownloader().capture(
      pageUrl: base.resolve('/public/dashboard.php'),
      renderedHtml: '<html><head><link rel="stylesheet" href="/public/css/style.css"></head>'
          '<body><img src="/public/ikona.png"><script src="/public/js/script.js"></script></body></html>',
    );

    expect(seen.keys, containsAll(['/public/css/style.css', '/public/ikona.png', '/public/js/script.js']));
    for (final entry in seen.entries) {
      for (final forbidden in ['cookie', 'authorization', 'proxy-authorization', 'x-installation-id', 'x-device-token']) {
        expect(entry.value.containsKey(forbidden), isFalse, reason: '${entry.key} carried "$forbidden"');
      }
    }
  });
}
