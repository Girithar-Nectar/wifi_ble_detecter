import 'dart:async';
import 'dart:math' as math;
import 'package:wifi_scan/wifi_scan.dart';
import 'package:permission_handler/permission_handler.dart';
import '../global_widgets/config.dart';
import '../models/device_model.dart';
import '../helper/logger.dart';

class WifiService {
  static double _calculateDistance(int rssi) {
    const double a = -40; // Calibrated RSSI at 1 meter for WiFi
    const double n = 2.5; // Path loss exponent for indoor environments
    if (rssi >= AppConfig.minRssi && rssi <= AppConfig.maxRssi && rssi > -80) {
      return math.pow(10, (a - rssi) / (10 * n)).toDouble().clamp(0.1, AppConfig.rangeThreshold);
    }
    return AppConfig.rangeThreshold + 1; // Indicate out of range
  }

  static bool _isInRange(int rssi) {
    return rssi > -65 && rssi <= AppConfig.maxRssi;
  }

  static Future<bool> _checkLocationPermissions() async {
    try {
      final locationStatus = await Permission.locationWhenInUse.status;
      if (locationStatus.isDenied) {
        final newStatus = await Permission.locationWhenInUse.request();
        if (newStatus.isPermanentlyDenied) {
          logger.e('Location permission permanently denied');
          await openAppSettings();
          return false;
        }
        return newStatus.isGranted;
      }
      return locationStatus.isGranted;
    } catch (e) {
      logger.e('Error checking location permissions: $e');
      return false;
    }
  }

  static Future<List<DeviceModel>> scanWifiNetworks() async {
    try {
      if (!await _checkLocationPermissions()) {
        logger.e('Location permissions not granted for WiFi scanning');
        return [];
      }

      final wifiScan = WiFiScan.instance;
      final canGetScannedResults = await wifiScan.canGetScannedResults();
      if (canGetScannedResults != CanGetScannedResults.yes) {
        logger.e('WiFi scanning not supported: $canGetScannedResults');
        return [];
      }

      await wifiScan.startScan();
      await Future.delayed(const Duration(seconds: 5));
      final results = await wifiScan.getScannedResults();
      logger.i('WiFi scan completed. Found ${results.length} networks');
      return results.map((result) {
        final distance = _calculateDistance(result.level);
        final isInRange = _isInRange(result.level);
        return DeviceModel(
          id: result.bssid.toLowerCase(),
          name: result.ssid.isNotEmpty ? result.ssid : 'Unknown Network',
          type: 'wifi',
          distance: distance,
          rssi: result.level,
          ssid: result.ssid,
          macAddress: result.bssid.toLowerCase(),
          lastDetected: DateTime.now(),
          lastSeen: DateTime.now(),
          isInRange: isInRange,
        );
      }).toList();
    } catch (e) {
      logger.e('Error scanning WiFi networks: $e');
      return [];
    }
  }

  static Stream<List<DeviceModel>> startWifiScanning({Duration interval = const Duration(seconds: 20)}) {
    return Stream.periodic(interval, (_) async {
      return await scanWifiNetworks();
    }).asyncMap((future) => future);
  }

  static String getSignalStrengthDescription(int rssi) {
    if (rssi >= -50) return 'Excellent';
    if (rssi >= -60) return 'Good';
    if (rssi >= -65) return 'Fair';
    if (rssi >= -75) return 'Poor';
    return 'Very Poor';
  }

  static String getRangeDescription(double distance) {
    if (distance <= 2) return 'Immediate (< 2m)';
    if (distance <= 5) return 'Very Close (2-5m)';
    if (distance <= AppConfig.rangeThreshold) return 'Close (5-10m)';
    return 'Out of Range (> ${AppConfig.rangeThreshold}m)';
  }
}