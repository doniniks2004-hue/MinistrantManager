import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/util/startup_trace.dart';
import 'package:ministrant_manager/core/util/ui_marker.dart';

void main() {
  late Directory dir;

  setUp(() async {
    StartupTrace.reset();
    UiMarker.debugReset();
    dir = await Directory.systemTemp.createTemp('mm_ui_marker_');
  });

  tearDown(() async => dir.delete(recursive: true));

  test('names the screen and the start-up marks, and nothing else', () async {
    StartupTrace.mark('main');
    await UiMarker.record('activation_screen', directory: dir);

    final data = jsonDecode(File('${dir.path}/mm_ui_marker.json').readAsStringSync()) as Map<String, dynamic>;
    expect(data.keys, unorderedEquals(['screen', 'screens', 'marks']));
    expect(data['screen'], 'activation_screen');
    expect(data['screens'], ['activation_screen']);
    expect((data['marks'] as Map).keys, containsAll(['main', 'ui_activation_screen']));
    expect((data['marks'] as Map).values.every((v) => v is int), isTrue, reason: 'names and milliseconds only');
  });

  test('a later screen is the current one, and the earlier ones are kept in order', () async {
    await UiMarker.record('first_frame', directory: dir);
    await UiMarker.record('activation_screen', directory: dir);
    final data = jsonDecode(File('${dir.path}/mm_ui_marker.json').readAsStringSync()) as Map<String, dynamic>;
    expect(data['screen'], 'activation_screen');
    expect(data['screens'], ['first_frame', 'activation_screen'], reason: 'a CI job must tell "drew a frame, then stopped" from "never drew one"');
  });

  test('an app that drew a frame and then stopped at its error screen says so, with the reason', () async {
    await UiMarker.record('first_frame', directory: dir);
    await UiMarker.record('startup_error', detail: 'PlatformException(Unexpected security result code -34018)', directory: dir);
    final data = jsonDecode(File('${dir.path}/mm_ui_marker.json').readAsStringSync()) as Map<String, dynamic>;
    expect(data['screen'], 'startup_error');
    expect(data['detail'], 'PlatformException(Unexpected security result code -34018)');
    expect(data['screens'], ['first_frame', 'startup_error']);
  });

  test('the detail is cut to safe characters and a safe length, whatever it was given', () async {
    await UiMarker.record(
      'startup_error',
      detail: 'x' * 500 + ' /private/var/mobile/x?token=abc#frag <b>"quoted"</b>\n',
      directory: dir,
    );
    final detail = (jsonDecode(File('${dir.path}/mm_ui_marker.json').readAsStringSync()) as Map<String, dynamic>)['detail'] as String;
    expect(detail.length, lessThanOrEqualTo(120));
    for (final bad in ['/', '?', '#', '<', '>', '"', '=', '\n']) {
      expect(detail, isNot(contains(bad)));
    }
  });

  test('a folder that cannot be written to never throws into the app', () async {
    await UiMarker.record('activation_screen', directory: Directory('${dir.path}/does/not/exist'));
  });

  Map<String, dynamic> read() =>
      jsonDecode(File('${dir.path}/mm_ui_marker.json').readAsStringSync()) as Map<String, dynamic>;

  group('writes that overlap', () {
    test('calls made without await end with the LAST state on disk', () async {
      final writes = <Future<void>>[
        UiMarker.record('first_frame', directory: dir),
        UiMarker.record('activation_screen', directory: dir),
      ];
      await Future.wait(writes);
      expect(read()['screen'], 'activation_screen');
      expect(read()['screens'], ['first_frame', 'activation_screen']);
    });

    test('a slow FIRST write does not finish after, and so overwrite, a later one', () async {
      final release = Completer<void>();
      var first = true;
      UiMarker.debugBeforeWrite = () async {
        if (first) {
          first = false;
          await release.future; // the first write is held back
        }
      };
      final a = UiMarker.record('first_frame', directory: dir);
      final b = UiMarker.record('activation_screen', directory: dir);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(File('${dir.path}/mm_ui_marker.json').existsSync(), isFalse, reason: 'nothing written while the first write is held');
      release.complete();
      await Future.wait([a, b]);
      expect(read()['screen'], 'activation_screen');
    });

    test('a first_frame that arrives AFTER a reached screen does not take its place', () async {
      await UiMarker.record('activation_screen', directory: dir);
      await UiMarker.record('first_frame', directory: dir);
      expect(read()['screen'], 'activation_screen', reason: 'a late first_frame must not move the file back');
      expect(read()['screens'], ['activation_screen', 'first_frame']);
    });

    test('an error screen keeps its detail when first_frame is written after it', () async {
      await UiMarker.record('startup_error', detail: 'TimeoutException', directory: dir);
      await UiMarker.record('first_frame', directory: dir);
      expect(read()['screen'], 'startup_error');
      expect(read()['detail'], 'TimeoutException');
    });

    test('a reader polling the file during many writes never sees a half-written file', () async {
      await UiMarker.record('first_frame', directory: dir);
      var stop = false;
      var bad = 0;
      final reader = () async {
        while (!stop) {
          try {
            jsonDecode(File('${dir.path}/mm_ui_marker.json').readAsStringSync());
          } catch (_) {
            bad++;
          }
          await Future<void>.delayed(Duration.zero);
        }
      }();
      final writes = [for (var i = 0; i < 60; i++) UiMarker.record(i.isEven ? 'first_frame' : 'activation_screen', directory: dir)];
      await Future.wait(writes);
      stop = true;
      await reader;
      expect(bad, 0);
      expect(read()['screen'], 'activation_screen');
      expect(File('${dir.path}/mm_ui_marker.json.tmp').existsSync(), isFalse, reason: 'no temporary file left behind');
    });
  });
}
