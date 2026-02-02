import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart' hide ServiceStatus;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import 'services/background_executor.dart';
import 'services/detection_fusion.dart';
import 'models/attendance_config.dart';

export 'models/attendance_config.dart';
export 'services/detection_fusion.dart';

class AttendanceTracker {
  static final AttendanceTracker _instance = AttendanceTracker._internal();
  factory AttendanceTracker() => _instance;
  AttendanceTracker._internal();

  /// Check if all critical permissions (Location, Bluetooth) are granted.
  Future<bool> hasPermissions() async {
    try {
      // Check location permission via Geolocator
      final locStatus = await Geolocator.checkPermission();
      final hasLoc = locStatus == LocationPermission.always || locStatus == LocationPermission.whileInUse;

      // Check notification permission via permission_handler
      final hasNotification = await Permission.notification.isGranted;

      // For Bluetooth, the user wants us to rely on FlutterBluePlus
      // On modern Android, the 'permission' is BLUETOOTH_SCAN/CONNECT
      // FBP usually handles this internally if the manifest is correct,
      // but we'll check Scan permission to be safe.
      final hasBleScan = await Permission.bluetoothScan.isGranted;

      return hasLoc && hasNotification && hasBleScan;
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

      // Request location permission using geolocator
      print('AttendanceTracker: Requesting geolocation permission (GEOLOCATOR)...');
      final locStatus = await Geolocator.requestPermission();
      print('AttendanceTracker: Geolocation status received: $locStatus');

      if (locStatus == LocationPermission.denied || locStatus == LocationPermission.deniedForever) {
        print('AttendanceTracker: Geolocation denied - aborting rest');
        return false;
      }

      // Request Bluetooth runtime permissions first (Android 12+ requirement)
      // This is still needed for FBP to have access to the hardware
      print('AttendanceTracker: Requesting Bluetooth runtime permissions...');
      await [Permission.bluetoothScan, Permission.bluetoothConnect].request();

      // Attempt to turn on Bluetooth hardware
      print('AttendanceTracker: Powering on Bluetooth (FBP)...');
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        print('AttendanceTracker: Bluetooth turnOn() failed: $e');
      }

      // Request notification LAST (may hang on some devices if first)
      print('AttendanceTracker: Requesting notification permission...');
      await Permission.notification.request();

      final hasAll = await hasPermissions();
      print('AttendanceTracker: Permission request sequence finished. All granted: $hasAll');
      return hasAll;
    } catch (e, stack) {
      print('AttendanceTracker: FATAL error requesting permissions: $e');
      print('AttendanceTracker: Stack trace: $stack');
      return false;
    }
  }

  /// Check if all required services (GPS, Wi-Fi, Bluetooth) are enabled hardware-wise.
  Future<ServiceStatus> checkServicesStatus() async {
    final result = await BackgroundExecutor.getLastResult();
    if (result != null) return result.status;

    // Fallback if no last result
    final isGpsEnabled = await Geolocator.isLocationServiceEnabled();
    final wifiBssid = await NetworkInfo().getWifiBSSID();

    // Check BLE with timeout
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

    return ServiceStatus(isGpsEnabled: isGpsEnabled, isWifiEnabled: wifiBssid != null, isBleEnabled: isBleEnabled);
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
