import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/util/build_info.dart';
import 'package:ministrant_manager/core/util/startup_trace.dart';

void main() {
  setUp(StartupTrace.reset);
  tearDown(StartupTrace.reset);

  group('StartupTrace', () {
    test('records stages in the order reached, with non-decreasing times', () {
      StartupTrace.mark('a');
      StartupTrace.mark('b');
      StartupTrace.mark('c');

      final marks = StartupTrace.marks;
      expect(marks.map((m) => m.$1), ['a', 'b', 'c']);
      expect(marks[1].$2, greaterThanOrEqualTo(marks[0].$2));
      expect(marks[2].$2, greaterThanOrEqualTo(marks[1].$2));
    });

    test('a stage is recorded once: later repeats describe the cold start no more', () {
      StartupTrace.mark('page_ready_online');
      final first = StartupTrace.marks.single.$2;

      StartupTrace.mark('page_ready_online');

      expect(StartupTrace.marks, hasLength(1));
      expect(StartupTrace.marks.single.$2, first);
    });

    test('formats one "stage: N ms" line per stage', () {
      StartupTrace.mark('x');
      StartupTrace.mark('y');

      final lines = StartupTrace.format().split('\n');
      expect(lines, hasLength(2));
      expect(lines[0], matches(RegExp(r'^x: \d+ ms$')));
      expect(lines[1], matches(RegExp(r'^y: \d+ ms$')));
    });

    test('says so when nothing was recorded', () {
      expect(StartupTrace.format(), 'brak danych');
    });

    test('the list handed out cannot be used to rewrite the record', () {
      StartupTrace.mark('a');
      expect(() => StartupTrace.marks.add(('b', 1)), throwsUnsupportedError);
    });
  });

  group('build commit label', () {
    test('a full SHA is shortened to seven characters', () {
      expect(
        buildCommitLabel('2035205f0c6d46011656141c752736abda7f09812'),
        '2035205',
      );
    });

    test('a short value is shown whole', () {
      expect(buildCommitLabel('abc12'), 'abc12');
    });

    test('a build made without a SHA says so instead of showing nothing', () {
      expect(buildCommitLabel(''), 'build lokalny (bez SHA)');
    });
  });
}
