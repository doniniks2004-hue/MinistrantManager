import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/util/startup_trace.dart';
import 'package:ministrant_manager/core/util/ui_marker.dart';

void main() {
  late Directory dir;

  setUp(() async {
    StartupTrace.reset();
    dir = await Directory.systemTemp.createTemp('mm_ui_marker_');
  });

  tearDown(() async => dir.delete(recursive: true));

  test('names the screen and the start-up marks, and nothing else', () async {
    StartupTrace.mark('main');
    await UiMarker.record('activation_screen', directory: dir);

    final data = jsonDecode(File('${dir.path}/mm_ui_marker.json').readAsStringSync()) as Map<String, dynamic>;
    expect(data.keys, unorderedEquals(['screen', 'marks']));
    expect(data['screen'], 'activation_screen');
    expect((data['marks'] as Map).keys, containsAll(['main', 'ui_activation_screen']));
    expect((data['marks'] as Map).values.every((v) => v is int), isTrue, reason: 'names and milliseconds only');
  });

  test('a later screen replaces the earlier one', () async {
    await UiMarker.record('activation_screen', directory: dir);
    await UiMarker.record('home', directory: dir);
    final data = jsonDecode(File('${dir.path}/mm_ui_marker.json').readAsStringSync()) as Map<String, dynamic>;
    expect(data['screen'], 'home');
  });

  test('a folder that cannot be written to never throws into the app', () async {
    await UiMarker.record('activation_screen', directory: Directory('${dir.path}/does/not/exist'));
  });
}
