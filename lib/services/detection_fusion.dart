import 'dart:async';
import 'dart:io' show Platform;
import 'package:geolocator/geolocator.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/attendance_config.dart';
import '../attendance_tracker_platform_interface.dart';

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
        enabled = await Geolocator.isLocationServiceEnabled().timeout(
          const Duration(seconds: 2),
          onTimeout: () => false,
        );
        if (enabled && config.officePoints.isNotEmpty) {
          Position? position;

          // Single attempt: High accuracy with reasonable timeout
          try {
            log += "GPS: Attempting fix (8s)...\n";
            position = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.high,
                timeLimit: Duration(seconds: 8),
              ),
            );
            log += "GPS: Fix acquired.\n";
          } catch (e) {
            log += "GPS: Fix timed out ($e).\n";
          }

          // Fallback to Last Known Position (if recent)
          if (position == null) {
            log += "GPS: Trying fallback to last known...\n";
            position = await Geolocator.getLastKnownPosition();
            if (position != null) {
              final age = DateTime.now().difference(position.timestamp);
              if (age.inMinutes < 10) {
                log += "GPS: Using last known fix (${age.inMinutes}m old).\n";
              } else {
                log += "GPS: Last known fix too old (${age.inMinutes}m).\n";
                position = null;
              }
            }
          }

          if (position != null) {
            log += "GPS: Pos (${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)})\n";

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
            log += "GPS Skip: Could not obtain any location fix.\n";
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

        final info = NetworkInfo();
        final wifiSsid = await info.getWifiName().timeout(const Duration(seconds: 2), onTimeout: () => null);
        final wifiBssid = await info.getWifiBSSID().timeout(const Duration(seconds: 2), onTimeout: () => null);

        try {
          enabled =
              await AttendanceTrackerPlatform.instance.isWifiEnabled().timeout(
                const Duration(seconds: 2),
                onTimeout: () => false,
              ) ??
              (wifiBssid != null);
        } catch (_) {
          enabled = wifiBssid != null;
        }

        final locPerm = await Geolocator.checkPermission();
        final wifiPerm = await Permission.nearbyWifiDevices.status;
        log +=
            "Wi-Fi Status: Enabled=$enabled, LocPerm=$locPerm, NearbyWifiPerm=$wifiPerm, SSID=${wifiSsid != null}, BSSID=${wifiBssid != null}\n";

        if (wifiBssid != null) {
          final normBssid = _normalize(wifiBssid);
          final normConfigBssids = config.wifiBSSIDs.map(_normalize).toList();
          String cleanSsid = (wifiSsid ?? "").replaceAll('"', '');

          if ((cleanSsid.isNotEmpty && config.wifiSSIDs.contains(cleanSsid)) || normConfigBssids.contains(normBssid)) {
            matched = true;
            log += "Wi-Fi: MATCH! Connected to $cleanSsid ($wifiBssid)\n";
          } else {
            log += "Wi-Fi: Connected to '$cleanSsid' ($wifiBssid - Not in config)\n";
          }
        } else {
          log += "Wi-Fi Skip: Not connected or hardware OFF.\n";
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

        final adapterState = await FlutterBluePlus.adapterState.first.timeout(
          Duration(seconds: Platform.isIOS ? 3 : 1),
          onTimeout: () => BluetoothAdapterState.unknown,
        );
        final locPerm = await Geolocator.checkPermission();
        final bleScanPerm = await Permission.bluetoothScan.status;
        final bleConnectPerm = await Permission.bluetoothConnect.status;
        final blePerm = await Permission.bluetooth.status;

        bool isSupported = await FlutterBluePlus.isSupported;
        enabled = isSupported && adapterState == BluetoothAdapterState.on;

        // iOS Resilience: If adapter state is unknown/unauthorized but we have permission,
        // it might just be the background isolate taking time to sync.
        if (Platform.isIOS && !enabled && isSupported) {
          if (blePerm == PermissionStatus.granted) {
            log += "BLE: iOS Fallback - Permission GRANTED but adapter is $adapterState. Attempting scan anyway...\n";
            enabled = true;
          }
        }

        log +=
            "BLE Status: Adapter=$adapterState, Supported=$isSupported, LocPerm=$locPerm, ScanPerm=$bleScanPerm, ConnectPerm=$bleConnectPerm, iOSBlePerm=$blePerm\n";

        if (enabled) {
          log += "BLE: Preparing scan...\n";
          try {
            await FlutterBluePlus.stopScan();
          } catch (_) {}

          final List<Guid> serviceFilters = config.bleServiceUuids.map((uuid) => Guid(uuid)).toList();
          final normConfigMacs = config.bleMACs.map(_normalize).toList();

          // Use lowPower mode to save battery; lowLatency only if explicitly needed
          try {
            await FlutterBluePlus.startScan(
              timeout: const Duration(seconds: 5),
              withServices: serviceFilters,
              androidScanMode: AndroidScanMode.lowPower,
              androidUsesFineLocation: true,
            );
          } catch (e) {
            log += "BLE: startScan Error: $e\n";
          }

          log += "BLE: Scan active: ${FlutterBluePlus.isScanningNow}\n";
          final Set<String> seenIds = {};
          final List<ScanResult> distinctResults = [];

          // Listen with early exit: stop scanning as soon as we find a match
          final completer = Completer<void>();
          final subscription = FlutterBluePlus.onScanResults.listen((updatedResults) {
            for (final r in updatedResults) {
              final id = r.device.remoteId.str;
              if (seenIds.add(id)) {
                distinctResults.add(r);

                // Early match check — stop immediately if found
                final normMac = _normalize(id);
                final deviceName = r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName;
                final normName = _normalize(deviceName);
                bool isMacMatch = normConfigMacs.any((m) => m == normMac);
                bool isNameMatch = config.bleDeviceNames.any((n) => _normalize(n) == normName);
                if (isMacMatch || isNameMatch) {
                  matched = true;
                  log += "BLE: MATCH! $deviceName ($id) RSSI: ${r.rssi}\n";
                  if (!completer.isCompleted) completer.complete();
                }
              }
            }
          }, onError: (e) => log += "BLE: Stream Error: $e\n");

          // Wait for either: match found, scan finished, or 6s hard timeout
          await Future.any([
            completer.future,
            Future.doWhile(() async {
              await Future.delayed(const Duration(milliseconds: 500));
              return FlutterBluePlus.isScanningNow;
            }),
            Future.delayed(const Duration(seconds: 6)),
          ]);

          await subscription.cancel();
          try {
            await FlutterBluePlus.stopScan();
          } catch (_) {}

          final results = distinctResults;
          log += "BLE: Found ${results.length} devices total.\n";

          // If no early match, do a final pass on all collected results
          if (!matched) {
            for (var r in results) {
              final rawMac = r.device.remoteId.str;
              final normMac = _normalize(rawMac);
              final deviceName = r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName;
              final normName = _normalize(deviceName);

              bool isMacMatch = normConfigMacs.any((m) => m == normMac);
              bool isNameMatch = config.bleDeviceNames.any((n) => _normalize(n) == normName);

              if (isMacMatch || isNameMatch) {
                matched = true;
                log += "BLE: MATCH! $deviceName ($rawMac) RSSI: ${r.rssi}\n";
                break;
              }
            }
          }

          if (!matched && results.isNotEmpty) {
            log += "BLE: No match. Top 3 seen:\n";
            results.sort((a, b) => b.rssi.compareTo(a.rssi));
            for (var i = 0; i < (results.length < 3 ? results.length : 3); i++) {
              final r = results[i];
              log += "  - ${r.device.remoteId.str} (${r.device.platformName}) [${r.rssi} dBm]\n";
            }
          } else if (!matched) {
            log += "BLE: Zero devices found.\n";
          }
        } else {
          log += "BLE Skip: Bluetooth Adapter is OFF or NOT SUPPORTED\n";
        }
      } catch (e) {
        log += "BLE Error: $e\n";
      }
      return _ScanTaskResult(matched: matched, enabled: enabled, log: log);
    });

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
