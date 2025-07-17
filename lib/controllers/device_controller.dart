import 'dart:async';
import 'package:get/get.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as blue;
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../global_widgets/config.dart';
import '../helper/logger.dart';
import '../models/device_model.dart';
import '../services/wifi_service.dart';
import '../services/bluetooth_service.dart';
import '../controllers/notification_controller.dart';
import 'dart:io' show Platform;
import 'dart:convert';

class DeviceController extends GetxController {
  final List<String> allowedMacAddresses = [
    '3c:64:cf:a6:2b:d0',
    '3c:64:cf:a6:2b:ce',
    '3c:64:cf:a6:31:6e',
    '3c:64:cf:a6:31:70',
    '3c:64:cf:a5:fc:48',
    '3c:64:cf:a5:fc:46',
  ];

  final RxList<DeviceModel> wifiDevices = <DeviceModel>[].obs;
  final RxList<DeviceModel> bleDevices = <DeviceModel>[].obs;
  final RxString selectedFilter = 'wifi'.obs;
  final RxBool isScanning = false.obs;
  final RxBool isWifiEnabled = false.obs;
  final RxBool isBluetoothEnabled = false.obs;

  StreamSubscription<List<DeviceModel>>? _wifiSubscription;
  StreamSubscription<List<DeviceModel>>? _bluetoothSubscription;
  StreamSubscription<blue.BluetoothAdapterState>? _bluetoothStateSubscription;
  final NotificationController _notificationController = Get.find<NotificationController>();
  final Map<String, bool> _previousRangeState = <String, bool>{};
  Timer? _scanTimer;

  @override
  void onInit() {
    super.onInit();
    _initializeServices();
    _loadStoredDevices();
    _loadFilterPreference();
    startScanning();
    ever(selectedFilter, (_) => _onFilterChanged());
  }

  @override
  void onClose() {
    // stopScanning();
    // _bluetoothStateSubscription?.cancel();
    super.onClose();
  }

  Future<void> _initializeServices() async {
    try {
      final canGet = await WiFiScan.instance.canGetScannedResults();
      isWifiEnabled.value = canGet == CanGetScannedResults.yes;

      await _requestPermissions();
      _bluetoothStateSubscription?.cancel();
      _bluetoothStateSubscription = blue.FlutterBluePlus.adapterState.listen((state) {
        isBluetoothEnabled.value = state == blue.BluetoothAdapterState.on;
        if (!isBluetoothEnabled.value) {
          _notificationController.showStatusNotification(
            'Bluetooth Disabled',
            'Please enable Bluetooth to scan for devices.',
          );
          logger.i('Bluetooth state changed: $state');
        } else {
          logger.i('Bluetooth is on');
          if (isScanning.value) performManualScan();
        }
      }, onError: (e) {
        logger.e('Bluetooth state error: $e');
        _notificationController.showStatusNotification(
          'Bluetooth Error',
          'Failed to monitor Bluetooth state.',
        );
      });
    } catch (e) {
      logger.e('Error initializing services: $e');
      _notificationController.showStatusNotification(
        'Initialization Error',
        'Failed to initialize scanning services.',
      );
    }
  }

