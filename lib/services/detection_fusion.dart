import 'dart:async';
import 'dart:io' show Platform;
import 'package:geolocator/geolocator.dart' hide ServiceStatus;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import '../models/attendance_config.dart';
import '../models/detection_result.dart';
import '../attendance_tracker_platform_interface.dart';

export '../models/detection_result.dart';

class _ScanTaskResult {
  final bool matched;
  final bool enabled;
  final String log;
  final double? distance;
  final Position? position;
  final String? bssid;
  final String? ssid;
  final String? device;
  final String? beacon;
  final bool byBeacon;

  _ScanTaskResult({
    required this.matched,
    required this.enabled,
    required this.log,
    this.distance,
    this.position,
    this.bssid,
    this.ssid,
    this.device,
    this.beacon,
    this.byBeacon = false,
  });
}

/// A parsed iBeacon advertisement or config entry.
class IBeaconId {
  final String uuid;
  final int? major;
  final int? minor;

  const IBeaconId(this.uuid, [this.major, this.minor]);

  /// Parses "UUID", "UUID:major" or "UUID:major:minor".
  static IBeaconId? parse(String value) {
    final parts = value.trim().split(':');
    final uuid = parts.first.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(uuid)) return null;
    return IBeaconId(
      uuid,
      parts.length > 1 ? int.tryParse(parts[1]) : null,
      parts.length > 2 ? int.tryParse(parts[2]) : null,
    );
  }

  /// Reads an iBeacon from Apple (0x004C) manufacturer data, without the company id.
  static IBeaconId? fromManufacturerData(List<int> data) {
    if (data.length < 22 || data[0] != 0x02 || data[1] != 0x15) return null;
    String hex(int from, int to) => data.sublist(from, to).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final uuid = '${hex(2, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 12)}-${hex(12, 18)}';
    return IBeaconId(uuid, (data[18] << 8) | data[19], (data[20] << 8) | data[21]);
  }

  bool matches(IBeaconId seen) =>
      uuid == seen.uuid && (major == null || major == seen.major) && (minor == null || minor == seen.minor);

  @override
  String toString() => [uuid, if (major != null) major, if (minor != null) minor].join(':');
}

class DetectionFusion {
  static const int _appleCompanyId = 0x004C;

  static String _normalize(String input) => input.replaceAll(':', '').toLowerCase().trim();

  /// Lower-cases a BSSID and pads each octet to two digits; iOS drops leading zeros.
  static String normalizeBssid(String input) =>
      input.trim().toLowerCase().split(':').map((o) => o.padLeft(2, '0')).join(':');

