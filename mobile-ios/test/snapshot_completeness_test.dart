import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/page_resource_downloader.dart';
import 'package:ministrant_manager/core/offline/snapshot_capture_service.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';

/// The structure of the real parish panel (taken from its header.php, footer.php
/// and dashboard.php): one stylesheet and one script on every page, the logo
/// twice, an inline @import of Google Fonts, and a data: SVG inside the CSS.
String _page(String body) => '''
<html><head>
<link rel="stylesheet" href="/public/css/style.css">
<link rel="icon" type="image/png" href="/public/ikona.png">
<style>
@import url('https://fonts.googleapis.com/css2?family=Poppins:wght@400;500;600;700;800&display=swap');
body { font-family: 'Poppins', sans-serif; }
</style>
</head><body>
<img src="/public/ikona.png" alt="Logo">
<main>$body</main>
<script src="/public/js/script.js"></script>
</body></html>''';

const _css = '''
.eye { background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24'%3E%3C/svg%3E"); }
body { margin: 0; }
''';

class _Reply {
  const _Reply(this.body, {this.status = 200, this.delay = Duration.zero, this.type = 'text/plain'});
  final String body;
  final int status;
  final Duration delay;
  final String type;
}

void main() {
  late HttpServer server;
  late Uri base;
  late Map<String, _Reply> routes;
  late Directory tmp;

  final encryptor = SnapshotEncryptor(hexKey: '1' * 64);

  Map<String, _Reply> healthy() => {
    '/public/css/style.css': const _Reply(_css, type: 'text/css'),
    '/public/js/script.js': const _Reply('window.ok = 1;', type: 'application/javascript'),
    '/public/ikona.png': const _Reply('PNGDATA', type: 'image/png'),
  };

  setUp(() async {
    routes = healthy();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      final reply = routes[request.uri.path];
      if (reply == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        if (reply.delay > Duration.zero) await Future<void>.delayed(reply.delay);
        request.response.statusCode = reply.status;
        request.response.headers.contentType = ContentType.parse(reply.type);
        request.response.write(reply.body);
      }
      await request.response.close();
    });
    tmp = await Directory.systemTemp.createTemp('mm_completeness_');
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  Future<CapturedPage> capture(PageResourceDownloader downloader, String html) =>
      downloader.capture(pageUrl: base.resolve('/public/dashboard.php'), renderedHtml: html);

  group('the downloader sorts what is missing', () {
    test('the real panel structure: complete; Google Fonts is external, not missing', () async {
      final page = await capture(PageResourceDownloader(), _page('v1'));

      expect(page.missingCritical, isEmpty);
      expect(page.missingOptional, isEmpty);
      expect(page.budgetExhausted, isFalse);
      expect(page.externalHosts, ['fonts.googleapis.com']);
      expect(page.assets.keys, containsAll(['public/css/style.css', 'public/js/script.js', 'public/ikona.png']));
      expect(page.html, contains('/assets/public/css/style.css'));
      expect(page.html, contains('/assets/public/js/script.js'));
      expect(page.html, contains('fonts.googleapis.com'), reason: 'the external import is left as it was');
      expect(
        utf8.decode(page.assets['public/css/style.css']!),
        contains('data:image/svg+xml'),
        reason: 'a data: URL is self-contained and untouched',
      );
    });

    test('a stylesheet that cannot be fetched is CRITICAL', () async {
      routes['/public/css/style.css'] = const _Reply('boom', status: 500);
      final page = await capture(PageResourceDownloader(), _page('v1'));
      expect(page.missingCritical, ['public/css/style.css']);
    });

    test('a script that cannot be fetched is CRITICAL', () async {
      routes.remove('/public/js/script.js');
      final page = await capture(PageResourceDownloader(), _page('v1'));
      expect(page.missingCritical, ['public/js/script.js']);
    });

    test('the logo is OPTIONAL: the page is still complete without it', () async {
      routes.remove('/public/ikona.png');
      final page = await capture(PageResourceDownloader(), _page('v1'));
      expect(page.missingCritical, isEmpty);
      expect(page.missingOptional, ['public/ikona.png'], reason: 'once, though used twice');
    });

    test('what a stylesheet @imports is CRITICAL too', () async {
      routes['/public/css/style.css'] = const _Reply("@import url('nested.css'); body{}", type: 'text/css');
      final page = await capture(PageResourceDownloader(), _page('v1'));
      expect(page.missingCritical, ['public/css/nested.css']);
    });

    test('a resource that answers with a redirect (a session is needed) is missing, not silently accepted', () async {
      routes['/public/css/style.css'] = const _Reply('', status: 302);
      final page = await capture(PageResourceDownloader(), _page('v1'));
      expect(page.missingCritical, ['public/css/style.css']);
    });

    test('the total time is bounded, and what did not arrive in it is missing', () async {
      routes['/public/js/script.js'] = const _Reply('x', delay: Duration(seconds: 3));
      final watch = Stopwatch()..start();
      final page = await capture(
        PageResourceDownloader(totalBudget: const Duration(milliseconds: 400)),
        _page('v1'),
      );
      expect(watch.elapsedMilliseconds, lessThan(2000), reason: 'not the resource\'s own 3 s, never more than what is left');
      expect(page.budgetExhausted, isTrue);
      expect(page.missingCritical, contains('public/js/script.js'));
    });

    test('the total size is bounded', () async {
      routes['/public/css/style.css'] = _Reply('a' * 5000, type: 'text/css');
      final page = await capture(PageResourceDownloader(maxTotalBytes: 1000), _page('v1'));
      expect(page.budgetExhausted, isTrue);
      expect(page.missingCritical, contains('public/css/style.css'));
    });
  });

  group('a page is saved only when it is complete', () {
    late SnapshotStore store;
    late SnapshotCaptureService service;

    setUp(() {
      store = SnapshotStore(encryptor: encryptor, rootOverride: tmp);
      service = SnapshotCaptureService(downloader: PageResourceDownloader(), store: store);
    });

    Future<CaptureOutcome> save(String body) => service.captureAndSave(
      parishId: 'p',
      userId: 'u',
      serverBaseUrl: base,
      targetPath: '/public/dashboard.php',
      renderedHtml: _page(body),
    );

    Future<String?> savedHtml() async {
      final dir = await store.getPageDirectoryIfReady(
        parishId: 'p',
        userId: 'u',
        pagePath: '/public/dashboard.php',
      );
      if (dir == null) return null;
      return utf8.decode(encryptor.decryptBytes(await File('${dir.path}/snapshot.html').readAsBytes()));
    }

    test('a complete page is saved, and the outcome says so', () async {
      final outcome = await save('v1');
      expect(outcome.status, CaptureStatus.saved);
      expect(outcome.externalHosts, ['fonts.googleapis.com']);
      expect(await savedHtml(), contains('v1'));
    });

    test('a page without its stylesheet does NOT replace the working copy', () async {
      expect((await save('v1')).status, CaptureStatus.saved);

      routes['/public/css/style.css'] = const _Reply('down', status: 503);
      final outcome = await save('v2-broken');

      expect(outcome.status, CaptureStatus.rejectedIncomplete);
      expect(outcome.missingCritical, ['public/css/style.css']);
      final html = await savedHtml();
      expect(html, contains('v1'), reason: 'the previous copy is untouched');
      expect(html, isNot(contains('v2-broken')));
    });

    test('with no copy yet, an incomplete page is not saved at all', () async {
      routes.remove('/public/js/script.js');
      expect((await save('v1')).status, CaptureStatus.rejectedIncomplete);
      expect(await savedHtml(), isNull);
    });

    test('a missing logo does not stop the page being saved; the outcome names it', () async {
      routes.remove('/public/ikona.png');
      final outcome = await save('v1');
      expect(outcome.status, CaptureStatus.saved);
      expect(outcome.missingOptional, ['public/ikona.png']);
      expect(await savedHtml(), contains('v1'));
    });

    test('after the stylesheet is back, the next capture replaces the copy', () async {
      expect((await save('v1')).status, CaptureStatus.saved);
      routes['/public/css/style.css'] = const _Reply('down', status: 503);
      expect((await save('v2')).status, CaptureStatus.rejectedIncomplete);
      routes['/public/css/style.css'] = const _Reply(_css, type: 'text/css');
      expect((await save('v3')).status, CaptureStatus.saved);
      expect(await savedHtml(), contains('v3'));
    });

    test('pages that are never saved are reported as such', () async {
      final outcome = await service.captureAndSave(
        parishId: 'p',
        userId: 'u',
        serverBaseUrl: base,
        targetPath: '/public/login.php',
        renderedHtml: _page('login'),
      );
      expect(outcome.status, CaptureStatus.notCapturable);
    });

    test('the outcome carries no page content and no user data', () async {
      routes.remove('/public/ikona.png');
      final text = (await save('SECRET-CONTENT-OF-THE-PAGE')).toString();
      expect(text, isNot(contains('SECRET-CONTENT')));
      expect(text, isNot(contains('public/ikona.png')), reason: 'diagnostics summarize optional resources without revealing their paths');
    });
  });
}
