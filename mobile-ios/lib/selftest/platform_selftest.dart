import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/offline/local_snapshot_server.dart';
import '../core/offline/snapshot_crypto_vector.dart';
import '../core/offline/snapshot_encryptor.dart';
import '../core/offline/snapshot_store.dart';
import 'selftest_report.dart';

/// Runs, on the platform the app is running on, what a unit test can only
/// pretend: the real native AES-GCM against an answer computed by OpenSSL, an
/// encrypted saved page written and read back, the loopback HTTP server over a
/// real socket, and its recovery. The WebView part needs a widget and lives in
/// main_selftest.dart.
///
/// This is a test harness, not a feature of the app: it has its own entry point
/// and nothing in the app calls it.
class PlatformSelfTest {
  PlatformSelfTest({required this.workDirectory});

  /// Where the saved page is kept between runs (a "cold" run reads it back).
  final Directory workDirectory;

  /// A fixed key: this is a test of the machinery, not of key storage, and the
  /// saved page has to be readable by the next process.
  static const hexKey = '5e1f5e1f5e1f5e1f5e1f5e1f5e1f5e1f5e1f5e1f5e1f5e1f5e1f5e1f5e1f5e1f';
  static const parishId = 'selftest';
  static const userId = '1';
  static const pagePath = '/public/dashboard.php';

  late final SnapshotEncryptor encryptor = SnapshotEncryptor(hexKey: hexKey);
  late final SnapshotStore store = SnapshotStore(
    encryptor: encryptor,
    rootOverride: Directory('${workDirectory.path}/store'),
  );

  // ---- the page being saved: the sizes of one real dashboard ------------------

  /// A 1x1 PNG, valid, so that a browser really decodes it.
  static final Uint8List png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  static String _pad(String filler, int bytes) => filler * bytes;

  static final String html = '<!doctype html><html><head><meta charset="utf-8"><title>MM selftest</title>'
      '<link rel="stylesheet" href="/assets/public/css/style.css"></head><body>'
      '<h1 id="h">Ministrant Manager selftest — zażółć gęślą jaźń ✓</h1>'
      '<img id="logo" src="/assets/public/ikona.png" width="64" height="64">'
      '<script src="/assets/public/js/script.js"></script>'
      '<!-- ${_pad('p', 56000)} --></body></html>';

  static final String css = 'body{background:#123456;color:#fff}/* ${_pad('c', 22000)} */';
  static final String js = 'window.__mm_script_ran=true;/* ${_pad('j', 20000)} */';

  Map<String, List<int>> get assets => {
    'public/css/style.css': utf8.encode(css),
    'public/js/script.js': utf8.encode(js),
    'public/ikona.png': png,
  };

  // ---- one check --------------------------------------------------------------

  /// Runs [body]; it returns a detail, or throws to fail. With [informational] a
  /// failure is recorded as an observation instead (see [CheckStatus.info]).
  Future<void> check(
    SelfTestReport report,
    String name,
    Future<String> Function() body, {
    bool informational = false,
    void Function(String line)? log,
  }) async {
    final watch = Stopwatch()..start();
    CheckResult result;
    try {
      final detail = await body();
      result = CheckResult(name, CheckStatus.pass, watch.elapsedMilliseconds, detail);
    } catch (e) {
      result = CheckResult(
        name,
        informational ? CheckStatus.info : CheckStatus.fail,
        watch.elapsedMilliseconds,
        '${e.runtimeType}: $e',
      );
    }
    report.add(result);
    log?.call('MM_SELFTEST ${jsonEncode(result.toJson())}');
  }

  /// A check whose result is a MEASUREMENT or an observation, never a verdict.
  void note(SelfTestReport report, String name, int ms, String detail, {void Function(String line)? log}) {
    final result = CheckResult(name, CheckStatus.info, ms, detail);
    report.add(result);
    log?.call('MM_SELFTEST ${jsonEncode(result.toJson())}');
  }

