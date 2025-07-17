import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../global_widgets/config.dart';
import '../models/device_model.dart';
import '../helper/logger.dart';

class BluetoothService {
  static bool _isRequestingPermissions = false;

  static Future<bool> isBluetoothEnabled() async {
    try {
      final adapterState = await FlutterBluePlus.adapterState.first;
      return adapterState == BluetoothAdapterState.on;
    } catch (e) {
      logger.e('Error checking Bluetooth state: $e');
      return false;
    }
  }

  static double _calculateDistance(int rssi) {
    if (rssi >= AppConfig.minRssi && rssi <= AppConfig.maxRssi && rssi > -80) {
      final distance =
      math.pow(10, (AppConfig.txPower - rssi) / (10 * AppConfig.pathLossExponent)).toDouble();
      return distance.clamp(0.1, AppConfig.rangeThreshold);
    }
    return AppConfig.rangeThreshold + 1; // Indicate out of range
  }

  static bool _isInRange(int rssi) {
    return _calculateDistance(rssi) <= AppConfig.rangeThreshold && rssi > -80;
  }

  static Future<bool> _checkBluetoothPermissions() async {
    try {
      final statuses = await Future.wait([
        Permission.bluetoothScan.status,
        Permission.bluetoothConnect.status,
        Permission.locationWhenInUse.status,
      ]);
      final allGranted = statuses.every((status) => status.isGranted);
      logger.i('Bluetooth permissions: $statuses');
      return allGranted;
    } catch (e) {
      logger.e('Error checking Bluetooth permissions: $e');
      return false;
    }
  }

  static Future<bool> _requestBluetoothPermissions() async {
    if (_isRequestingPermissions) return false;
    _isRequestingPermissions = true;

    try {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      final allGranted = statuses.values.every((status) => status.isGranted);
      if (statuses.values.any((status) => status.isPermanentlyDenied)) {
        logger.e('Bluetooth permissions permanently denied.');
        await openAppSettings();
        return await _checkBluetoothPermissions();
      }
      logger.i('Bluetooth permissions after request: $statuses');
      return allGranted;
    } catch (e) {
      logger.e('Error requesting Bluetooth permissions: $e');
      return false;
    } finally {
      _isRequestingPermissions = false;
    }
  }

  static Future<List<DeviceModel>> scanBluetoothDevices() async {
    List<DeviceModel> devices = [];

    if (!await FlutterBluePlus.isSupported) {
      logger.e('Bluetooth not supported on this device');
      return devices;
    }

    if (!await _checkBluetoothPermissions()) {
      if (!await _requestBluetoothPermissions()) {
        logger.e('Bluetooth permissions denied');
        return devices;
      }
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      logger.i('Bluetooth is off. Prompting user.');
      return devices;
    }

    try {
      // await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(
        timeout: AppConfig.scanTimeout,

        androidScanMode: AndroidScanMode.lowLatency, // Changed to lowLatency for better detection
        continuousUpdates: true,
        androidCheckLocationServices: true,
        androidUsesFineLocation: true,
      );

      final subscription = FlutterBluePlus.scanResults.listen((results) {
        for (var result in results) {
          final mac = result.device.remoteId.toString().toLowerCase();
          if (result.rssi == 0 || !AppConfig.allowedBleMacAddresses.containsKey(mac)) {
            continue;
          }

          final deviceName = AppConfig.allowedBleMacAddresses[mac]!;
          final distance = _calculateDistance(result.rssi);
          final isInRange = _isInRange(result.rssi);
          final deviceModel = DeviceModel(
            id: mac,
            name: deviceName,
            type: 'ble_device',
            distance: distance,
            rssi: result.rssi,
            macAddress: mac,
            lastDetected: DateTime.now(),
            lastSeen: DateTime.now(),
            isInRange: isInRange,
            uuid: result.advertisementData.serviceUuids.map((guid) => guid.toString().toLowerCase()).toList(),
          );

          final existingIndex = devices.indexWhere((d) => d.id == mac);
          if (existingIndex >= 0) {
            devices[existingIndex] = deviceModel;
          } else {
            devices.add(deviceModel);
          }
        }
      });

      await Future.delayed(AppConfig.scanTimeout);
      // subscription.cancel();
      // await FlutterBluePlus.stopScan();
      logger.i('BLE scan completed. Found ${devices.length} devices');
    } catch (e) {
      logger.e('Error scanning BLE devices: $e');
    }

    return devices;
  }

  static Stream<List<DeviceModel>> startBluetoothScanning() {
    return Stream.periodic(AppConfig.scanInterval, (_) => null).asyncMap((_) async {
      return await scanBluetoothDevices();
    });
  }

  static String getSignalStrengthDescription(int rssi) {
    if (rssi >= -50) return 'Excellent';
    if (rssi >= -60) return 'Good';
    if (rssi >= -70) return 'Fair';
    if (rssi >= -80) return 'Poor';
    return 'Very Poor';
  }

  static String getRangeDescription(double distance) {
    if (distance <= AppConfig.rangeThreshold) return 'In Range (${distance.toStringAsFixed(1)}m)';
    return 'Out of Range';
  }
}