  static Future<DetectionResult> performScan(AttendanceConfig config, {String trigger = DetectionTrigger.timer}) async {
    final startTime = DateTime.now();
    String diagnosticLog = "Scan started at ${startTime.hour}:${startTime.minute}:${startTime.second} ($trigger)\n";

    // 1. GPS Task
    final gpsTask = Future<_ScanTaskResult>(() async {
      bool matched = false;
      bool enabled = false;
      double? distance;
      Position? position;
      String log = "";
      try {
        enabled = await Geolocator.isLocationServiceEnabled().timeout(
          const Duration(seconds: 2),
          onTimeout: () => false,
        );
        if (enabled && config.officePoints.isNotEmpty) {
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

          if (position != null && position.isMocked) {
            log += "GPS: REJECTED - position comes from a mock location app.\n";
          } else if (position != null) {
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
      return _ScanTaskResult(
        matched: matched,
        enabled: enabled,
        log: log,
        distance: distance,
        position: position != null && !position.isMocked ? position : null,
      );
    });

    // 2. Wi-Fi Task
    final wifiTask = Future<_ScanTaskResult>(() async {
      bool matched = false;
      bool enabled = false;
      String log = "";
      String? wifiSsid;
      String? wifiBssid;
      try {
        if (!config.hasWifi) {
          return _ScanTaskResult(matched: false, enabled: false, log: "");
        }

        final info = NetworkInfo();
        wifiSsid = await info.getWifiName().timeout(const Duration(seconds: 2), onTimeout: () => null);
        wifiBssid = await info.getWifiBSSID().timeout(const Duration(seconds: 2), onTimeout: () => null);
        // Android returns this placeholder when location permission or service is missing.
        if (wifiBssid == '02:00:00:00:00:00') wifiBssid = null;

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
          final normBssid = normalizeBssid(wifiBssid);
          final normConfigBssids = config.wifiBSSIDs.map(normalizeBssid).toList();
          String cleanSsid = (wifiSsid ?? "").replaceAll('"', '');
          wifiSsid = cleanSsid.isEmpty ? null : cleanSsid;

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
      return _ScanTaskResult(matched: matched, enabled: enabled, log: log, bssid: wifiBssid, ssid: wifiSsid);
    });

    // 3. BLE Task (named devices, MAC addresses and iBeacons)
    final bleTask = Future<_ScanTaskResult>(() async {
      bool matched = false;
      bool enabled = false;
      bool byBeacon = false;
      String? matchedDevice;
      String? matchedBeacon;
      String log = "";
      try {
        if (!config.hasBle && !config.hasBeacons) {
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
          final configBeacons = config.iBeacons.map(IBeaconId.parse).whereType<IBeaconId>().toList();

          // Android stops delivering unfiltered scans while the screen is off, so when
          // iBeacons are configured every target gets an OS-level filter.
          final useBeaconFilters = configBeacons.isNotEmpty;
          final macFilters = useBeaconFilters
              ? config.bleMACs.where((m) => m.length == 17).map((m) => m.toUpperCase()).toList()
              : const <String>[];
          final nameFilters = useBeaconFilters ? config.bleDeviceNames : const <String>[];

          // Use lowPower mode to save battery; lowLatency only if explicitly needed
          try {
            await FlutterBluePlus.startScan(
              timeout: const Duration(seconds: 5),
              withServices: serviceFilters,
              withRemoteIds: macFilters,
              withNames: nameFilters,
              withMsd: useBeaconFilters ? [MsdFilter(_appleCompanyId, data: [0x02, 0x15])] : const [],
              androidScanMode: AndroidScanMode.lowPower,
              androidUsesFineLocation: true,
            );
          } catch (e) {
            log += "BLE: startScan Error: $e\n";
          }

          log += "BLE: Scan active: ${FlutterBluePlus.isScanningNow}\n";
          final Set<String> seenIds = {};
          final List<ScanResult> distinctResults = [];

          bool checkResult(ScanResult r) {
            final id = r.device.remoteId.str;
            final deviceName = r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName;
            final isMacMatch = normConfigMacs.any((m) => m == _normalize(id));
            final isNameMatch =
                deviceName.isNotEmpty && config.bleDeviceNames.any((n) => _normalize(n) == _normalize(deviceName));
            if (isMacMatch || isNameMatch) {
              matchedDevice = deviceName.isNotEmpty ? deviceName : id;
              log += "BLE: MATCH! $deviceName ($id) RSSI: ${r.rssi}\n";
              return true;
            }
            final apple = r.advertisementData.manufacturerData[_appleCompanyId];
            final seenBeacon = apple != null ? IBeaconId.fromManufacturerData(apple) : null;
            if (seenBeacon != null && configBeacons.any((b) => b.matches(seenBeacon))) {
              byBeacon = true;
              matchedBeacon = seenBeacon.toString();
              log += "BLE: iBeacon MATCH! $seenBeacon RSSI: ${r.rssi}\n";
              return true;
            }
            return false;
          }

          // Listen with early exit: stop scanning as soon as we find a match
          final completer = Completer<void>();
          final subscription = FlutterBluePlus.onScanResults.listen((updatedResults) {
            for (final r in updatedResults) {
              if (seenIds.add(r.device.remoteId.str)) {
                distinctResults.add(r);
                if (!matched && checkResult(r)) {
                  matched = true;
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
              if (checkResult(r)) {
                matched = true;
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
      return _ScanTaskResult(
        matched: matched,
        enabled: enabled,
        log: log,
        device: matchedDevice,
        beacon: matchedBeacon,
        byBeacon: byBeacon,
      );
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
          "FUSION SUCCESS (via ${[if (gpsR.matched) "GPS", if (wifiR.matched) "Wi-Fi", if (bleR.matched) (bleR.byBeacon ? "iBeacon" : "BLE")].join(" + ")}) in ${duration}s\n";
    } else {
      diagnosticLog += "FUSION FAIL: Nothing matched in ${duration}s\n";
    }

    return DetectionResult(
      isInZone: inZone,
      byGps: gpsR.matched,
      byWifi: wifiR.matched,
      byBle: bleR.matched && !bleR.byBeacon,
      byBeacon: bleR.byBeacon,
      distance: gpsR.distance,
      status: ServiceStatus(isGpsEnabled: gpsR.enabled, isWifiEnabled: wifiR.enabled, isBleEnabled: bleR.enabled),
      diagnosticLog: diagnosticLog,
      latitude: gpsR.position?.latitude,
      longitude: gpsR.position?.longitude,
      accuracy: gpsR.position?.accuracy,
      wifiBssid: wifiR.bssid,
      wifiSsid: wifiR.ssid,
      bleDevice: bleR.device,
      beacon: bleR.beacon,
      trigger: trigger,
      timestamp: DateTime.now(),
    );
  }
}