  static Uint8List random(int n, [int seed = 11]) {
    final r = Random(seed);
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  static bool same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---- the checks that need no widget -----------------------------------------

  /// Everything except the WebView. Leaves [server] running on the saved page,
  /// for the WebView checks to use; the caller stops it.
  Future<LocalSnapshotServer> runCore(SelfTestReport report, {void Function(String line)? log}) async {
    final onDevice = Platform.isIOS || Platform.isAndroid;

    await check(report, 'platform', () async => '${Platform.operatingSystem} ${Platform.operatingSystemVersion}', log: log);

    await check(report, 'crypto.platform_verified', () async {
      final usable = await SnapshotEncryptor.verifyPlatform();
      // On a phone a platform that cannot reproduce the OpenSSL answer is a
      // failure. On a host with no platform side it is an observation (the check
      // is informational there), recorded as such rather than as a pass.
      if (!usable) throw StateError(SnapshotEncryptor.platformStatus);
      return SnapshotEncryptor.platformStatus;
    }, informational: !onDevice, log: log);

    await check(report, 'crypto.openssl_vector_dart_opens', () async {
      // The OpenSSL answer was sealed with the VECTOR's own key. This harness's
      // [encryptor] has a different key (the one the saved page uses), and with it
      // the tag rightly fails to verify: opening the vector with [encryptor] was
      // the harness's own mistake, and an InvalidCipherTextException was the
      // integrity check doing its job.
      final vectorEncryptor = SnapshotEncryptor(hexKey: snapshotVectorKeyHex);
      final opened = vectorEncryptor.decryptBytes(snapshotVectorBytes(snapshotVectorSealedHex));
      if (!same(opened, snapshotVectorBytes(snapshotVectorPlainHex))) throw StateError('Dart did not open the OpenSSL bytes');
      return 'Dart opens what OpenSSL sealed (with the vector key)';
    }, log: log);

    await check(report, 'crypto.openssl_vector_refused_under_another_key', () async {
      try {
        encryptor.decryptBytes(snapshotVectorBytes(snapshotVectorSealedHex));
      } catch (_) {
        return 'the same bytes under a different key are refused (the tag does not verify)';
      }
      throw StateError('the OpenSSL bytes were accepted under a key they were not sealed with');
    }, log: log);

    await check(report, 'crypto.interop_dart_and_platform', () async {
      if (!await SnapshotEncryptor.verifyPlatform()) throw StateError('no verified platform AES-GCM on this machine');
      final plain = random(158 * 1024);
      final nativeBefore = SnapshotEncryptor.nativeCalls;
      var watch = Stopwatch()..start();
      final sealedByDart = Uint8List.fromList(encryptor.encryptBytes(plain));
      final dartSealMs = watch.elapsedMilliseconds;
      watch = Stopwatch()..start();
      final openedByPlatform = await encryptor.decryptBytesInBackground(sealedByDart);
      final platformOpenMs = watch.elapsedMilliseconds;
      watch = Stopwatch()..start();
      final sealedByPlatform = await encryptor.encryptBytesInBackground(plain);
      final platformSealMs = watch.elapsedMilliseconds;
      watch = Stopwatch()..start();
      final openedByDart = encryptor.decryptBytes(sealedByPlatform);
      final dartOpenMs = watch.elapsedMilliseconds;

      if (SnapshotEncryptor.nativeCalls - nativeBefore < 2) throw StateError('the platform was not actually used');
      if (!same(openedByPlatform, plain)) throw StateError('the platform did not open what Dart sealed');
      if (!same(openedByDart, plain)) throw StateError('Dart did not open what the platform sealed');
      return '158 KB both ways: Dart seal ${dartSealMs}ms -> platform open ${platformOpenMs}ms; '
          'platform seal ${platformSealMs}ms -> Dart open ${dartOpenMs}ms';
    }, informational: !onDevice, log: log);

    await check(report, 'crypto.tampered_payload_refused', () async {
      final sealed = Uint8List.fromList(encryptor.encryptBytes(random(5000)))..[100] ^= 0xff;
      try {
        await encryptor.decryptBytesInBackground(sealed);
      } catch (_) {
        return 'a changed byte is refused';
      }
      throw StateError('a tampered payload was accepted');
    }, log: log);

    await check(report, 'store.encrypted_roundtrip', () async {
      final watch = Stopwatch()..start();
      await store.writeSnapshot(
        parishId: parishId,
        userId: userId,
        pagePath: pagePath,
        html: html,
        assets: assets,
      );
      final dir = await store.getPageDirectoryIfReady(parishId: parishId, userId: userId, pagePath: pagePath);
      if (dir == null) throw StateError('the page that was just written cannot be found');
      final page = File('${dir.path}/snapshot.html').readAsBytesSync();
      if (latin1.decode(page).contains('selftest')) throw StateError('the page is stored in plain text');
      if (encryptor.isPublicFormat(page)) throw StateError('the page is stored as a public resource');
      final css = File('${dir.path}/assets/public/css/style.css').readAsBytesSync();
      if (!encryptor.isPublicFormat(css)) throw StateError('a public resource is not authenticated');
      return 'written and found in ${watch.elapsedMilliseconds}ms; page encrypted, stylesheet authenticated';
    }, log: log);

    final server = LocalSnapshotServer(encryptor: encryptor);
    final lines = <String>[];
    server.trace = lines.add;

    await check(report, 'server.loopback_http', () async {
      await server.start();
      final dir = await store.getPageDirectoryIfReady(parishId: parishId, userId: userId, pagePath: pagePath);
      server.rootDirectory = dir;
      final client = HttpClient();
      try {
        Future<(int, List<int>, HttpHeaders)> get(String path) async {
          final response = await (await client.getUrl(server.urlFor(path))).close();
          final body = await response.fold<List<int>>([], (a, b) => a..addAll(b));
          return (response.statusCode, body, response.headers);
        }

        final watch = Stopwatch()..start();
        final page = await get('/snapshot.html');
        final style = await get('/assets/public/css/style.css');
        final script = await get('/assets/public/js/script.js');
        final logo = await get('/assets/public/ikona.png');
        final firstMs = watch.elapsedMilliseconds;
        for (final r in [page, style, script, logo]) {
          if (r.$1 != 200) throw StateError('a resource answered ${r.$1}');
        }
        if (!same(style.$2, utf8.encode(css))) throw StateError('the stylesheet came back different');
        if (!same(script.$2, utf8.encode(js))) throw StateError('the script came back different');
        if (!same(logo.$2, png)) throw StateError('the logo came back different');
        // The page's own /assets/ references must have been rewritten to the
        // server's access token, or the browser would ask the wrong address.
        final token = server.urlFor('/x').pathSegments.first;
        final served = utf8.decode(page.$2);
        if (!served.contains('/$token/assets/public/css/style.css') || !served.contains('/$token/assets/public/ikona.png')) {
          throw StateError('the page does not point at the server\'s own address for its resources');
        }

        final wrongToken = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/wrong-token/snapshot.html'))).close();
        await wrongToken.drain<void>();
        if (wrongToken.statusCode != 404) throw StateError('a wrong token answered ${wrongToken.statusCode}');
        final post = await (await client.postUrl(server.urlFor('/snapshot.html'))).close();
        await post.drain<void>();
        if (post.statusCode != 405) throw StateError('POST answered ${post.statusCode}');
        return 'four resources over 127.0.0.1 in ${firstMs}ms, byte-exact; wrong token 404; POST 405';
      } finally {
        client.close(force: true);
      }
    }, log: log);

    await check(report, 'server.security_headers', () async {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(server.urlFor('/snapshot.html'))).close();
        await response.drain<void>();
        final csp = response.headers.value('content-security-policy') ?? '';
        if (!csp.contains("connect-src 'none'")) throw StateError("no connect-src 'none' in the policy: $csp");
        if (!csp.contains("form-action 'none'")) throw StateError("no form-action 'none' in the policy");
        if (response.headers.value('x-content-type-options') != 'nosniff') throw StateError('no nosniff');
        if (response.headers.value('referrer-policy') != 'no-referrer') throw StateError('no no-referrer');
        return "CSP connect-src 'none' + form-action 'none', nosniff, no-referrer";
      } finally {
        client.close(force: true);
      }
    }, log: log);

