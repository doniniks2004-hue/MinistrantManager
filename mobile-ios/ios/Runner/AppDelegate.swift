import CryptoKit
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
    if let registrar = self.registrar(forPlugin: "SnapshotCryptoPlugin") {
      SnapshotCryptoPlugin.register(with: registrar)
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

/// AES-GCM with the platform's own library (CryptoKit), for the saved pages.
///
/// The same algorithm, key and BYTES as the Dart implementation in
/// SnapshotEncryptor: data = IV (12 bytes) + ciphertext + 16-byte tag, which is
/// exactly CryptoKit's "combined" form, so what one side writes the other reads.
/// Plain Dart does this at ~50 KB per second in a debug build; this takes
/// milliseconds.
///
/// It decides nothing: on any failure (a payload that does not authenticate, a
/// wrong key, a bad argument) it answers with an error code, and Dart, which has
/// the authoritative implementation, does the work and gives the real verdict.
/// Neither the key nor any data is ever put in an error message.
final class SnapshotCryptoPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "eu.ministrant.manager/crypto",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any],
        let key = arguments["key"] as? FlutterStandardTypedData,
        let data = arguments["data"] as? FlutterStandardTypedData,
        key.data.count == 32
      else {
        result(FlutterError(code: "bad_arguments", message: nil, details: nil))
        return
      }
      let symmetricKey = SymmetricKey(data: key.data)
      do {
        switch call.method {
        case "decrypt":
          if data.data.count <= 12 + 16 {
            result(FlutterError(code: "bad_arguments", message: nil, details: nil))
            return
          }
          let box = try AES.GCM.SealedBox(combined: data.data)
          let plain = try AES.GCM.open(box, using: symmetricKey)
          result(FlutterStandardTypedData(bytes: plain))
        case "encrypt":
          guard let iv = arguments["iv"] as? FlutterStandardTypedData, iv.data.count == 12 else {
            result(FlutterError(code: "bad_arguments", message: nil, details: nil))
            return
          }
          let sealed = try AES.GCM.seal(
            data.data, using: symmetricKey, nonce: try AES.GCM.Nonce(data: iv.data))
          guard let combined = sealed.combined else {
            result(FlutterError(code: "crypto_failed", message: nil, details: nil))
            return
          }
          result(FlutterStandardTypedData(bytes: combined))
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        // No detail: never the key, never the data.
        result(FlutterError(code: "crypto_failed", message: nil, details: nil))
      }
    }
  }
}
