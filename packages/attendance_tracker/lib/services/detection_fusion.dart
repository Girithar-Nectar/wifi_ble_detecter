import 'package:geolocator/geolocator.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/attendance_config.dart';

class ServiceStatus {
  final bool isGpsEnabled;
  final bool isWifiEnabled;
  final bool isBleEnabled;

  ServiceStatus({required this.isGpsEnabled, required this.isWifiEnabled, required this.isBleEnabled});
}

class DetectionResult {
  final bool isInZone;
  final bool byGps;
  final bool byWifi;
  final bool byBle;
  final double? distance;
  final ServiceStatus status;
  final String diagnosticLog;

  DetectionResult({
    required this.isInZone,
    this.byGps = false,
    this.byWifi = false,
    this.byBle = false,
    this.distance,
    required this.status,
    this.diagnosticLog = "",
  });
}

class DetectionFusion {
  static String _normalize(String input) => input.replaceAll(':', '').toLowerCase().trim();

  static Future<DetectionResult> performScan(AttendanceConfig config) async {
    bool byGps = false;
    bool byWifi = false;
    bool byBle = false;
    double? currentDistance;

    bool isGpsEnabled = false;
    bool isWifiEnabled = false;
    bool isBleEnabled = false;

    String diagnosticLog = "Scan started at ${DateTime.now().hour}:${DateTime.now().minute}:${DateTime.now().second}\n";

    // Pre-normalize config lists
    final normalizedWifiBSSIDs = config.wifiBSSIDs.map(_normalize).toList();
    final normalizedBleMACs = config.bleMACs.map(_normalize).toList();

    // 1. GPS Check (Macro)
    try {
      isGpsEnabled = await Geolocator.isLocationServiceEnabled();
      if (isGpsEnabled) {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
        );

        currentDistance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          config.officeLatitude,
          config.officeLongitude,
        );
        if (currentDistance <= config.geofenceRadius) {
          byGps = true;
          diagnosticLog += "GPS: MATCH (${currentDistance.toStringAsFixed(1)}m)\n";
        } else {
          diagnosticLog += "GPS: NO MATCH (${currentDistance.toStringAsFixed(1)}m)\n";
        }
      } else {
        diagnosticLog += "GPS: Service Disabled\n";
      }
    } catch (e) {
      diagnosticLog += "GPS Error: $e\n";
    }

    // 2. Wi-Fi Check (Micro)
    try {
      if (config.wifiSSIDs.isNotEmpty || config.wifiBSSIDs.isNotEmpty) {
        final canScan = await WiFiScan.instance.canStartScan();
        isWifiEnabled = canScan == CanStartScan.yes;
        if (isWifiEnabled) {
          await WiFiScan.instance.startScan();
          diagnosticLog += "Wi-Fi: Scanning (3s delay)...\n";
          await Future.delayed(const Duration(seconds: 3));

          final results = await WiFiScan.instance.getScannedResults();
          diagnosticLog += "Wi-Fi: Found ${results.length} APs\n";

          for (var result in results) {
            final normBssid = _normalize(result.bssid);
            final ssidMatch = result.ssid.isNotEmpty && config.wifiSSIDs.contains(result.ssid);
            final bssidMatch = result.bssid.isNotEmpty && normalizedWifiBSSIDs.contains(normBssid);

            if (ssidMatch || bssidMatch) {
              byWifi = true;
              diagnosticLog += "Wi-Fi: MATCH! ${result.ssid} ($normBssid)\n";
              break;
            }
          }
          if (!byWifi && results.isNotEmpty) {
            diagnosticLog += "Wi-Fi: No match. Top AP: ${results.first.ssid}\n";
          }
        } else {
          diagnosticLog += "Wi-Fi Fail: $canScan\n";
        }
      }
    } catch (e) {
      diagnosticLog += "Wi-Fi Error: $e\n";
    }

    // 3. BLE Check (Micro)
    try {
      if (config.bleDeviceNames.isNotEmpty || config.bleMACs.isNotEmpty) {
        isBleEnabled =
            await FlutterBluePlus.isSupported && await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
        if (isBleEnabled) {
          diagnosticLog += "BLE: Scanning (5s)...\n";
          await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5), androidUsesFineLocation: true);
          await Future.delayed(const Duration(seconds: 5));

          final results = FlutterBluePlus.lastScanResults;
          diagnosticLog += "BLE: Found ${results.length} devices\n";

          for (var r in results) {
            final normMac = _normalize(r.device.remoteId.str);
            final nameMatch = config.bleDeviceNames.contains(r.device.platformName);
            final macMatch = normalizedBleMACs.contains(normMac);

            if (nameMatch || macMatch) {
              byBle = true;
              diagnosticLog += "BLE: MATCH! ${r.device.platformName} ($normMac)\n";
              break;
            }
          }
          if (!byBle && results.isNotEmpty) {
            diagnosticLog += "BLE: No match. Top device: ${results.first.device.platformName}\n";
          }
        } else {
          diagnosticLog += "BLE: Disabled/Unsupported\n";
        }
      }
    } catch (e) {
      diagnosticLog += "BLE Error: $e\n";
    }

    // Fusion Logic
    bool inZone = byGps || byWifi || byBle;

    return DetectionResult(
      isInZone: inZone,
      byGps: byGps,
      byWifi: byWifi,
      byBle: byBle,
      distance: currentDistance,
      status: ServiceStatus(isGpsEnabled: isGpsEnabled, isWifiEnabled: isWifiEnabled, isBleEnabled: isBleEnabled),
      diagnosticLog: diagnosticLog,
    );
  }
}
