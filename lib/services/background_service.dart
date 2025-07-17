import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import '../global_widgets/config.dart';
import '../services/bluetooth_service.dart';
import '../services/wifi_service.dart';
import '../models/device_model.dart';
import '../helper/logger.dart';
import 'dart:convert';
import 'dart:io' show Platform;

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final startTime = DateTime.now();
      logger.i('Background task started: $task at $startTime');
      if (task == 'detectDevices') {
        await _performBackgroundDetection();
      }
      final duration = DateTime.now().difference(startTime).inMilliseconds;
      logger.i('Background task completed in ${duration}ms');
      return true;
    } catch (e, stackTrace) {
      logger.e('Background task error: $e, stackTrace: $stackTrace');
      return false;
    }
  });
}

Future<void> _performBackgroundDetection() async {
  logger.i('Starting background detection for ${Platform.isAndroid ? "Android" : "iOS"}');
  await _initializeBackgroundNotifications();

  final prefs = await SharedPreferences.getInstance();
  final selectedFilter = prefs.getString('selected_filter') ?? 'wifi';
  List<DeviceModel> storedDevices = [];
  try {
    final storedDevicesJson = prefs.getString('detected_devices');
    if (storedDevicesJson != null && storedDevicesJson.isNotEmpty) {
      final List<dynamic> jsonList = jsonDecode(storedDevicesJson);
      storedDevices = jsonList.map((json) => DeviceModel.fromJson(json)).toList();
    }
  } catch (e) {
    logger.e('Error parsing stored devices: $e');
  }

  final notifications = FlutterLocalNotificationsPlugin();
  final Map<String, bool> previousRangeState = {};
  for (var device in storedDevices) {
    previousRangeState['${device.id}_${device.type}'] = device.isInRange;
  }

  List<DeviceModel> updatedDevices = [];
  if (selectedFilter == 'wifi') {
    if (await Permission.locationWhenInUse.isGranted && await Geolocator.isLocationServiceEnabled()) {
      try {
        final wifiDevices = await WifiService.scanWifiNetworks();
        const allowedMacs = [
          '3c:64:cf:a6:2b:d0',
          '3c:64:cf:a6:2b:ce',
          '3c:64:cf:a6:31:6e',
          '3c:64:cf:a6:31:70',
          '3c:64:cf:a5:fc:48',
          '3c:64:cf:a5:fc:46',
        ];
        updatedDevices = wifiDevices.where((d) => allowedMacs.contains(d.id.toLowerCase())).toList();
      } catch (e) {
        logger.w('WiFi scanning failed: $e');
        await prefs.setString('last_scan_error', 'WiFi scan failed: $e');
      }
    } else {
      logger.w('WiFi scanning skipped: Location permissions or services not available');
      await prefs.setString('last_scan_error', 'WiFi scan skipped: Missing location permissions');
    }
  } else if (selectedFilter == 'ble_device') {
    final bluetoothPermissions = Platform.isAndroid
        ? (await Permission.bluetoothScan.isGranted && await Permission.bluetoothConnect.isGranted)
        : await Permission.bluetooth.isGranted;
    if (bluetoothPermissions && await BluetoothService.isBluetoothEnabled()) {
      try {
        final bleDevices = await BluetoothService.scanBluetoothDevices();
        updatedDevices = bleDevices
            .where((d) => AppConfig.allowedBleMacAddresses.containsKey(d.id.toLowerCase()))
            .toList();
      } catch (e) {
        logger.w('BLE scanning failed: $e');
        await prefs.setString('last_scan_error', 'BLE scan failed: $e');
      }
    } else {
      logger.w('BLE scanning skipped: Bluetooth permissions or services not available');
      await prefs.setString('last_scan_error', 'BLE scan skipped: Missing Bluetooth permissions');
    }
  }

  final currentMacs = updatedDevices.map((d) => d.id.toLowerCase()).toSet();
  for (var device in storedDevices) {
    if (device.type == selectedFilter && !currentMacs.contains(device.id.toLowerCase())) {
      if (device.lastDetected != null && DateTime.now().difference(device.lastDetected!).inMinutes < 10) {
        updatedDevices.add(device);
      } else {
        final deviceKey = '${device.id}_${device.type}';
        if (previousRangeState[deviceKey] == true) {
          final notificationId = _generateNotificationId(device.name, device.type == 'wifi' ? 'WiFi' : 'BLE Device');
          await notifications.show(
            notificationId,
            'Device Out of Range',
            '${device.name} (${device.type == 'wifi' ? 'WiFi' : 'BLE Device'}) is no longer nearby',
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'background_detection',
                'Background Device Detection',
                channelDescription: 'Notifications for background device detection',
                importance: Importance.min,
                priority: Priority.min,
                showWhen: true,
                enableVibration: true,
                playSound: true,
                icon: '@mipmap/ic_launcher',
                onlyAlertOnce: true,
              ),
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
              ),
            ),
            payload: 'out_of_range_${device.id}',
          );
          logger.i('Sent out-of-range notification for ${device.name} (ID: $notificationId)');
        }
      }
    }
  }

  for (final device in updatedDevices) {
    final deviceKey = '${device.id}_${device.type}';
    final wasInRange = previousRangeState[deviceKey] ?? false;
    final isInRange = device.isInRange && device.distance != null && device.distance! <= AppConfig.rangeThreshold;

    if (isInRange && !wasInRange && device.type == selectedFilter) {
      final notificationId = _generateNotificationId(device.name, device.type == 'wifi' ? 'WiFi' : 'BLE Device');
      await notifications.show(
        notificationId,
        'Background Detection',
        '${device.name} (${device.type == 'wifi' ? 'WiFi' : 'BLE Device'}) detected at ~${device.distance?.toStringAsFixed(1)}m',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'background_detection',
            'Background Device Detection',
            channelDescription: 'Notifications for background device detection',
            importance: Importance.high,
            priority: Priority.high,
            showWhen: true,
            enableVibration: true,
            playSound: true,
            icon: '@mipmap/ic_launcher',
            onlyAlertOnce: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: 'background_${device.id}',
      );
      logger.i('Sent in-range notification for ${device.name} (ID: $notificationId)');
    } else if (!isInRange && wasInRange && device.type == selectedFilter) {
      final notificationId = _generateNotificationId(device.name, device.type == 'wifi' ? 'WiFi' : 'BLE Device');
      await notifications.show(
        notificationId,
        'Device Out of Range',
        '${device.name} (${device.type == 'wifi' ? 'WiFi' : 'BLE Device'}) is no longer nearby',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'background_detection',
            'Background Device Detection',
            channelDescription: 'Notifications for background device detection',
            importance: Importance.min,
            priority: Priority.min,
            showWhen: true,
            enableVibration: true,
            playSound: true,
            icon: '@mipmap/ic_launcher',
            onlyAlertOnce: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: 'out_of_range_${device.id}',
      );
      logger.i('Sent out-of-range notification for ${device.name} (ID: $notificationId)');
    }
  }

  final uniqueDevices = <String, DeviceModel>{};
  for (var device in updatedDevices) {
    uniqueDevices['${device.id}_${device.type}'] = device;
  }
  try {
    await prefs.setString('detected_devices', jsonEncode(uniqueDevices.values.map((d) => d.toJson()).toList()));
  } catch (e) {
    logger.e('Error saving detected devices: $e');
  }
}

