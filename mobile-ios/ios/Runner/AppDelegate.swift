import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "NetworkSignalPlugin") {
      NetworkSignalPlugin.register(with: registrar)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// Reports changes of the device's network path to Dart. It states what the
/// SYSTEM knows about the connection; it never claims anything about the
/// parish server (a Wi-Fi without internet is a "satisfied" path). `validated`
/// is not provided on iOS and is always null, so it is never assumed.
/// All decisions are made in Dart, identically on iOS and Android.
final class NetworkSignalPlugin: NSObject, FlutterStreamHandler {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "eu.ministrant.manager.network")
  private var sink: FlutterEventSink?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NetworkSignalPlugin()
    FlutterEventChannel(
      name: "eu.ministrant.manager/network/events",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(instance)
    FlutterMethodChannel(
      name: "eu.ministrant.manager/network",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { call, result in
      if call.method == "current" {
        result(instance.snapshot(instance.monitor.currentPath))
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    instance.monitor.pathUpdateHandler = { [weak instance] path in
      // The monitor reports on its own queue; Flutter wants the main one.
      DispatchQueue.main.async {
        guard let instance = instance else { return }
        instance.sink?(instance.snapshot(path))
      }
    }
    instance.monitor.start(queue: instance.queue)
  }

  private func snapshot(_ path: NWPath) -> [String: Any] {
    let transport: String
    if path.status != .satisfied {
      transport = "none"
    } else if path.usesInterfaceType(.wifi) {
      transport = "wifi"
    } else if path.usesInterfaceType(.cellular) {
      transport = "cellular"
    } else if path.usesInterfaceType(.wiredEthernet) {
      transport = "ethernet"
    } else {
      transport = "other"
    }
    return [
      "hasInterface": path.status == .satisfied,
      "validated": NSNull(),
      "transport": transport,
    ]
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
