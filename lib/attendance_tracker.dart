import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart' hide ServiceStatus;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import 'services/background_executor.dart';
import 'services/detection_fusion.dart';
import 'models/attendance_config.dart';
import 'attendance_tracker_platform_interface.dart';

export 'models/attendance_config.dart';
export 'services/detection_fusion.dart';

class AttendanceTracker {
  static final AttendanceTracker _instance = AttendanceTracker._internal();
  factory AttendanceTracker() => _instance;
  AttendanceTracker._internal();

  /// Check if all critical permissions (Location, Bluetooth) are granted.
  Future<bool> hasPermissions() async {
    try {
      final sdkInt = await AttendanceTrackerPlatform.instance.getAndroidSdkInt() ?? 0;

      // Check location permission via Geolocator
      final locStatus = await Geolocator.checkPermission();
      final hasLoc = locStatus == LocationPermission.always || locStatus == LocationPermission.whileInUse;
      // Check Nearby Wi-Fi Devices (Android 13+)
      bool hasNearbyWifi = true;
      if (sdkInt >= 33) {
        hasNearbyWifi = await Permission.nearbyWifiDevices.isGranted;
      }

      // Check Bluetooth permissions (Android 12+)
      bool hasBle = true;
      if (sdkInt >= 31) {
        hasBle = await Permission.bluetoothScan.isGranted && await Permission.bluetoothConnect.isGranted;
      }

      // Check notification permission via permission_handler
      final hasNotification = await Permission.notification.isGranted;

      return hasLoc && hasNotification && hasBle && hasNearbyWifi;
    } catch (e) {
      print('AttendanceTracker: Error checking permissions: $e');
      return false;
    }
  }

