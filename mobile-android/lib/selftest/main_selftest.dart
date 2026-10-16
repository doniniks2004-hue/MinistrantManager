import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/offline/local_snapshot_server.dart';
import '../core/util/startup_trace.dart';
import 'platform_selftest.dart';
import 'selftest_report.dart';

/// A SEPARATE entry point of the app, for CI and for a person with a device:
///
///   flutter build ios --simulator --debug -t lib/selftest/main_selftest.dart
///
/// It is not the app and the app does not contain a way to start it. It drives
/// the real components (native AES-GCM, the encrypted store, the loopback
/// server, a real WebView on 127.0.0.1) on the platform it runs on and writes
/// what it found to `Documents/mm_selftest/result.json`, so that a CI job reads a
/// file instead of depending on what the platform does with log output.
///
/// The first run in a fresh install is the "full" run and leaves a saved page on
/// disk. Every later run is a "cold" run: a new process opens that page from disk
/// and measures how long it takes until a frame was drawn.
void main() {
  StartupTrace.mark('main');
  runApp(const MaterialApp(home: SelfTestPage()));
}

class SelfTestPage extends StatefulWidget {
  const SelfTestPage({super.key});

  @override
  State<SelfTestPage> createState() => _SelfTestPageState();
}

class _SelfTestPageState extends State<SelfTestPage> {
  late final WebViewController _controller;
  final _messages = StreamController<String>.broadcast();
  final _lines = <String>[];
  String _headline = 'SELFTEST RUNNING';
  SelfTestReport? _report;
  Directory? _dir;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('SelfTest', onMessageReceived: (m) => _messages.add(m.message));
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  @override
  void dispose() {
    _messages.close();
    super.dispose();
  }

  void _log(String line) {
    // ignore: avoid_print
    print(line);
    if (mounted) setState(() => _lines.add(line));
  }

  Future<void> _write(SelfTestReport report) async {
    final dir = _dir;
    if (dir == null) return;
    await File('${dir.path}/result.json').writeAsString(jsonEncode(report.toJson()), flush: true);
  }

