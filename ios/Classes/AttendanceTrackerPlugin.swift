import Flutter
import UIKit
import SystemConfiguration
import NetworkExtension

public class AttendanceTrackerPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "attendance_tracker", binaryMessenger: registrar.messenger())
    let instance = AttendanceTrackerPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "getAndroidSdkInt":
      // iOS doesn't have Android SDK, return nil
      result(nil)
    case "isWifiEnabled":
      result(isWifiEnabled())
    case "openWifiSettings":
      openWifiSettings(result: result)
    case "setWifiEnabled":
      // iOS doesn't allow programmatic WiFi toggling
      result(false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
  
  private func isWifiEnabled() -> Bool {
    var zeroAddress = sockaddr_in()
    zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    zeroAddress.sin_family = sa_family_t(AF_INET)
    
    guard let defaultRouteReachability = withUnsafePointer(to: &zeroAddress, {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        SCNetworkReachabilityCreateWithAddress(nil, $0)
      }
    }) else {
      return false
    }
    
    var flags: SCNetworkReachabilityFlags = []
    if !SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags) {
      return false
    }
    
    let isReachable = flags.contains(.reachable)
    let isWWAN = flags.contains(.isWWAN)
    
    return isReachable && !isWWAN
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
