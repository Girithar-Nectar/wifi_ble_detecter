import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart' hide ServiceStatus;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/attendance_config.dart';
import 'detection_fusion.dart';

@pragma('vm:entry-point')
class BackgroundExecutor {
  static const String _configKey = 'attendance_config_cache';
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  static FlutterTts? _tts;

  static FlutterTts _getTts() {
    _tts ??= FlutterTts();
    return _tts!;
  }

  static Future<void> initialize(AttendanceConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configKey, jsonEncode(config.toJson()));

    final service = FlutterBackgroundService();

    // Initial notification setup
    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );
    await _notifications.initialize(initializationSettings);

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'attendance_tracker_foreground',
      'Attendance Tracking Service',
      description: 'Keeps attendance tracking active in background',
      importance: Importance.low,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false, // Don't start immediately; wait for permissions in UI
        isForegroundMode: true,
        notificationChannelId: 'attendance_tracker_foreground',
        initialNotificationTitle: 'Attendance Tracking',
        initialNotificationContent: 'Searching for office zone...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(autoStart: true, onForeground: onStart, onBackground: onIosBackground),
    );
  }

  static Future<void> start() async {
    final service = FlutterBackgroundService();
    await service.startService();
  }

  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    service.invoke('stopService');
  }

  static Future<void> forceScan() async {
    final service = FlutterBackgroundService();
    service.invoke('forceScan');
  }

  static Future<DetectionResult?> getLastResult() async {
    final prefs = await SharedPreferences.getInstance();
    final resultJson = prefs.getString('last_detection_result');
    if (resultJson == null) return null;

    try {
      final map = jsonDecode(resultJson);
      // We need a way to deserialize DetectionResult
      // I'll add a fromJson to DetectionResult or just manual map here
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
    } catch (_) {
      return null;
    }
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    if (service is AndroidServiceInstance) {
      // Android 14 Requirement: Must call this immediately (within 5 seconds)
      try {
        await service.setAsForegroundService();
      } catch (e) {
        debugPrint('AttendanceTracker: Failed to set foreground: $e');
      }
    }

    try {
      DartPluginRegistrant.ensureInitialized();

      if (service is AndroidServiceInstance) {
        service.on('setAsForeground').listen((event) {
          service.setAsForegroundService();
        });

        service.on('setAsBackground').listen((event) {
          service.setAsBackgroundService();
        });
      }

      service.on('stopService').listen((event) {
        service.stopSelf();
      });

      service.on('forceScan').listen((event) async {
        try {
          await _runDetectionCycle(service);
        } catch (e) {
          debugPrint('AttendanceTracker: Force scan failed: $e');
        }
      });

      // Ensure notifications are initialized even if onStart is called alone (AOT entry point)
      const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _notifications.initialize(const InitializationSettings(android: androidSettings));

      // Run initial detection immediately
      try {
        await _runDetectionCycle(service);
      } catch (e) {
        debugPrint('AttendanceTracker: Initial detection failed: $e');
      }

      // Periodic detection loop
      Timer.periodic(const Duration(minutes: 1), (timer) async {
        try {
          await _runDetectionCycle(service);
        } catch (e) {
          debugPrint('AttendanceTracker: Periodic cycle failed: $e');
        }
      });
    } catch (criticalError) {
      debugPrint('AttendanceTracker: CRITICAL Background Failure: $criticalError');
    }
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    try {
      DartPluginRegistrant.ensureInitialized();
      await _runDetectionCycle(service);
      return true;
    } catch (e) {
      debugPrint('AttendanceTracker: iOS Background Fetch Error: $e');
      return false;
    }
  }

  static Future<void> _runDetectionCycle(ServiceInstance service) async {
    final prefs = await SharedPreferences.getInstance();
    final configJson = prefs.getString(_configKey);
    if (configJson == null) return;

    final config = AttendanceConfig.fromJson(jsonDecode(configJson));
    final now = DateTime.now();

    // 1. Check if within shift hours
    if (!_isWithinShift(now, config)) {
      await _handleShiftEnded(config, prefs);
      // Still notify UI so it can update its "Loading" state and logs
      service.invoke('onUpdate', {
        'isInZone': false,
        'byGps': false,
        'byWifi': false,
        'byBle': false,
        'diagnosticLog': 'Scan skipped: Outside of shift hours (${now.hour}:${now.minute}).',
        'status': {
          'isGpsEnabled': await Geolocator.isLocationServiceEnabled(),
          'isWifiEnabled': (await WiFiScan.instance.canStartScan()) == CanStartScan.yes,
          'isBleEnabled':
              await FlutterBluePlus.isSupported && await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on,
        },
      });
      return;
    }

    // 2. Perform Detection Fusion
    final detection = await DetectionFusion.performScan(config);

    // 3. Service Guard: Check if all required sensors are on
    await _handleServiceGuard(detection, service, config);

    // 4. Update Status and Notifications
    await _handleDetectionResult(detection, config, prefs, service);
  }

  static Future<void> _handleServiceGuard(
    DetectionResult result,
    ServiceInstance service,
    AttendanceConfig config,
  ) async {
    final status = result.status;
    List<String> disabled = [];

    if (!status.isGpsEnabled) disabled.add('GPS/Location');
    if (!status.isWifiEnabled) disabled.add('Wi-Fi');
    if (!status.isBleEnabled) {
      disabled.add('Bluetooth');
      // Attempt to auto-enable Bluetooth on Android
      try {
        if (await FlutterBluePlus.isSupported) {
          await FlutterBluePlus.turnOn();
        }
      } catch (_) {}
    }

    if (disabled.isNotEmpty) {
      final anythingEnabled = status.isGpsEnabled || status.isWifiEnabled || status.isBleEnabled;
      if (!anythingEnabled) {
        _showNotification(
          'Detection Paused',
          'All tracking sensors (GPS, Wi-Fi, Bluetooth) are turned OFF. Please enable at least one to record attendance.',
          enableTts: config.enableTts,
        );
      } else {
        debugPrint('AttendanceTracker: Tracking limited, disabled: $disabled');
      }
    }
  }

  static bool _isWithinShift(DateTime now, AttendanceConfig config) {
    final currentMs = (now.hour * 3600000) + (now.minute * 60000) + (now.second * 1000) + now.millisecond;

    if (config.shiftStartMs <= config.shiftEndMs) {
      return currentMs >= config.shiftStartMs && currentMs <= config.shiftEndMs;
    } else {
      // Shift spans across midnight (e.g., 22:00 to 06:00)
      return currentMs >= config.shiftStartMs || currentMs <= config.shiftEndMs;
    }
  }

  static Future<void> _handleDetectionResult(
    DetectionResult result,
    AttendanceConfig config,
    SharedPreferences prefs,
    ServiceInstance service,
  ) async {
    final wasInZone = prefs.getBool('was_in_zone') ?? false;
    final isInZone = result.isInZone;

    // Cache the full result for UI
    final resultJson = jsonEncode({
      'isInZone': result.isInZone,
      'byGps': result.byGps,
      'byWifi': result.byWifi,
      'byBle': result.byBle,
      'distance': result.distance,
      'diagnosticLog': result.diagnosticLog,
      'status': {
        'isGpsEnabled': result.status.isGpsEnabled,
        'isWifiEnabled': result.status.isWifiEnabled,
        'isBleEnabled': result.status.isBleEnabled,
      },
    });
    await prefs.setString('last_detection_result', resultJson);

    // Send update to UI
    service.invoke('onUpdate', jsonDecode(resultJson));

    if (isInZone && !wasInZone) {
      String source = "";
      if (result.byGps)
        source = " (via GPS)";
      else if (result.byWifi)
        source = " (via Wi-Fi)";
      else if (result.byBle)
        source = " (via Bluetooth)";

      _showNotification(
        config.welcomeTitle,
        "${config.welcomeBody}$source",
        sound: config.welcomeSound,
        vibrationPattern: config.welcomeVibration,
        enableTts: config.enableTts,
      );
      await prefs.setBool('was_in_zone', true);
    } else if (!isInZone && wasInZone) {
      _showNotification(
        config.outOfZoneTitle,
        config.outOfZoneBody,
        sound: config.outOfZoneSound,
        vibrationPattern: config.outOfZoneVibration,
        enableTts: config.enableTts,
      );
      await prefs.setBool('was_in_zone', false);
    }

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Attendance Tracking',
        content: isInZone ? 'Currently IN Zone' : 'Searching for zone...',
      );
    }
  }

  static Future<void> _handleShiftEnded(AttendanceConfig config, SharedPreferences prefs) async {
    final wasInZone = prefs.getBool('was_in_zone') ?? false;
    if (wasInZone) {
      _showNotification(
        config.shiftEndedTitle,
        config.shiftEndedBody,
        sound: config.outOfZoneSound,
        vibrationPattern: config.outOfZoneVibration,
        enableTts: config.enableTts,
      );
      await prefs.setBool('was_in_zone', false);
    }
  }

  static void _showNotification(
    String title,
    String body, {
    String? sound,
    List<int>? vibrationPattern,
    bool enableTts = false,
  }) {
    Int64List? pattern;
    if (vibrationPattern != null) {
      pattern = Int64List.fromList(vibrationPattern);
    }

    final soundFile = (sound != null && sound.isNotEmpty) ? RawResourceAndroidNotificationSound(sound) : null;

    _notifications.show(
      DateTime.now().millisecond,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'attendance_alerts',
          'Attendance Alerts',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          vibrationPattern: pattern,
          sound: soundFile,
          enableVibration: true,
        ),
        iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true, sound: sound),
      ),
    );

    // Speak using TTS if enabled
    if (enableTts) {
      try {
        _getTts().speak("$title. $body");
      } catch (e) {
        debugPrint('AttendanceTracker: TTS Error in background: $e');
      }
    }
  }
}
