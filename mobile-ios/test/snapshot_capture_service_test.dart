import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/local_snapshot_server.dart';
import 'package:ministrant_manager/core/offline/page_resource_downloader.dart';
import 'package:ministrant_manager/core/offline/snapshot_capture_service.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';

/// Offline-architecture milestone, P5. Review round: "dopiero po P5
/// będziemy mieli pierwszy kompletny łańcuch offline, a nie tylko
/// niezależne komponenty" — these tests prove exactly that: a fake
/// "online PHP site" (real HTTP server) is captured end-to-end and then
/// actually served back by a real, separately-bound [LocalSnapshotServer]
/// — no WebView involved yet (that's the next milestone), but every
/// OTHER link in the chain is real, nothing mocked.
void main() {
  late HttpServer onlineSite;
  late Uri onlineBaseUrl;
  late Directory tempRoot;
  late SnapshotStore store;
  late SnapshotCaptureService service;

  setUp(() async {
    onlineSite = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    onlineBaseUrl = Uri.parse('http://127.0.0.1:${onlineSite.port}');
    onlineSite.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/public/dashboard.php':
          response.headers.contentType = ContentType.html;
          response.write('''
            <html><head><link rel="stylesheet" href="/assets/style.css"></head>
            <body><img src="/assets/logo.png"><p>Dashboard v1</p></body></html>
          ''');
          break;
        case '/assets/style.css':
          response.headers.contentType = ContentType('text', 'css');
          response.write('body { color: blue; }');
          break;
        case '/assets/logo.png':
          response.headers.contentType = ContentType('image', 'png');
          response.write('PNGDATA');
          break;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

    tempRoot = await Directory.systemTemp.createTemp('snapshot_capture_service_test_');
    store = SnapshotStore(rootOverride: tempRoot);
    service = SnapshotCaptureService(downloader: PageResourceDownloader(), store: store);
  });

  tearDown(() async {
    await onlineSite.close(force: true);
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<String> fetchOnline(String path) async {
    final client = HttpClient();
    final request = await client.getUrl(onlineBaseUrl.resolve(path));
    final response = await request.close();
    return utf8.decoder.bind(response).join();
  }

  group('SnapshotCaptureService', () {
    test('captures a real page end-to-end into a complete, readable SnapshotStore entry', () async {
      final html = await fetchOnline('/public/dashboard.php');

      await service.captureAndSave(
        parishId: 'witosa',
        userId: '9001',
        pageUrl: onlineBaseUrl.resolve('/public/dashboard.php'),
        renderedHtml: html,
      );

      final manifest = await store.readManifestFor(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php');
      expect(manifest, isNotNull);
      expect(manifest!.path, '/public/dashboard.php');
      expect(manifest.resources, containsAll(['assets/assets/style.css', 'assets/assets/logo.png']));

      final dir = await store.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php');
      expect(await File('${dir!.path}/snapshot.html').readAsString(), contains('Dashboard v1'));
      expect(await File('${dir.path}/assets/assets/style.css').readAsString(), 'body { color: blue; }');
      expect(await File('${dir.path}/assets/assets/logo.png').readAsString(), 'PNGDATA');
    });

    test(
      'capstone: the captured snapshot is actually servable end-to-end through a real LocalSnapshotServer — no WebView needed to prove the chain',
      () async {
        final html = await fetchOnline('/public/dashboard.php');
        await service.captureAndSave(
          parishId: 'witosa',
          userId: '9001',
          pageUrl: onlineBaseUrl.resolve('/public/dashboard.php'),
          renderedHtml: html,
        );

        final pageDir = await store.getPageDirectoryIfReady(
          parishId: 'witosa',
          userId: '9001',
          pagePath: '/public/dashboard.php',
        );
        expect(pageDir, isNotNull);

        final localServer = LocalSnapshotServer();
        final port = await localServer.start();
        localServer.rootDirectory = pageDir;

        final client = HttpClient();

        final pageResp = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port/snapshot.html'))).close();
        final pageBody = await utf8.decoder.bind(pageResp).join();
        expect(pageResp.statusCode, 200);
        expect(pageBody, contains('Dashboard v1'));
        expect(pageBody, contains('/assets/assets/style.css'), reason: 'the HTML served offline must contain the SAME rewritten reference that was captured');

        final cssResp = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port/assets/assets/style.css'))).close();
        expect(cssResp.statusCode, 200);
        expect(cssResp.headers.contentType?.mimeType, 'text/css');
        expect(await utf8.decoder.bind(cssResp).join(), 'body { color: blue; }');

        final imgResp = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port/assets/assets/logo.png'))).close();
        expect(imgResp.statusCode, 200);
        expect(imgResp.headers.contentType?.mimeType, 'image/png');

        await localServer.stop();
      },
    );

    test('a second capture of the same page atomically replaces the first — no leftover files from v1', () async {
      await service.captureAndSave(
        parishId: 'witosa',
        userId: '9001',
        pageUrl: onlineBaseUrl.resolve('/public/dashboard.php'),
        renderedHtml: await fetchOnline('/public/dashboard.php'),
      );

      await service.captureAndSave(
        parishId: 'witosa',
        userId: '9001',
        pageUrl: onlineBaseUrl.resolve('/public/dashboard.php'),
        renderedHtml: '<html><body><p>Dashboard v2, no stylesheet or image at all</p></body></html>',
      );

      final dir = await store.getPageDirectoryIfReady(parishId: 'witosa', userId: '9001', pagePath: '/public/dashboard.php');
      expect(await File('${dir!.path}/snapshot.html').readAsString(), contains('Dashboard v2'));
      expect(
        await File('${dir.path}/assets/assets/style.css').exists(),
        isFalse,
        reason: 'v1 had a stylesheet, v2 has none at all — it must be gone, not left over from the previous capture',
      );
    });

    test('isolation holds through the full chain: capturing for one user never touches another', () async {
      final html = await fetchOnline('/public/dashboard.php');

      await service.captureAndSave(
        parishId: 'witosa',
        userId: 'admin-1',
        pageUrl: onlineBaseUrl.resolve('/public/dashboard.php'),
        renderedHtml: html,
      );

      final otherUserDir = await store.getPageDirectoryIfReady(
        parishId: 'witosa',
        userId: 'ministrant-5',
        pagePath: '/public/dashboard.php',
      );
      expect(otherUserDir, isNull, reason: 'capturing for admin-1 must never create anything visible under a different user_id');
    });
  });
}
