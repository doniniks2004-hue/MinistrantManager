import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';

/// Real sizes of one saved dashboard (taken from the parish panel):
/// page ~56 KB, style.css 22 KB, script.js 21 KB, ikona.png 158 KB.
const _dashboard = [56 * 1024, 22327, 20696, 157789];

Uint8List _bytes(int n) {
  final random = Random(7);
  return Uint8List.fromList(List<int>.generate(n, (_) => random.nextInt(256)));
}

void main() {
  final encryptor = SnapshotEncryptor(hexKey: '1' * 64);
  final payloads = [for (final n in _dashboard) _bytes(n)];
  final sealed = [for (final p in payloads) Uint8List.fromList(encryptor.encryptBytes(p))];

  group('the background versions give exactly what the synchronous ones give', () {
    test('decrypt', () async {
      for (var i = 0; i < payloads.length; i++) {
        expect(await encryptor.decryptBytesInBackground(sealed[i]), payloads[i]);
      }
    });

    test('encrypt: same format, round-trips, and never the same bytes twice', () async {
      final a = await encryptor.encryptBytesInBackground(payloads[1]);
      final b = await encryptor.encryptBytesInBackground(payloads[1]);
      expect(a, isNot(b), reason: 'a fresh IV every time');
      expect(encryptor.decryptBytes(a), payloads[1]);
      expect(await encryptor.decryptBytesInBackground(b), payloads[1]);
    });

    test('a tampered payload still throws, in the background too', () async {
      final tampered = Uint8List.fromList(sealed[1])..[40] ^= 0xff;
      await expectLater(encryptor.decryptBytesInBackground(tampered), throwsA(anything));
    });

    test('a payload too short to hold an IV still throws', () async {
      await expectLater(encryptor.decryptBytesInBackground(Uint8List(5)), throwsA(isA<FormatException>()));
    });

    test('small payloads (a manifest) take the cheap path and agree', () async {
      final small = _bytes(300);
      final packed = encryptor.encryptBytes(small);
      expect(await encryptor.decryptBytesInBackground(packed), small);
    });
  });

  group('MEASURED (printed into the CI log; the assertions are loose on purpose)', () {
    test('what one dashboard costs to decrypt, and whether the event loop stays free', () async {
      final sync = Stopwatch()..start();
      var maxSyncGap = 0;
      for (final s in sealed) {
        final one = Stopwatch()..start();
        encryptor.decryptBytes(s);
        maxSyncGap = max(maxSyncGap, one.elapsedMilliseconds);
      }
      final syncMs = sync.elapsedMilliseconds;

      // The same work on other isolates while a timer ticks on this one.
      var ticks = 0;
      var lastTick = Stopwatch()..start();
      var maxTickGap = 0;
      final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
        maxTickGap = max(maxTickGap, lastTick.elapsedMilliseconds);
        lastTick = Stopwatch()..start();
        ticks++;
      });
      final background = Stopwatch()..start();
      await Future.wait([for (final s in sealed) encryptor.decryptBytesInBackground(s)]);
      final backgroundMs = background.elapsedMilliseconds;
      ticker.cancel();

      // ignore: avoid_print
      print(
        'DECRYPT-COST dashboard ${_dashboard.reduce((a, b) => a + b)} B: '
        'synchronous on this isolate = $syncMs ms (longest single file blocked it for $maxSyncGap ms); '
        'on other isolates in parallel = $backgroundMs ms, '
        'with this isolate ticking $ticks times and never idle for more than $maxTickGap ms',
      );

      expect(syncMs, lessThan(120000));
      expect(backgroundMs, lessThan(120000));
      // The point of moving it: this isolate keeps running while the work is
      // done elsewhere. Loose, so a loaded CI machine does not fail it.
      expect(maxTickGap, lessThan(1500));
    });
  });
}