  /// Loads [url] and waits until the engine says it finished.
  Future<void> _load(Uri url, {Duration within = const Duration(seconds: 20)}) {
    final finished = Completer<void>();
    String? failure;
    _controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) {
          if (!finished.isCompleted) finished.complete();
        },
        onWebResourceError: (e) {
          failure = '${e.errorCode} ${e.description}';
          if (e.isForMainFrame == true && !finished.isCompleted) {
            finished.completeError(StateError('main frame failed: $failure'));
          }
        },
      ),
    );
    unawaited(_controller.loadRequest(url));
    return finished.future.timeout(within, onTimeout: () => throw StateError('no onPageFinished within ${within.inSeconds}s (last error: $failure)'));
  }

  /// Two animation frames after the page finished: a frame was drawn.
  Future<int> _painted() async {
    final watch = Stopwatch()..start();
    final painted = _messages.stream.firstWhere((m) => m == 'painted');
    await _controller.runJavaScript(
      "requestAnimationFrame(function(){requestAnimationFrame(function(){SelfTest.postMessage('painted')})});",
    );
    await painted.timeout(const Duration(seconds: 10));
    return watch.elapsedMilliseconds;
  }

  Future<Map<String, dynamic>> _inspect() async {
    final raw = await _controller.runJavaScriptReturningResult(
      "JSON.stringify({rs:document.readyState,"
      "imgs:document.images.length,"
      "imgsOk:Array.prototype.filter.call(document.images,function(i){return i.complete&&i.naturalWidth>0}).length,"
      "sheets:document.styleSheets.length,"
      "bg:getComputedStyle(document.body).backgroundColor,"
      "h:(document.getElementById('h')||{}).textContent||'',"
      "script:window.__mm_script_ran===true})",
    );
    var text = raw.toString();
    if (text.startsWith('"')) text = jsonDecode(text) as String;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> _run() async {
    final support = await getApplicationDocumentsDirectory();
    final dir = Directory('${support.path}/mm_selftest')..createSync(recursive: true);
    _dir = dir;
    final seeded = File('${dir.path}/seeded');
    final counterFile = File('${dir.path}/runs');
    final run = (counterFile.existsSync() ? int.tryParse(counterFile.readAsStringSync()) ?? 0 : 0) + 1;
    counterFile.writeAsStringSync('$run');
    final cold = seeded.existsSync();

    final report = SelfTestReport(
      mode: cold ? 'cold' : 'full',
      run: run,
      platform: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );
    setState(() => _report = report);
    await _write(report); // done:false, so a run cut short is not mistaken for a pass

    final test = PlatformSelfTest(workDirectory: dir);
    try {
      if (cold) {
        await _runCold(test, report);
      } else {
        await _runFull(test, report);
        seeded.writeAsStringSync('1');
      }
    } catch (e) {
      report.add(CheckResult('selftest.harness', CheckStatus.fail, 0, '${e.runtimeType}: $e'));
    }
    for (final m in StartupTrace.marks) {
      report.marks[m.$1] = m.$2;
    }
    report.done = true;
    await _write(report);
    // ignore: avoid_print
    print('MM_SELFTEST_DONE ${jsonEncode(report.toJson())}');
    if (mounted) {
      setState(() => _headline = report.ok ? 'SELFTEST PASS (${report.mode} #$run)' : 'SELFTEST FAIL: ${report.failed}');
    }
  }

  Future<void> _runFull(PlatformSelfTest test, SelfTestReport report) async {
    final server = await test.runCore(report, log: _log);
    try {
      final url = server.urlFor('/snapshot.html');

      await test.check(report, 'webview.loads_loopback_http', () async {
        final watch = Stopwatch()..start();
        await _load(url);
        final finishedMs = watch.elapsedMilliseconds;
        final paintedMs = await _painted();
        final page = await _inspect();
        if (page['rs'] != 'complete') throw StateError('readyState ${page['rs']}');
        if (page['imgs'] != 1 || page['imgsOk'] != 1) throw StateError('the logo did not decode (${page['imgsOk']}/${page['imgs']})');
        if ((page['sheets'] as int) < 1) throw StateError('the stylesheet was not applied');
        if (page['bg'] != 'rgb(18, 52, 86)') throw StateError('the stylesheet did not take effect (background ${page['bg']})');
        if (page['script'] != true) throw StateError('the script did not run');
        if (!(page['h'] as String).contains('selftest')) throw StateError('the page text is missing');
        return 'WKWebView / WebView loaded http://127.0.0.1 (ATS exception works): finished ${finishedMs}ms, '
            'a frame drawn ${finishedMs + paintedMs}ms after the request; page, stylesheet, script and logo all in effect';
      }, log: _log);

      await test.check(report, 'webview.csp_blocks_requests', () async {
        final answer = _messages.stream.firstWhere((m) => m.startsWith('csp:'));
        await _controller.runJavaScript(
          "fetch(location.origin + '/' + location.pathname.split('/')[1] + '/snapshot.html')"
          ".then(function(){SelfTest.postMessage('csp:allowed')})"
          ".catch(function(){SelfTest.postMessage('csp:blocked')});",
        );
        final result = await answer.timeout(const Duration(seconds: 10));
        if (result != 'csp:blocked') throw StateError('the saved page could make a request: $result');
        return "a request from the saved page is blocked by connect-src 'none'";
      }, log: _log);

      await test.check(report, 'webview.recovers_after_listener_loss', () async {
        final watch = Stopwatch()..start();
        await server.debugKillListenerForTest();
        await server.ensureHealthy();
        server.rootDirectory = await test.store.getPageDirectoryIfReady(
          parishId: PlatformSelfTest.parishId,
          userId: PlatformSelfTest.userId,
          pagePath: PlatformSelfTest.pagePath,
        );
        await _load(server.urlFor('/snapshot.html'));
        await _painted();
        final page = await _inspect();
        if (page['imgsOk'] != 1 || page['bg'] != 'rgb(18, 52, 86)') throw StateError('the page is incomplete after the repair: $page');
        return 'listener closed, replaced, page drawn again in ${watch.elapsedMilliseconds}ms';
      }, log: _log);
    } finally {
      await server.stop();
    }
  }

  /// The page is on disk from the "full" run; this process opens it with nothing
  /// warm: a new server (an empty memory cache), the store read from disk.
  Future<void> _runCold(PlatformSelfTest test, SelfTestReport report) async {
    final marks = report.marks;
    final watch = Stopwatch()..start();
    final server = LocalSnapshotServer(encryptor: test.encryptor);
    try {
      await test.check(report, 'cold.opens_saved_page_from_disk', () async {
        final dir = await test.store.getPageDirectoryIfReady(
          parishId: PlatformSelfTest.parishId,
          userId: PlatformSelfTest.userId,
          pagePath: PlatformSelfTest.pagePath,
        );
        if (dir == null) throw StateError('the saved page left by the first run is not there');
        marks['page_found_ms'] = watch.elapsedMilliseconds;
        await server.start();
        server.rootDirectory = dir;
        marks['server_ready_ms'] = watch.elapsedMilliseconds;
        final url = server.urlFor('/snapshot.html');
        marks['load_request_ms'] = watch.elapsedMilliseconds;
        await _load(url);
        marks['finished_ms'] = watch.elapsedMilliseconds;
        await _painted();
        marks['painted_ms'] = watch.elapsedMilliseconds;
        final page = await _inspect();
        if (page['rs'] != 'complete' || page['imgsOk'] != 1 || page['bg'] != 'rgb(18, 52, 86)' || page['script'] != true) {
          throw StateError('the page drawn is not the complete one: $page');
        }
        return 'complete page drawn ${marks['painted_ms']}ms after this process began to open it '
            '(found ${marks['page_found_ms']}, server ${marks['server_ready_ms']}, finished ${marks['finished_ms']})';
      }, log: _log);
      test.note(
        report,
        'cold.timing_is_a_measurement_not_a_verdict',
        marks['painted_ms'] ?? -1,
        'on this machine (a CI simulator, not an iPhone), counted from the first line of the open, not from the launch of the process',
        log: _log,
      );
    } finally {
      await server.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      appBar: AppBar(title: Text(_headline)),
      body: Column(
        children: [
          SizedBox(height: 220, child: WebViewWidget(controller: _controller)),
          if (report != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('${report.mode} run ${report.run}: ${report.passed} passed, ${report.failed} failed, ${report.informational} info'),
            ),
          Expanded(
            child: ListView(
              children: [for (final l in _lines.reversed) Text(l, style: const TextStyle(fontSize: 10))],
            ),
          ),
        ],
      ),
    );
  }
}
