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

class _ScanTaskResult {
  final bool matched;
  final bool enabled;
  final String log;
  final double? distance;

  _ScanTaskResult({required this.matched, required this.enabled, required this.log, this.distance});
}

class DetectionFusion {
  static String _normalize(String input) => input.replaceAll(':', '').toLowerCase().trim();

  static Future<DetectionResult> performScan(AttendanceConfig config) async {
    final startTime = DateTime.now();
    String diagnosticLog = "Scan started at ${startTime.hour}:${startTime.minute}:${startTime.second}\n";

    // 1. GPS Task
    final gpsTask = Future<_ScanTaskResult>(() async {
      bool matched = false;
      bool enabled = false;
      double? distance;
      String log = "";
      try {
        enabled = await Geolocator.isLocationServiceEnabled();
        if (enabled && config.officePoints.isNotEmpty) {
          final position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 5)),
          );

          log += "GPS: Acquired (${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)})\n";

          double? minDistance;
          for (final pointStr in config.officePoints) {
            final point = AttendanceConfig.parseWktPoint(pointStr);
            if (point == null) continue;
            final d = Geolocator.distanceBetween(position.latitude, position.longitude, point.key, point.value);
            if (minDistance == null || d < minDistance) minDistance = d;
          }

          distance = minDistance;
          if (distance != null && distance <= config.geofenceRadius) {
            matched = true;
            log += "GPS: MATCH (${distance.toStringAsFixed(1)}m)\n";
          } else if (distance != null) {
            log += "GPS: NO MATCH (${distance.toStringAsFixed(1)}m from office)\n";
          }
        } else {
          log += "GPS Skip: ${config.officePoints.isEmpty ? "No Config" : "Service OFF"}\n";
        }
      } catch (e) {
        log += "GPS Error: $e\n";
      }
      return _ScanTaskResult(matched: matched, enabled: enabled, log: log, distance: distance);
    });

    // 2. Wi-Fi Task
    final wifiTask = Future<_ScanTaskResult>(() async {
      bool matched = false;
      bool enabled = false;
      String log = "";
      try {
        if (config.wifiSSIDs.isEmpty && config.wifiBSSIDs.isEmpty) {
          return _ScanTaskResult(matched: false, enabled: false, log: "");
        }

        final canScan = await WiFiScan.instance.canStartScan();
        enabled = canScan == CanStartScan.yes;

        if (enabled) {
          await WiFiScan.instance.startScan();
          await Future.delayed(const Duration(seconds: 2));
          final results = await WiFiScan.instance.getScannedResults();
          final normConfigBssids = config.wifiBSSIDs.map(_normalize).toList();

          for (var ap in results) {
            final normBssid = _normalize(ap.bssid);
            if (config.wifiSSIDs.contains(ap.ssid) || normConfigBssids.contains(normBssid)) {
              matched = true;
              log += "Wi-Fi: MATCH! ${ap.ssid}\n";
              break;
            }
          }
          if (!matched) log += "Wi-Fi: NO MATCH (${results.length} APs found)\n";
        } else {
          log += "Wi-Fi Skip: OFF ($canScan)\n";
        }
      } catch (e) {
        log += "Wi-Fi Error: $e\n";
      }
      return _ScanTaskResult(matched: matched, enabled: enabled, log: log);
    });

    // 3. BLE Task
    final bleTask = Future<_ScanTaskResult>(() async {
      bool matched = false;
      bool enabled = false;
      String log = "";
      try {
        if (config.bleDeviceNames.isEmpty && config.bleMACs.isEmpty) {
          return _ScanTaskResult(matched: false, enabled: false, log: "");
        }

        enabled =
            await FlutterBluePlus.isSupported &&
            (await FlutterBluePlus.adapterState.first.timeout(
                  const Duration(seconds: 1),
                  onTimeout: () => BluetoothAdapterState.unknown,
                )) ==
                BluetoothAdapterState.on;

        if (enabled) {
          // Check Location Services (Android Requirement)
          final locOn = await Geolocator.isLocationServiceEnabled();
          if (!locOn) {
            return _ScanTaskResult(
              matched: false,
              enabled: true,
              log: "BLE Skip: Android requires system Location ON for BT scanning to work.\n",
            );
          }

          // Optimized Scan: 5s timeout + Low Latency (Android)
          // 1. Stop any existing scan to avoid "scan already in progress" errors
          try {
            await FlutterBluePlus.stopScan();
          } catch (_) {}

          // 2. Start scan
          await FlutterBluePlus.startScan(
            timeout: const Duration(seconds: 5),
            androidScanMode: AndroidScanMode.lowLatency,
          );

          // 3. WAIT for the scan to actually finish (timeout reached)
          // In FlutterBluePlus 2.x, startScan completes when the scan STARTS.
          await FlutterBluePlus.isScanning
              .where((val) => val == false)
              .first
              .timeout(const Duration(seconds: 7), onTimeout: () => false);

          final results = FlutterBluePlus.lastScanResults;
          final normConfigMacs = config.bleMACs.map(_normalize).toList();

          // Log top detections for debugging
          final topDetections = List<ScanResult>.from(results)..sort((a, b) => b.rssi.compareTo(a.rssi));
          if (topDetections.isNotEmpty) {
            log += "BLE Detections (${results.length}):\n";
            for (var i = 0; i < (topDetections.length < 3 ? topDetections.length : 3); i++) {
              final r = topDetections[i];
              final name = r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName;
              log += "  - $name: ${r.rssi} dBm\n";
            }
          }

          for (var r in results) {
            final normMac = _normalize(r.device.remoteId.str);
            final deviceName = r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName;
            final normName = _normalize(deviceName);

            bool isMatch = false;
            if (config.bleDeviceNames.any((n) => _normalize(n) == normName)) {
              isMatch = true;
            } else if (normConfigMacs.contains(normMac)) {
              isMatch = true;
            }

            if (isMatch) {
              matched = true;
              log += "BLE: MATCH! $deviceName ($normMac) at ${r.rssi} dBm\n";
              break;
            }
          }
          if (!matched) log += "BLE: NO MATCH (${results.length} devices found)\n";
        } else {
          log += "BLE Skip: BT is OFF\n";
        }
      } catch (e) {
        log += "BLE Error: $e\n";
      }
      return _ScanTaskResult(matched: matched, enabled: enabled, log: log);
    });

    // Run parallel
    final results = await Future.wait([gpsTask, wifiTask, bleTask]);
    final gpsR = results[0];
    final wifiR = results[1];
    final bleR = results[2];

    diagnosticLog += "${gpsR.log}${wifiR.log}${bleR.log}";

    bool inZone = gpsR.matched || wifiR.matched || bleR.matched;
    final duration = DateTime.now().difference(startTime).inSeconds;

    if (inZone) {
      diagnosticLog +=
          "FUSION SUCCESS (via ${[if (gpsR.matched) "GPS", if (wifiR.matched) "Wi-Fi", if (bleR.matched) "BLE"].join(" + ")}) in ${duration}s\n";
    } else {
      diagnosticLog += "FUSION FAIL: Nothing matched in ${duration}s\n";
    }

    return DetectionResult(
      isInZone: inZone,
      byGps: gpsR.matched,
      byWifi: wifiR.matched,
      byBle: bleR.matched,
      distance: gpsR.distance,
      status: ServiceStatus(isGpsEnabled: gpsR.enabled, isWifiEnabled: wifiR.enabled, isBleEnabled: bleR.enabled),
      diagnosticLog: diagnosticLog,
    );
  }
}
