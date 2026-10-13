import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/network/network_signal.dart';
import 'package:ministrant_manager/core/offline/connectivity_monitor.dart';

class _Signal implements NetworkSignal {
  final controller = StreamController<NetworkState>.broadcast();
  NetworkState? now;

  @override
  Stream<NetworkState> get changes => controller.stream;

  @override
  Future<NetworkState?> current() async => now;

  void emit(NetworkState state) {
    now = state;
    controller.add(state);
  }
}

const _wifi = NetworkState(hasInterface: true, validated: true, transport: NetworkTransport.wifi);
const _cell = NetworkState(hasInterface: true, validated: true, transport: NetworkTransport.cellular);
const _none = NetworkState(hasInterface: false, transport: NetworkTransport.none);
const _wifiNoInternet = NetworkState(hasInterface: true, validated: false, transport: NetworkTransport.wifi);
const _iosWifi = NetworkState(hasInterface: true, transport: NetworkTransport.wifi); // validated: unknown

void main() {
  late _Signal signal;
  late ConnectivityMonitor monitor;
  late List<ConnectivityEventKind> seen;

  Future<void> ms(WidgetTester tester, int millis) => tester.pump(Duration(milliseconds: millis));

  Future<void> boot(WidgetTester tester, {NetworkState? at}) async {
    signal = _Signal()..now = at;
    monitor = ConnectivityMonitor(signal);
    seen = [];
    monitor.events.listen((e) => seen.add(e.kind));
    monitor.start();
    await ms(tester, 1);
  }

  void networkTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        monitor.dispose();
        await signal.controller.close();
      }
    });
  }

  group('NetworkState', () {
    test('parses what the native side sends', () {
      expect(
        NetworkState.tryParse({'hasInterface': true, 'validated': false, 'transport': 'wifi'}),
        _wifiNoInternet,
      );
      expect(NetworkState.tryParse({'hasInterface': false, 'validated': null, 'transport': 'none'}), _none);
      expect(
        NetworkState.tryParse({'hasInterface': true, 'validated': null, 'transport': 'wifi'}),
        _iosWifi,
      );
    });

    test('malformed messages are ignored, never thrown', () {
      expect(NetworkState.tryParse(null), isNull);
      expect(NetworkState.tryParse('x'), isNull);
      expect(NetworkState.tryParse({'transport': 'wifi'}), isNull);
      expect(NetworkState.tryParse({'hasInterface': 'yes'}), isNull);
      expect(
        NetworkState.tryParse({'hasInterface': true, 'transport': 'satellite'})?.transport,
        NetworkTransport.other,
      );
    });
  });

  group('loss', () {
    networkTest('is reported within the grace period and not before: measured', (tester) async {
      await boot(tester, at: _wifi);
      signal.emit(_none);
      await ms(tester, 200);
      expect(seen, isEmpty, reason: 'still inside the grace period');
      await ms(tester, 100); // 300 ms after the loss
      expect(seen, [ConnectivityEventKind.lost]);
      // The decision costs 250 ms of a 2 s allowance.
      expect(monitor.lossGrace, lessThanOrEqualTo(const Duration(milliseconds: 300)));
    });

    networkTest('a handover (loss, then another network within the grace period) is no outage', (
      tester,
    ) async {
      await boot(tester, at: _wifi);
      signal.emit(_none);
      await ms(tester, 100);
      signal.emit(_cell);
      await ms(tester, 2000);
      expect(seen, isEmpty);
    });

    networkTest('is reported once however many "no network" reports follow', (tester) async {
      await boot(tester, at: _wifi);
      signal.emit(_none);
      await ms(tester, 400);
      signal.emit(const NetworkState(hasInterface: false, transport: NetworkTransport.other));
      await ms(tester, 400);
      expect(seen, [ConnectivityEventKind.lost]);
    });

    networkTest('a device that STARTS without a network is reported after the grace period', (
      tester,
    ) async {
      await boot(tester, at: _none);
      await ms(tester, 300);
      expect(seen, [ConnectivityEventKind.lost]);
    });
  });

  group('return', () {
    networkTest('after a loss it is reported once, as "returned" (meaning: ask the server)', (
      tester,
    ) async {
      await boot(tester, at: _wifi);
      signal.emit(_none);
      await ms(tester, 400);
      signal.emit(_cell);
      await ms(tester, 10);
      expect(seen, [ConnectivityEventKind.lost, ConnectivityEventKind.returned]);

      signal.emit(_wifi); // another change of network, no new loss
      await ms(tester, 2000);
      expect(seen, hasLength(2), reason: 'not reported again for a connection that never left');
    });

    networkTest('a state that did not change reports nothing', (tester) async {
      await boot(tester, at: _wifi);
      signal.emit(_wifi);
      signal.emit(_wifi);
      await ms(tester, 2000);
      expect(seen, isEmpty);
    });
  });

  group('Wi-Fi without internet (Android reports it)', () {
    networkTest('is "doubtful" once, and "returned" once when the system validates it again', (
      tester,
    ) async {
      await boot(tester, at: _wifi);
      signal.emit(_wifiNoInternet);
      await ms(tester, 10);
      signal.emit(_wifiNoInternet);
      await ms(tester, 10);
      expect(seen, [ConnectivityEventKind.doubtful]);

      signal.emit(_wifi);
      await ms(tester, 10);
      expect(seen, [ConnectivityEventKind.doubtful, ConnectivityEventKind.returned]);
    });

    networkTest('where the platform does not say (iOS), nothing is ever assumed doubtful', (
      tester,
    ) async {
      await boot(tester, at: _iosWifi);
      signal.emit(const NetworkState(hasInterface: true, transport: NetworkTransport.cellular));
      await ms(tester, 2000);
      expect(seen, isEmpty);
    });
  });

  group('a connection that flaps', () {
    Future<void> flap(WidgetTester tester, int times) async {
      for (var i = 0; i < times; i++) {
        signal.emit(_none);
        await ms(tester, 300);
        signal.emit(i.isEven ? _cell : _wifi);
        await ms(tester, 10);
      }
    }

    networkTest('is not reported "returned" until it has been quiet', (tester) async {
      await boot(tester, at: _wifi);
      await flap(tester, 4); // 8 changes within the window
      seen.clear();

      signal.emit(_none);
      await ms(tester, 300);
      expect(seen, [ConnectivityEventKind.lost]);
      seen.clear();
      signal.emit(_wifi);
      await ms(tester, 2900);
      expect(seen, isEmpty, reason: 'held while it flaps');

      await ms(tester, 300);
      expect(seen, [ConnectivityEventKind.returned], reason: 'reported once it settled');
    });

    networkTest('a new loss during the hold cancels it', (tester) async {
      await boot(tester, at: _wifi);
      await flap(tester, 4);
      signal.emit(_none);
      await ms(tester, 300);
      signal.emit(_wifi); // held
      await ms(tester, 1000);
      seen.clear();
      signal.emit(_none);
      await ms(tester, 5000);
      expect(seen, isNot(contains(ConnectivityEventKind.returned)));
    });
  });

  networkTest('dispose stops everything and closes the stream', (tester) async {
    await boot(tester, at: _wifi);
    var done = false;
    monitor.events.listen((_) {}, onDone: () => done = true);
    signal.emit(_none);
    monitor.dispose();
    await ms(tester, 1000);
    expect(done, isTrue);
    expect(seen, isEmpty, reason: 'the pending loss was cancelled');
  });
}
