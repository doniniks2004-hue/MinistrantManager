import 'dart:async';

import 'package:flutter/services.dart';

enum NetworkTransport { wifi, cellular, ethernet, other, none }

/// What the operating system says about the device's connection. This is a
/// statement about the INTERFACE, never about the parish server: a Wi-Fi that
/// is up says nothing about whether the server answers.
class NetworkState {
  const NetworkState({
    required this.hasInterface,
    this.validated,
    this.transport = NetworkTransport.other,
  });

  /// There is a default network the system considers usable for the internet.
  final bool hasInterface;

  /// The system's own check that this network really reaches the internet
  /// (Android's NET_CAPABILITY_VALIDATED). null: the platform does not say
  /// (iOS), so "validated" is never assumed.
  final bool? validated;

  final NetworkTransport transport;

  static NetworkState? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final hasInterface = raw['hasInterface'];
    if (hasInterface is! bool) return null;
    final validated = raw['validated'];
    return NetworkState(
      hasInterface: hasInterface,
      validated: validated is bool ? validated : null,
      transport: switch (raw['transport']) {
        'wifi' => NetworkTransport.wifi,
        'cellular' => NetworkTransport.cellular,
        'ethernet' => NetworkTransport.ethernet,
        'none' => NetworkTransport.none,
        _ => NetworkTransport.other,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NetworkState &&
      other.hasInterface == hasInterface &&
      other.validated == validated &&
      other.transport == transport;

  @override
  int get hashCode => Object.hash(hasInterface, validated, transport);

  @override
  String toString() =>
      'NetworkState(interface: $hasInterface, validated: $validated, $transport)';
}

/// The one thing the native platforms provide: changes of the connection, as
/// they happen. All decisions about them are made in Dart
/// (see ConnectivityMonitor), identically on every platform.
abstract class NetworkSignal {
  Stream<NetworkState> get changes;

  /// The current state, or null when the platform cannot say.
  Future<NetworkState?> current();
}

/// Android (ConnectivityManager) and iOS (NWPathMonitor) through platform
/// channels. Where the native side is absent (tests, an unsupported platform)
/// it simply never reports anything, and the app falls back to checking the
/// server itself.
class PlatformNetworkSignal implements NetworkSignal {
  PlatformNetworkSignal({EventChannel? events, MethodChannel? methods})
    : _events = events ?? const EventChannel(eventsChannelName),
      _methods = methods ?? const MethodChannel(methodChannelName);

  static const eventsChannelName = 'eu.ministrant.manager/network/events';
  static const methodChannelName = 'eu.ministrant.manager/network';

  final EventChannel _events;
  final MethodChannel _methods;

  @override
  Stream<NetworkState> get changes => _events
      .receiveBroadcastStream()
      .map(NetworkState.tryParse)
      .where((state) => state != null)
      .cast<NetworkState>()
      // A missing or failing native side must not become an unhandled error.
      .handleError((Object _) {});

  @override
  Future<NetworkState?> current() async {
    try {
      return NetworkState.tryParse(await _methods.invokeMethod<Object?>('current'));
    } catch (_) {
      return null;
    }
  }
}

/// A platform with no native signal.
class NoNetworkSignal implements NetworkSignal {
  const NoNetworkSignal();

  @override
  Stream<NetworkState> get changes => const Stream<NetworkState>.empty();

  @override
  Future<NetworkState?> current() async => null;
}
