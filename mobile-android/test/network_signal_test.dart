import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/network/network_signal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const events = EventChannel(PlatformNetworkSignal.eventsChannelName);
  const methods = MethodChannel(PlatformNetworkSignal.methodChannelName);

  tearDown(() {
    messenger.setMockStreamHandler(events, null);
    messenger.setMockMethodCallHandler(methods, null);
  });

  test('states sent by the native side arrive as NetworkState, malformed ones are dropped', () async {
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          sink.success({'hasInterface': false, 'validated': null, 'transport': 'none'});
          sink.success('garbage');
          sink.success({'hasInterface': true, 'validated': false, 'transport': 'wifi'});
          sink.endOfStream();
        },
      ),
    );

    final states = await PlatformNetworkSignal().changes.toList();
    expect(states, [
      const NetworkState(hasInterface: false, transport: NetworkTransport.none),
      const NetworkState(hasInterface: true, validated: false, transport: NetworkTransport.wifi),
    ]);
  });

  test('current() asks the native side', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'current');
      return {'hasInterface': true, 'validated': true, 'transport': 'cellular'};
    });
    expect(
      await PlatformNetworkSignal().current(),
      const NetworkState(hasInterface: true, validated: true, transport: NetworkTransport.cellular),
    );
  });

  test('without a native side, current() is null and listening does not raise an error', () async {
    final signal = PlatformNetworkSignal();
    expect(await signal.current(), isNull);

    final sub = signal.changes.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel(); // an unhandled error here would fail the test
  });

  test('a native side that fails is the same as none', () async {
    messenger.setMockMethodCallHandler(methods, (call) async => throw PlatformException(code: 'x'));
    expect(await PlatformNetworkSignal().current(), isNull);
  });

  test('NoNetworkSignal never reports anything', () async {
    expect(await const NoNetworkSignal().changes.isEmpty, isTrue);
    expect(await const NoNetworkSignal().current(), isNull);
  });
}
