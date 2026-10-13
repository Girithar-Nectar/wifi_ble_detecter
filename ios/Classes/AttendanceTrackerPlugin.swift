import Flutter
import UIKit

public class AttendanceTrackerPlugin: NSObject, FlutterPlugin {
  private static var channels: [FlutterMethodChannel] = []
  private static let checkpointScheme = "attendancetracker"

  private let channel: FlutterMethodChannel
  private let nfc = NfcReader()
  private var engine: AttendanceTrackerEngine { AttendanceTrackerEngine.shared }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    // Normally already done at launch by AttendanceTrackerLoader; harmless twice.
    AttendanceTrackerEngine.bootstrap(launchOptions: nil)
    let channel = FlutterMethodChannel(name: "attendance_tracker", binaryMessenger: registrar.messenger())
    let instance = AttendanceTrackerPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    channels.append(channel)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    Self.channels.removeAll { $0 === channel }
  }

  /// Sends a native event (detection, event, ping, pending checkpoint) to every attached engine.
  static func broadcast(_ method: String, _ arguments: Any?) {
    DispatchQueue.main.async {
      channels.forEach { $0.invokeMethod(method, arguments: arguments) }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "getAndroidSdkInt":
      // iOS doesn't have Android SDK, return nil
      result(nil)
    case "isWifiEnabled":
      result(AttendanceTrackerEngine.isOnWifi())
    case "openWifiSettings":
      openWifiSettings(result: result)
    case "setWifiEnabled":
      // iOS doesn't allow programmatic WiFi toggling
      result(false)
    case "configure":
      engine.configure(args["config"] as? [String: Any] ?? [:])
      result(nil)
    case "setTrackingEnabled":
      engine.setTracking((args["enabled"] as? Bool) ?? false)
      result(nil)
    case "isTrackingEnabled":
      result(engine.store.trackingEnabled)
    case "refreshMonitoring":
      engine.refresh()
      result(nil)
    case "scanNow":
      engine.scan(trigger: args["trigger"] as? String ?? "manual") { result($0) }
    case "appendEvent":
      engine.appendEvent(args["event"] as? [String: Any] ?? [:])
      result(nil)
    case "getEvents":
      result(engine.store.events(pendingOnly: (args["pendingOnly"] as? Bool) ?? true))
    case "acknowledgeEvents":
      engine.acknowledgeEvents(args["ids"] as? [String] ?? [])
      result(nil)
    case "markEventsUploaded":
      engine.markEventsUploaded(args["ids"] as? [String] ?? [])
      result(nil)
    case "recordCheckpoint":
      engine.recordCheckpoint(args["checkpoint"] as? [String: Any] ?? [:]) { result($0) }
    case "getLastCheckpoint":
      result(engine.store.lastCheckpoint)
    case "takePendingCheckpoints":
      result(engine.store.takePendingCheckpoints())
    case "saveLastResult":
      engine.store.lastResult = args["result"] as? [String: Any]
      result(nil)
    case "getLastResult":
      result(engine.store.lastResult)
    case "isNfcAvailable":
      result(NfcReader.isAvailable)
    case "readNfcTag":
      nfc.start(alertMessage: args["alertMessage"] as? String, result: result)
    case "stopNfcSession":
      nfc.stop()
      result(nil)
    case "isIgnoringBatteryOptimizations", "requestIgnoreBatteryOptimizations":
      // No battery optimisation exemption on iOS.
      result(true)
    case "testNotification":
      engine.testNotification()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// `attendancetracker://checkpoint?...` from a QR code opened by the camera.
  /// Requires the scheme in the host's CFBundleURLTypes.
  public func application(
    _ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    guard url.scheme?.lowercased() == Self.checkpointScheme else { return false }
    engine.addPendingCheckpoint(url: url)
    return true
  }

  private func openWifiSettings(result: @escaping FlutterResult) {
    if let url = URL(string: "App-Prefs:root=WIFI") {
      if UIApplication.shared.canOpenURL(url) {
        UIApplication.shared.open(url, options: [:]) { success in
          result(success)
        }
        return
      }
    }
    // Fallback to general settings
    if let url = URL(string: UIApplication.openSettingsURLString) {
      UIApplication.shared.open(url, options: [:]) { success in
        result(success)
      }
    } else {
      result(false)
    }
  }
}