Future<void> _initializeBackgroundNotifications() async {
  const initializationSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(
      requestSoundPermission: true,
      requestBadgePermission: true,
      requestAlertPermission: true,
      defaultPresentSound: true,
      defaultPresentBadge: true,
      defaultPresentBanner: true,
      defaultPresentAlert: true,
    ),
  );

  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (response) {
      logger.i('Background notification tapped: ${response.payload}');
    },
  );

  if (Platform.isAndroid) {
    await notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
      const AndroidNotificationChannel(
        'background_detection',
        'Background Device Detection',
        description: 'Notifications for background device detection',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );
  }

  if (Platform.isIOS) {
    await notifications
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
  }
}

int _generateNotificationId(String deviceName, String deviceType) {
  final timestamp = DateTime.now().millisecondsSinceEpoch % 100000;
  final hash = (deviceName.hashCode + deviceType.hashCode + timestamp) % 2147483647;
  final id = hash.abs();
  logger.d('Generated notification ID: $id for $deviceName ($deviceType)');
  return id;
}

class BackgroundService {
  static const String _taskName = 'detectDevices';

  static Future<void> initialize() async {
    try {
      await Workmanager().initialize(
        callbackDispatcher,
        isInDebugMode: const bool.fromEnvironment('dart.vm.product') ? false : true, // Disable debug in release
      );
      logger.i('Workmanager initialized for ${Platform.isAndroid ? "Android" : "iOS"}');
    } catch (e, stackTrace) {
      logger.e('Error initializing Workmanager: $e, stackTrace: $stackTrace');
    }
  }

  static Future<void> registerBackgroundTask() async {
    try {
      if (Platform.isAndroid) {
        await Workmanager().registerPeriodicTask(
          _taskName,
          'detectDevices',
          frequency: AppConfig.scanInterval,
          constraints: Constraints(
            networkType: NetworkType.notRequired,
            requiresBatteryNotLow: false,
            requiresCharging: false,
            requiresDeviceIdle: false,
            requiresStorageNotLow: false,
          ),
          existingWorkPolicy: ExistingWorkPolicy.replace,
        );
      } else if (Platform.isIOS) {
        await Workmanager().registerOneOffTask(
          _taskName,
          'detectDevices',
          initialDelay: const Duration(seconds: 5),
          constraints: Constraints(
            networkType: NetworkType.notRequired,
            requiresBatteryNotLow: false,
            requiresCharging: false,
            requiresDeviceIdle: false,
            requiresStorageNotLow: false,
          ),
          existingWorkPolicy: ExistingWorkPolicy.replace,
        );
      }
      logger.i('Background detection task registered for ${Platform.isAndroid ? "Android" : "iOS"}');
    } catch (e, stackTrace) {
      logger.e('Error registering background task: $e, stackTrace: $stackTrace');
    }
  }

  static Future<void> cancelBackgroundTask() async {
    try {
      await Workmanager().cancelByUniqueName(_taskName);
      logger.i('Background detection task cancelled');
    } catch (e, stackTrace) {
      logger.e('Error cancelling background task: $e, stackTrace: $stackTrace');
    }
  }

  static Future<void> requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.locationWhenInUse,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
    } else if (Platform.isIOS) {
      await [
        Permission.bluetooth,
        Permission.locationWhenInUse,
      ].request();
    }
    logger.i('Requested permissions for ${Platform.isAndroid ? "Android" : "iOS"}');
  }
}