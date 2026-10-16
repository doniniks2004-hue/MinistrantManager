import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/util/loop_lag_monitor.dart';

void main() {
  late List<String> lines;
  late LoopLagMonitor monitor;

  setUp(() {
    lines = [];
    monitor = LoopLagMonitor(log: lines.add);
  });

  Duration ms(int n) => Duration(milliseconds: n);

  test('ticks that arrive on time report nothing', () {
    for (var t = 10; t <= 200; t += 10) {
      monitor.recordTick(ms(t));
    }
    expect(lines, isEmpty);
  });

  test('a stretch in which the isolate was busy is reported with its length and when it ended', () {
    monitor.recordTick(ms(10));
    monitor.recordTick(ms(20));
    monitor.recordTick(ms(260)); // nothing ran for 240 ms, which is 230 ms late
    expect(lines.single, allOf(contains('230 ms'), contains('+260 ms')));
  });

  test('a small delay is not reported (but is remembered as the worst so far)', () {
    monitor.recordTick(ms(10));
    monitor.recordTick(ms(70)); // 50 ms late: under the threshold
    expect(lines, isEmpty);
  });

  test('the worst gap is the one that is summarised', () {
    monitor.recordTick(ms(10));
    monitor.recordTick(ms(150)); // 130 late
    monitor.recordTick(ms(160));
    monitor.recordTick(ms(500)); // 330 late
    monitor.recordTick(ms(510));
    monitor.recordTick(ms(700)); // 180 late
    expect(lines, hasLength(3));
    monitor.start();
    monitor.stop();
    expect(lines.last, allOf(contains('worst gap'), contains('330 ms')));
  });
}
