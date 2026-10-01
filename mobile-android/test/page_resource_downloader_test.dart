import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/page_resource_downloader.dart';

/// Offline-architecture milestone, P4. Real HTTP requests (via the
/// downloader's own dart:io HttpClient) against a really-bound local
/// server serving fixed, known fixtures — no mocking, since the whole
/// point of this class is correctly discovering/fetching/rewriting real
/// resource references, which a mock would just assume away.
void main() {
  late HttpServer fakeSite;
  late Uri baseUrl;

  setUp(() async {
    fakeSite = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = Uri.parse('http://127.0.0.1:${fakeSite.port}');

    fakeSite.listen((request) async {
      final path = request.uri.path;
      final response = request.response;

      switch (path) {
        case '/public/dashboard.php':
          response.headers.contentType = ContentType.html;
          response.write('''
            <html><head>
              <link rel="stylesheet" href="/assets/css/style.css">
              <link rel="icon" href="/favicon.ico">
              <style>.inline { background: url('/assets/img/inline-bg.png'); }</style>
            </head>
            <body style="background-image:url(/assets/img/body-bg.png)">
              <script src="/assets/js/app.js"></script>
              <img src="/assets/img/logo.png" srcset="/assets/img/logo.png 1x, /assets/img/logo@2x.png 2x">
              <img src="https://cdn.example.com/external.png">
              <img src="/assets/img/missing.png">
            </body></html>
          ''');
          break;
        case '/assets/css/style.css':
          response.headers.contentType = ContentType('text', 'css');
          response.write('''
            @import url('nested.css');
            body { background: url(../img/css-bg.png); }
          ''');
          break;
        case '/assets/css/nested.css':
          response.headers.contentType = ContentType('text', 'css');
          response.write('.nested { background: url(../fonts/font.woff2); }');
          break;
        case '/assets/js/app.js':
          response.headers.contentType = ContentType('text', 'javascript');
          response.write('console.log("app");');
          break;
        case '/favicon.ico':
          response.headers.contentType = ContentType('image', 'x-icon');
          response.write('ICO');
          break;
        case '/assets/img/logo.png':
        case '/assets/img/logo@2x.png':
        case '/assets/img/inline-bg.png':
        case '/assets/img/body-bg.png':
        case '/assets/img/css-bg.png':
          response.headers.contentType = ContentType('image', 'png');
          response.write('PNGDATA:$path');
          break;
        case '/assets/fonts/font.woff2':
          response.headers.contentType = ContentType('font', 'woff2');
          response.write('FONTDATA');
          break;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  });

  tearDown(() async {
    await fakeSite.close(force: true);
  });

  test('captures the main stylesheet, script, icon and image, rewriting their references to /assets/', () async {
    final html = await _fetchString(baseUrl.resolve('/public/dashboard.php'));
    final downloader = PageResourceDownloader();

    final result = await downloader.capture(pageUrl: baseUrl.resolve('/public/dashboard.php'), renderedHtml: html);

    expect(result.assets.containsKey('assets/css/style.css'), isTrue);
    expect(result.assets.containsKey('assets/js/app.js'), isTrue);
    expect(result.assets.containsKey('favicon.ico'), isTrue);
    expect(result.assets.containsKey('assets/img/logo.png'), isTrue);
    expect(utf8.decode(result.assets['assets/js/app.js']!), 'console.log("app");');

    expect(result.html, contains('href="/assets/assets/css/style.css"'));
    expect(result.html, contains('src="/assets/assets/js/app.js"'));
    expect(result.html, contains('href="/assets/favicon.ico"'));
  });

  test('recursively follows @import inside a stylesheet and rewrites its own url() reference', () async {
    final html = await _fetchString(baseUrl.resolve('/public/dashboard.php'));
    final downloader = PageResourceDownloader();

    final result = await downloader.capture(pageUrl: baseUrl.resolve('/public/dashboard.php'), renderedHtml: html);

    expect(result.assets.containsKey('assets/css/nested.css'), isTrue, reason: '@import target must be fetched');
    expect(result.assets.containsKey('assets/img/css-bg.png'), isTrue, reason: 'url() inside the main stylesheet must be fetched');
    expect(result.assets.containsKey('assets/fonts/font.woff2'), isTrue, reason: 'url() inside the NESTED @import stylesheet must also be fetched');

    final rewrittenMainCss = utf8.decode(result.assets['assets/css/style.css']!);
    expect(rewrittenMainCss, contains('@import url(/assets/assets/css/nested.css)'));
    expect(rewrittenMainCss, contains('url(/assets/assets/img/css-bg.png)'));

    final rewrittenNestedCss = utf8.decode(result.assets['assets/css/nested.css']!);
    expect(rewrittenNestedCss, contains('url(/assets/assets/fonts/font.woff2)'));
  });

  test('rewrites an inline <style> block and a style="" attribute', () async {
    final html = await _fetchString(baseUrl.resolve('/public/dashboard.php'));
    final downloader = PageResourceDownloader();

    final result = await downloader.capture(pageUrl: baseUrl.resolve('/public/dashboard.php'), renderedHtml: html);

    expect(result.assets.containsKey('assets/img/inline-bg.png'), isTrue);
    expect(result.assets.containsKey('assets/img/body-bg.png'), isTrue);
    expect(result.html, contains('/assets/assets/img/inline-bg.png'));
    expect(result.html, contains('/assets/assets/img/body-bg.png'));
  });

  test('rewrites every entry in a srcset, each with its own descriptor preserved', () async {
    final html = await _fetchString(baseUrl.resolve('/public/dashboard.php'));
    final downloader = PageResourceDownloader();

    final result = await downloader.capture(pageUrl: baseUrl.resolve('/public/dashboard.php'), renderedHtml: html);

    expect(result.assets.containsKey('assets/img/logo@2x.png'), isTrue);
    expect(result.html, contains('/assets/assets/img/logo.png 1x'));
    expect(result.html, contains('/assets/assets/img/logo@2x.png 2x'));
  });

  test('cross-origin resources are left completely untouched', () async {
    final html = await _fetchString(baseUrl.resolve('/public/dashboard.php'));
    final downloader = PageResourceDownloader();

    final result = await downloader.capture(pageUrl: baseUrl.resolve('/public/dashboard.php'), renderedHtml: html);

    expect(result.html, contains('https://cdn.example.com/external.png'), reason: 'the original cross-origin URL must survive unrewritten');
    expect(result.assets.keys.any((k) => k.contains('external')), isFalse);
  });

  test('a genuinely unreachable (404) resource is left in place rather than rewritten to a dead local path', () async {
    final html = await _fetchString(baseUrl.resolve('/public/dashboard.php'));
    final downloader = PageResourceDownloader();

    final result = await downloader.capture(pageUrl: baseUrl.resolve('/public/dashboard.php'), renderedHtml: html);

    expect(result.html, contains('/assets/img/missing.png'), reason: 'original reference preserved, never rewritten to /assets/assets/img/missing.png');
    expect(result.assets.containsKey('assets/img/missing.png'), isFalse);
  });

  test('the same resource referenced twice over is only actually fetched once over the network', () async {
    var requestCount = 0;
    final countingSite = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    countingSite.listen((request) async {
      if (request.uri.path == '/assets/img/logo.png') requestCount++;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.write('PNG');
      await request.response.close();
    });
    final countingBaseUrl = Uri.parse('http://127.0.0.1:${countingSite.port}');

    final html = '''
      <html><body>
        <img src="/assets/img/logo.png">
        <img src="/assets/img/logo.png">
      </body></html>
    ''';
    final downloader = PageResourceDownloader();
    final result = await downloader.capture(pageUrl: countingBaseUrl.resolve('/public/dashboard.php'), renderedHtml: html);

    expect(requestCount, 1, reason: 'two references to the identical URL must result in exactly one network request');
    expect(result.assets.length, 1);

    await countingSite.close(force: true);
  });
}

Future<String> _fetchString(Uri url) async {
  final client = HttpClient();
  final request = await client.getUrl(url);
  final response = await request.close();
  return utf8.decoder.bind(response).join();
}