  Future<void> _requestPermissions() async {
    try {
      if (Platform.isAndroid) {
        final statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.locationWhenInUse,
        ].request();
        if (statuses.values.any((status) => status.isDenied)) {
          logger.e('Required permissions denied: $statuses');
          _notificationController.showStatusNotification(
            'Permissions Denied',
            'Please grant Bluetooth and location permissions.',
          );
          if (statuses.values.any((status) => status.isPermanentlyDenied)) {
            await openAppSettings();
          }
        }
      } else if (Platform.isIOS) {
        final statuses = await [
          Permission.bluetooth,
          Permission.locationWhenInUse,
        ].request();
        if (statuses.values.any((status) => status.isDenied)) {
          logger.e('Required permissions denied: $statuses');
          _notificationController.showStatusNotification(
            'Permissions Denied',
            'Please grant Bluetooth and location permissions.',
          );
          if (statuses.values.any((status) => status.isPermanentlyDenied)) {
            await openAppSettings();
          }
        }
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        logger.w('Location services are disabled.');
        _notificationController.showStatusNotification(
          'Location Disabled',
          'Please enable location services for accurate scanning.',
        );
      }
    } catch (e) {
      logger.e('Error requesting permissions: $e');
      _notificationController.showStatusNotification(
        'Permission Error',
        'Failed to request permissions.',
      );
    }
  }

  Future<void> _loadStoredDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final storedDevices = prefs.getString('detected_devices');
    if (storedDevices != null) {
      final List<dynamic> jsonList = jsonDecode(storedDevices);
      final devices = jsonList.map((json) => DeviceModel.fromJson(json)).toList();
      final uniqueDevices = <String, DeviceModel>{};
      for (var device in devices) {
        final key = '${device.id}_${device.type}';
        uniqueDevices[key] = device;
      }
      _updateDeviceLists(uniqueDevices.values.toList());
    }
  }

  Future<void> _saveDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final allDevices = [...wifiDevices, ...bleDevices];
    final uniqueDevices = <String, DeviceModel>{};
    for (var device in allDevices) {
      final key = '${device.id}_${device.type}';
      uniqueDevices[key] = device;
    }
    final jsonList = uniqueDevices.values.map((device) => device.toJson()).toList();
    await prefs.setString('detected_devices', jsonEncode(jsonList));
  }

  Future<void> _loadFilterPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final filter = prefs.getString('selected_filter') ?? 'wifi';
    selectedFilter.value = filter == 'wifi' || filter == 'ble_device' ? filter : 'wifi';
    logger.i('Loaded filter preference: ${selectedFilter.value}');
  }

  Future<void> _saveFilterPreference() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_filter', selectedFilter.value);
    logger.i('Saved filter preference: ${selectedFilter.value}');
  }

  void _updateDeviceLists(List<DeviceModel> devices) {
    wifiDevices.value = devices
        .where((d) => d.type == 'wifi' && allowedMacAddresses.contains(d.id.toLowerCase()))
        .toList();
    bleDevices.value = devices
        .where((d) => d.type == 'ble_device' && AppConfig.allowedBleMacAddresses.containsKey(d.id.toLowerCase()))
        .toList();
    wifiDevices.refresh();
    bleDevices.refresh();
  }

  Future<void> startScanning() async {
    if (isScanning.value) return;
    logger.i('Starting scanning');
    isScanning.value = true;

    try {
      await performManualScan();
      _scanTimer = Timer.periodic(Duration(seconds: 8), (timer) async {
        if (!isScanning.value) {
          timer.cancel();
          return;
        }
        await performManualScan();
      });

      if (isWifiEnabled.value) {
        _wifiSubscription?.cancel();
        _wifiSubscription = WifiService.startWifiScanning(interval: Duration(seconds: 8)).listen(
              (devices) => _updateWifiDevices(devices),
          onError: (error) {
            logger.e('WiFi scanning error: $error');
            _notificationController.showStatusNotification(
              'WiFi Scanning Error',
              'Retrying WiFi scan in 8 seconds.',
            );
          },
        );
      }

      if (isBluetoothEnabled.value) {
        // await blue.FlutterBluePlus.stopScan();
        // _bluetoothSubscription?.cancel();
        _bluetoothSubscription = BluetoothService.startBluetoothScanning().listen(
              (devices) => _updateBluetoothDevices(devices),
          onError: (error) {
            logger.e('Bluetooth scanning error: $error');
            _notificationController.showStatusNotification(
              'Bluetooth Scanning Error',
              'Retrying BLE scan in 8 seconds.',
            );
          },
        );
      } else {
        _notificationController.showStatusNotification(
          'Bluetooth Disabled',
          'Please enable Bluetooth to scan for devices.',
        );
      }
    } catch (e) {
      logger.e('Error starting scanning: $e');
      _notificationController.showStatusNotification(
        'Scanning Error',
        'Retrying scan in 8 seconds.',
      );
    }
  }

  void stopScanning() {
    _wifiSubscription?.cancel();
    _bluetoothSubscription?.cancel();
    _scanTimer?.cancel();
    isScanning.value = false;
    blue.FlutterBluePlus.stopScan();
    logger.i('Scanning stopped');
  }

  void _updateWifiDevices(List<DeviceModel> scannedDevices) {
    final currentMacs = scannedDevices.map((d) => d.id.toLowerCase()).toSet();
    final updatedDevices = <DeviceModel>[];

    for (var device in scannedDevices) {
      if (allowedMacAddresses.contains(device.id.toLowerCase())) {
        updatedDevices.add(device.copyWith(lastDetected: DateTime.now()));
      }
    }

    for (var device in wifiDevices) {
      final mac = device.id.toLowerCase();
      if (!currentMacs.contains(mac)) {
        logger.i('WiFi device not detected: ${device.ssid ?? device.name}, removing and notifying');
        if (selectedFilter.value == 'wifi') {
          _notificationController.showDeviceOutOfRangeNotification(
            device.ssid ?? device.name,
            'WiFi',
          );
        }
        final deviceKey = '${device.id}_WiFi';
        _previousRangeState[deviceKey] = false;
      } else if (!updatedDevices.any((d) => d.id.toLowerCase() == mac)) {
        updatedDevices.add(device);
      }
    }

    final uniqueDevices = <String, DeviceModel>{};
    for (var device in updatedDevices) {
      final key = '${device.id}_WiFi';
      uniqueDevices[key] = device;
    }

    wifiDevices.value = uniqueDevices.values.toList();
    if (selectedFilter.value == 'wifi') {
      _checkRangeChanges(wifiDevices, 'WiFi');
    }
    _saveDevices();
    wifiDevices.refresh();
  }

  void _updateBluetoothDevices(List<DeviceModel> scannedDevices) {
    logger.i('BLE devices detected: ${scannedDevices.length}');
    for (var device in scannedDevices) {
      logger.i('Device: ${device.name}, ID: ${device.id}, Type: ${device.type}, RSSI: ${device.rssi}, Distance: ${device.distance}, InRange: ${device.isInRange}');
    }

    final currentMacs = scannedDevices.map((d) => d.id.toLowerCase()).toSet();
    final updatedBleDevices = <DeviceModel>[];

    for (var device in scannedDevices) {
      final mac = device.id.toLowerCase();
      if (device.type == 'ble_device' && AppConfig.allowedBleMacAddresses.containsKey(mac)) {
        updatedBleDevices.add(device.copyWith(
          name: AppConfig.allowedBleMacAddresses[mac]!,
          lastDetected: DateTime.now(),
        ));
      }
    }

    for (var device in bleDevices) {
      final mac = device.id.toLowerCase();
      if (!currentMacs.contains(mac)) {
        logger.i('BLE device not detected: ${device.name}, removing and notifying');
        if (selectedFilter.value == 'ble_device') {
          _notificationController.showDeviceOutOfRangeNotification(
            device.name,
            'BLE Device',
          );
        }
        final deviceKey = '${device.id}_BLE Device';
        _previousRangeState[deviceKey] = false;
      } else if (!updatedBleDevices.any((d) => d.id.toLowerCase() == mac)) {
        updatedBleDevices.add(device);
      }
    }

    final uniqueDevices = <String, DeviceModel>{};
    for (var device in updatedBleDevices) {
      final key = '${device.id}_BLE Device';
      uniqueDevices[key] = device;
    }

    bleDevices.value = uniqueDevices.values.toList();
    if (selectedFilter.value == 'ble_device') {
      _checkRangeChanges(bleDevices, 'BLE Device');
    }
    _saveDevices();
    bleDevices.refresh();
  }

  void _checkRangeChanges(List<DeviceModel> devices, String deviceType) {
    if (deviceType != 'WiFi' && deviceType != 'BLE Device') return;

    for (final device in devices) {
      final mac = device.id.toLowerCase();
      if (deviceType == 'WiFi' && !allowedMacAddresses.contains(mac) ||
          deviceType == 'BLE Device' && !AppConfig.allowedBleMacAddresses.containsKey(mac)) {
        continue;
      }

      final deviceKey = '${device.id}_$deviceType';
      final wasInRange = _previousRangeState[deviceKey] ?? false;
      final isInRange = device.isInRange && device.distance != null && device.distance! <= AppConfig.rangeThreshold;

      if (isInRange && !wasInRange) {
        logger.i('Device in range: ${device.ssid ?? device.name} ($deviceType, ${device.distance?.toStringAsFixed(1)}m)');
        _notificationController.showDeviceInRangeNotification(
          device.ssid ?? device.name,
          deviceType,
          device.distance!.toStringAsFixed(1),
        );
      } else if (!isInRange && wasInRange) {
        logger.i('Device out of range: ${device.ssid ?? device.name} ($deviceType)');
        _notificationController.showDeviceOutOfRangeNotification(
          device.ssid ?? device.name,
          deviceType,
        );
      }

      _previousRangeState[deviceKey] = isInRange;
    }
  }

  void _onFilterChanged() {
    logger.i('Filter changed to ${selectedFilter.value}');
    _saveFilterPreference();
    performManualScan();
    wifiDevices.refresh();
    bleDevices.refresh();
    update();
  }

  List<DeviceModel> get allDevices => [...wifiDevices, ...bleDevices];

  List<DeviceModel> get devicesInRange =>
      allDevices.where((device) => device.isInRange && device.distance != null && device.distance! <= AppConfig.rangeThreshold).toList();

  List<DeviceModel> get filteredDevicesInRange =>
      devicesInRange.where((device) => device.type == selectedFilter.value).toList();

  List<DeviceModel> getDevicesByType(String type) {
    switch (type) {
      case 'wifi':
        return wifiDevices;
      case 'ble_device':
        return bleDevices;
      default:
        return [];
    }
  }

  List<DeviceModel> getDevicesInRangeByType(String type) {
    return getDevicesByType(type)
        .where((device) => device.isInRange && device.distance != null && device.distance! <= AppConfig.rangeThreshold)
        .toList();
  }

  void toggleFilter(String type) {
    if (type == 'wifi' || type == 'ble_device') {
      selectedFilter.value = type;
    }
  }

  Future<void> performManualScan() async {
    try {
      if (isWifiEnabled.value && selectedFilter.value == 'wifi') {
        final wifiResults = await WifiService.scanWifiNetworks();
        _updateWifiDevices(wifiResults);
      }

      if (Platform.isAndroid) {
        final statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
        ].request();
        if (statuses.values.every((status) => status.isGranted) &&
            await BluetoothService.isBluetoothEnabled()) {
          isBluetoothEnabled.value = true;
          // await blue.FlutterBluePlus.stopScan();
          if (selectedFilter.value == 'ble_device') {
            final bluetoothResults = await BluetoothService.scanBluetoothDevices();
            _updateBluetoothDevices(bluetoothResults);
          }
        } else {
          isBluetoothEnabled.value = false;
          _notificationController.showStatusNotification(
            'Bluetooth Disabled or Permissions Denied',
            'Please enable Bluetooth and grant permissions.',
          );
        }
      } else if (Platform.isIOS) {
        if (await BluetoothService.isBluetoothEnabled()) {
          isBluetoothEnabled.value = true;
          // await blue.FlutterBluePlus.stopScan();
          if (selectedFilter.value == 'ble_device') {
            final bluetoothResults = await BluetoothService.scanBluetoothDevices();
            _updateBluetoothDevices(bluetoothResults);
          }
        } else {
          isBluetoothEnabled.value = false;
          _notificationController.showStatusNotification(
            'Bluetooth Disabled',
            'Please enable Bluetooth to scan for devices.',
          );
        }
      }
    } catch (e) {
      logger.e('Error performing manual scan: $e');
      _notificationController.showStatusNotification(
        'Scan Error',
        'Failed to scan devices: $e',
      );
    }
  }

  void clearDevices() {
    wifiDevices.clear();
    bleDevices.clear();
    _previousRangeState.clear();
    _saveDevices();
    wifiDevices.refresh();
    bleDevices.refresh();
    update();
  }

  int getDeviceCountByType(String type) => getDevicesByType(type).length;

  int getInRangeDeviceCountByType(String type) => getDevicesInRangeByType(type).length;
}