    await check(report, 'server.second_request_from_memory', () async {
      lines.clear();
      final client = HttpClient();
      try {
        await (await (await client.getUrl(server.urlFor('/snapshot.html'))).close()).drain<void>();
      } finally {
        client.close(force: true);
      }
      if (!lines.any((l) => l.contains('snapshot.html') && l.contains('memory'))) {
        throw StateError('not served from memory: $lines');
      }
      return 'the page is served from memory the second time';
    }, log: log);

    await check(report, 'server.listener_recovery', () async {
      final watch = Stopwatch()..start();
      await server.debugKillListenerForTest();
      final port = await server.ensureHealthy();
      final repairMs = watch.elapsedMilliseconds;
      server.rootDirectory = await store.getPageDirectoryIfReady(parishId: parishId, userId: userId, pagePath: pagePath);
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(server.urlFor('/snapshot.html'))).close();
        await response.drain<void>();
        if (response.statusCode != 200) throw StateError('after the repair the page answered ${response.statusCode}');
      } finally {
        client.close(force: true);
      }
      return 'a closed listener is replaced (port $port) and serves again; repair ${repairMs}ms (must fit in the 1500 ms plan budget)';
    }, log: log);

    await check(report, 'keychain.secure_storage', () async {
      const storage = FlutterSecureStorage(iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock));
      await storage.write(key: 'mm_selftest', value: 'ok');
      final value = await storage.read(key: 'mm_selftest');
      await storage.delete(key: 'mm_selftest');
      if (value != 'ok') throw StateError('read back "$value"');
      return 'write, read and delete work';
    }, informational: true, log: log);

    return server;
  }
}
