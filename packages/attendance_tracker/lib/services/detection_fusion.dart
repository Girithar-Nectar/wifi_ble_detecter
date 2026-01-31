import 'package:geolocator/geolocator.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/attendance_config.dart';

class DetectionResult {
  final bool isInZone;
  final bool byGps;
  final bool byWifi;
  final bool byBle;
  final double? distance;

  DetectionResult({required this.isInZone, this.byGps = false, this.byWifi = false, this.byBle = false, this.distance});
}

class DetectionFusion {
  static Future<DetectionResult> performScan(AttendanceConfig config) async {
    bool byGps = false;
    bool byWifi = false;
    bool byBle = false;
    double? currentDistance;

    // 1. GPS Check (Macro)
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      currentDistance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        config.officeLatitude,
        config.officeLongitude,
      );
      if (currentDistance <= config.geofenceRadius) {
        byGps = true;
      }
    } catch (e) {
      // Log error but continue with other detection methods
    }

    // 2. Wi-Fi Check (Micro)
    if (config.wifiSSIDs.isNotEmpty) {
      try {
        final canScan = await WiFiScan.instance.canStartScan();
        if (canScan == CanStartScan.yes) {
          await WiFiScan.instance.startScan();
          final results = await WiFiScan.instance.getScannedResults();
          for (var result in results) {
            if (config.wifiSSIDs.contains(result.ssid)) {
              byWifi = true;
              break;
            }
          }
        }
      } catch (e) {
        // Log error
      }
    }

    // 3. BLE Check (Micro)
    if (config.bleDeviceNames.isNotEmpty) {
      try {
        // Note: FlutterBluePlus.startScan might be resource-heavy for periodic background
        // We do a short 5-second burst scan
        await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
        await for (final results in FlutterBluePlus.scanResults) {
          for (var r in results) {
            if (config.bleDeviceNames.contains(r.device.platformName)) {
              byBle = true;
              break;
            }
          }
          if (byBle) break;
        }
      } catch (e) {
        // Log error
      }
    }

    // Fusion Logic
    bool inZone = byGps || byWifi || byBle;

    return DetectionResult(isInZone: inZone, byGps: byGps, byWifi: byWifi, byBle: byBle, distance: currentDistance);
  }
}