  /// Request all necessary permissions and return true if critical ones are granted.
  Future<bool> requestPermissions() async {
    try {
      print('AttendanceTracker: Starting permission REQUEST sequence...');

      // Small delay to let the app settle
      await Future.delayed(const Duration(milliseconds: 500));

      // 0. Get SDK version to know what to request
      final sdkInt = await AttendanceTrackerPlatform.instance.getAndroidSdkInt() ?? 0;
      print('AttendanceTracker: Starting permission sequence for Android API $sdkInt');

      // 1. Request ALL Runtime Permissions in ONE BATCH to prevent UI conflicts
      print('AttendanceTracker: Requesting runtime permission BATCH...');
      final Map<Permission, PermissionStatus> statuses = await [
        Permission.location,
        Permission.notification,
        if (sdkInt >= 31) Permission.bluetoothScan,
        if (sdkInt >= 31) Permission.bluetoothConnect,
        if (sdkInt >= 33) Permission.nearbyWifiDevices,
      ].request();

      print('AttendanceTracker: Batch request finished: $statuses');

      // 2. Wait for system UI to settle completely
      print('AttendanceTracker: Waiting for UI to settle...');
      await Future.delayed(const Duration(milliseconds: 1500));

      // 3. Hardware / Service Level Prompts (Settings Panels)
      print('AttendanceTracker: Checking hardware services...');

      // 3a. GPS (Location Services)
      final locStatus = await Geolocator.checkPermission();
      bool gpsEnabled = await Geolocator.isLocationServiceEnabled();
      if (!gpsEnabled && (locStatus == LocationPermission.always || locStatus == LocationPermission.whileInUse)) {
        print('AttendanceTracker: GPS is OFF but permission GRANTED. Prompting user...');
        gpsEnabled = await ensureLocationServiceEnabled();
      }

      // 3c. Wi-Fi Power
      bool wifiPermissionGranted = sdkInt < 33 || (statuses[Permission.nearbyWifiDevices]?.isGranted ?? false);
      if (wifiPermissionGranted) {
        bool wifiOn = await isWifiEnabled();
        if (!wifiOn) {
          print('AttendanceTracker: Wi-Fi is OFF. Displaying Settings Panel...');
          // Don't even try programmatic toggle as it's unreliable and causes conflicts
          wifiOn = await ensureWifiEnabled();
        }
      }

      // 3b. Bluetooth Power
      bool blePermissionGranted = sdkInt < 31 || (statuses[Permission.bluetoothConnect]?.isGranted ?? false);
      if (blePermissionGranted) {
        print('AttendanceTracker: Attempting to power on Bluetooth...');
        try {
          await FlutterBluePlus.turnOn().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }

      final hasAll = await hasPermissions();
      print('AttendanceTracker: Permission request sequence complete. All granted: $hasAll');
      return hasAll;
    } catch (e, stack) {
      print('AttendanceTracker: FATAL error requesting permissions: $e');
      print('AttendanceTracker: Stack trace: $stack');
      return false;
    }
  }

  /// Attempts to prompt the user to enable Location Services.
  /// Returns the state of the service after the prompt.
  Future<bool> ensureLocationServiceEnabled() async {
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (enabled) return true;

    // Geolocator.openLocationSettings() returns true if it opened the settings
    await Geolocator.openLocationSettings();

    // Give user time to toggle
    await Future.delayed(const Duration(seconds: 2));

    return await Geolocator.isLocationServiceEnabled();
  }

  /// Attempts to prompt the user to enable Wi-Fi hardware.
  Future<bool> ensureWifiEnabled() async {
    bool enabled = await isWifiEnabled();
    if (enabled) return true;

    await openWifiSettings();

    // Give user time to toggle
    await Future.delayed(const Duration(seconds: 2));

    return await isWifiEnabled();
  }

  /// Check if Wi-Fi hardware is enabled.
  Future<bool> isWifiEnabled() async {
    try {
      return await AttendanceTrackerPlatform.instance.isWifiEnabled() ?? false;
    } catch (_) {
      // Fallback: if we can't check, assume true if we have a BSSID or false otherwise
      final wifiBssid = await NetworkInfo().getWifiBSSID();
      return wifiBssid != null;
    }
  }

  /// Programmatically set Wi-Fi state (deprecated and restricted on Android 10+).
  /// Returns true if successful. On Android 10+, this will likely return false.
  Future<bool> setWifiEnabled(bool enabled) async {
    try {
      return await AttendanceTrackerPlatform.instance.setWifiEnabled(enabled) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Open Wi-Fi settings.
  Future<void> openWifiSettings() async {
    try {
      await AttendanceTrackerPlatform.instance.openWifiSettings();
    } catch (_) {}
  }

  /// Check if all required services (GPS, Wi-Fi, Bluetooth) are enabled hardware-wise.
  Future<ServiceStatus> checkServicesStatus() async {
    // 1. GPS
    final isGpsEnabled = await Geolocator.isLocationServiceEnabled();

    // 2. Wi-Fi
    final wifiOn = await isWifiEnabled();

    // 3. BLE with timeout
    bool isBleEnabled = false;
    try {
      if (await FlutterBluePlus.isSupported) {
        final state = await FlutterBluePlus.adapterState.first.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => BluetoothAdapterState.unknown,
        );
        isBleEnabled = state == BluetoothAdapterState.on;
      }
    } catch (_) {}

    return ServiceStatus(isGpsEnabled: isGpsEnabled, isWifiEnabled: wifiOn, isBleEnabled: isBleEnabled);
  }

  /// Initialize the plugin with the provided configuration.
  Future<void> initialize(AttendanceConfig config) async {
    await BackgroundExecutor.initialize(config);
  }

  /// Start tracking attendance.
  Future<void> startTracking() async {
    await BackgroundExecutor.start();
  }

  /// Stop tracking attendance.
  Future<void> stopTracking() async {
    await BackgroundExecutor.stop();
  }

  /// Manually trigger a detection scan immediately.
  Future<void> forceScan() async {
    await BackgroundExecutor.forceScan();
  }

  /// A stream of detection results as they occur in the background.
  Stream<DetectionResult> get onResult {
    return FlutterBackgroundService().on('onUpdate').map((event) {
      return _mapToResult(event!);
    });
  }

  /// Manually trigger a test vibration notification.
  Future<void> testVibration() async {
    FlutterBackgroundService().invoke('testVibration');
  }

  /// Manually check the current status (In-Zone/Out-of-Zone).
  Future<DetectionResult?> getLastResult() async {
    return await BackgroundExecutor.getLastResult();
  }

  Future<bool> isInZone() async {
    final result = await BackgroundExecutor.getLastResult();
    return result?.isInZone ?? false;
  }

  DetectionResult _mapToResult(Map<String, dynamic> map) {
    return DetectionResult(
      isInZone: map['isInZone'] ?? false,
      byGps: map['byGps'] ?? false,
      byWifi: map['byWifi'] ?? false,
      byBle: map['byBle'] ?? false,
      distance: (map['distance'] as num?)?.toDouble(),
      diagnosticLog: map['diagnosticLog'] ?? "",
      status: ServiceStatus(
        isGpsEnabled: map['status']?['isGpsEnabled'] ?? false,
        isWifiEnabled: map['status']?['isWifiEnabled'] ?? false,
        isBleEnabled: map['status']?['isBleEnabled'] ?? false,
      ),
    );
  }
}
