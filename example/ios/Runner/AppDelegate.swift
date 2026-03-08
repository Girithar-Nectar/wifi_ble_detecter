import UIKit
import Flutter
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate {
  let locationManager = CLLocationManager()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Enable background fetch with a minimum interval
    application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)

    // Start significant location change monitoring for reliable background wake-ups
    // This is the MOST reliable way to keep iOS background tasks alive
    locationManager.delegate = self
    locationManager.allowsBackgroundLocationUpdates = true
    locationManager.pausesLocationUpdatesAutomatically = false
    locationManager.startMonitoringSignificantLocationChanges()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

// MARK: - CLLocationManagerDelegate for background wake
extension AppDelegate: CLLocationManagerDelegate {
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    // Significant location change detected — the app is woken up
    // flutter_background_service will handle the actual scan
    print("AttendanceTracker: iOS significant location change detected")
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    print("AttendanceTracker: iOS location manager error: \(error.localizedDescription)")
  }
}
