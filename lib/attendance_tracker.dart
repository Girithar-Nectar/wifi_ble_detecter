import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart' hide ServiceStatus;
import 'package:wifi_scan/wifi_scan.dart';
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
      final location = await Permission.location.isGranted;
      final locationAlways = await Permission.locationAlways.isGranted;
      final bluetooth = await Permission.bluetoothScan.isGranted;
      final notification = await Permission.notification.isGranted;
      return location && locationAlways && bluetooth && notification;
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

      // Request foreground location first (Android 14 requirement)
      print('AttendanceTracker: Requesting foreground location (PERMISSION_HANDLER)...');
      final locStatus = await Permission.location.request();
      print('AttendanceTracker: Foreground location status received: $locStatus');

      if (locStatus.isDenied || locStatus.isPermanentlyDenied) {
        print('AttendanceTracker: Foreground location denied - aborting rest');
        return false;
      }

      // Only request background location AFTER foreground is granted (Android 14)
      if (locStatus.isGranted) {
        print('AttendanceTracker: Requesting background location...');
        final bgStatus = await Permission.locationAlways.request();
        print('AttendanceTracker: Background location status: $bgStatus');
      }

      // Request Bluetooth group
      print('AttendanceTracker: Requesting Bluetooth permissions...');
      await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
      ].request();

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
    return ServiceStatus(
      isGpsEnabled: await Geolocator.isLocationServiceEnabled(),
      isWifiEnabled: (await WiFiScan.instance.canStartScan()) == CanStartScan.yes,
      isBleEnabled:
          await FlutterBluePlus.isSupported && await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on,
    );
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
      isInZone: map['isInZone'],
      byGps: map['byGps'],
      byWifi: map['byWifi'],
      byBle: map['byBle'],
      distance: map['distance'],
      diagnosticLog: map['diagnosticLog'] ?? "",
      status: ServiceStatus(
        isGpsEnabled: map['status']['isGpsEnabled'],
        isWifiEnabled: map['status']['isWifiEnabled'],
        isBleEnabled: map['status']['isBleEnabled'],
      ),
    );
  }
}
