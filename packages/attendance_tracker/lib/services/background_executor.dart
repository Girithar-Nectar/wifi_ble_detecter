import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/attendance_config.dart';
import 'detection_fusion.dart';

class BackgroundExecutor {
  static const String _configKey = 'attendance_config_cache';
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  static Future<void> initialize(AttendanceConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configKey, jsonEncode(config.toJson()));

    final service = FlutterBackgroundService();

    // Initial notification setup
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
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'attendance_tracker_foreground',
        initialNotificationTitle: 'Attendance Tracking',
        initialNotificationContent: 'Searching for office zone...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(autoStart: false, onForeground: onStart, onBackground: onIosBackground),
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

  static Future<bool> checkCurrentStatus() async {
    // This would ideally communicate with the running service
    return false;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    if (service is AndroidServiceInstance) {
      // Android 14 Requirement: Must call this immediately to satisfy startForegroundService()
      await service.setAsForegroundService();

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

    // Run initial detection immediately
    await _runDetectionCycle(service);

    // Periodic detection loop
    Timer.periodic(const Duration(minutes: 1), (timer) async {
      await _runDetectionCycle(service);
    });
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    return true;
  }

  static Future<void> _runDetectionCycle(ServiceInstance service) async {
    final prefs = await SharedPreferences.getInstance();
    final configJson = prefs.getString(_configKey);
    if (configJson == null) return;

    final config = AttendanceConfig.fromJson(jsonDecode(configJson));
    final now = DateTime.now();

    // 1. Check if within shift hours
    if (!_isWithinShift(now, config)) {
      // Logic for "Forgot to checkout" if previously in zone
      await _handleShiftEnded(config, prefs);
      return;
    }

    // 2. Perform Detection Fusion
    final detection = await DetectionFusion.performScan(config);

    // 3. Update Status and Notifications
    await _handleDetectionResult(detection, config, prefs, service);
  }

  static bool _isWithinShift(DateTime now, AttendanceConfig config) {
    final start = DateTime(now.year, now.month, now.day, config.shiftStart.hour, config.shiftStart.minute);
    final end = DateTime(now.year, now.month, now.day, config.shiftEnd.hour, config.shiftEnd.minute);
    return now.isAfter(start) && now.isBefore(end);
  }

  static Future<void> _handleDetectionResult(
    DetectionResult result,
    AttendanceConfig config,
    SharedPreferences prefs,
    ServiceInstance service,
  ) async {
    final wasInZone = prefs.getBool('was_in_zone') ?? false;
    final isInZone = result.isInZone;

    if (isInZone && !wasInZone) {
      _showNotification(config.welcomeTitle, config.welcomeBody);
      await prefs.setBool('was_in_zone', true);
    } else if (!isInZone && wasInZone) {
      _showNotification(config.outOfZoneTitle, config.outOfZoneBody);
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
      _showNotification(config.shiftEndedTitle, config.shiftEndedBody);
      await prefs.setBool('was_in_zone', false);
    }
  }

  static void _showNotification(String title, String body) {
    _notifications.show(
      DateTime.now().millisecond,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'attendance_alerts',
          'Attendance Alerts',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }
}
