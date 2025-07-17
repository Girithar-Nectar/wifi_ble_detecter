import 'package:get/get.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../helper/logger.dart';

class NotificationController extends GetxController {
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  static final FlutterTts _tts = FlutterTts();
  static const String _channelId = 'device_detection';
  static const String _channelName = 'Device Detection';
  static const String _channelDescription = 'Notifications for nearby WiFi and Bluetooth devices';

  final Map<int, String> _ttsMessages = {};
  bool _isSpeaking = false;
  int? _currentTtsNotificationId;

  @override
  void onInit() {
    super.onInit();
    _initializeTts();
    initialize();
  }

  static Future<void> initialize() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
    AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await _notifications.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await _notifications
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  Future<void> _initializeTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setCompletionHandler(() {
      if (_currentTtsNotificationId != null) {
        _ttsMessages.remove(_currentTtsNotificationId);
        logger.i('TTS completed for notification ID: $_currentTtsNotificationId');
        _currentTtsNotificationId = null;
      }
      _isSpeaking = false;
      _processNextTtsMessage();
    });

    _tts.setErrorHandler((msg) {
      logger.e('TTS error: $msg');
      if (_currentTtsNotificationId != null) {
        _ttsMessages.remove(_currentTtsNotificationId);
        logger.i('Removed TTS message for notification ID: $_currentTtsNotificationId due to error');
        _currentTtsNotificationId = null;
      }
      _isSpeaking = false;
      _processNextTtsMessage();
    });

    _tts.setCancelHandler(() {
      _isSpeaking = false;
      _currentTtsNotificationId = null;
      logger.i('TTS playback cancelled');
    });
  }

  Future<void> _processNextTtsMessage() async {
    if (_isSpeaking || _ttsMessages.isEmpty) return;

    _isSpeaking = true;
    final entry = _ttsMessages.entries.first;
    _currentTtsNotificationId = entry.key;
    logger.i('Speaking TTS for notification ID: ${entry.key}, message: ${entry.value}');
    await _tts.speak(entry.value);
  }

  void _queueTtsMessage(int notificationId, String message) {
    if (_ttsMessages.containsKey(notificationId)) {
      logger.w('Overwriting existing TTS message for notification ID: $notificationId');
    }
    _ttsMessages[notificationId] = message;
    logger.i('Queued TTS message for notification ID: $notificationId, message: $message');
    _processNextTtsMessage();
  }

  static void _onNotificationTapped(NotificationResponse response) {
    logger.i('Notification tapped: ${response.payload}');
  }

  void showDeviceInRangeNotification(String deviceName, String deviceType, String distance) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      playSound: true,
      icon: '@mipmap/ic_launcher',
      onlyAlertOnce: true,
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final notificationId = _generateNotificationId(deviceName, deviceType);
    final message = '$deviceName ($deviceType) is nearby at approximately $distance meters';
    logger.i('Showing in-range notification: $message (ID: $notificationId)');
    await _notifications.show(
      notificationId,
      'Device Detected!',
      message,
      details,
      payload: 'in_range_$deviceName',
    );

    _queueTtsMessage(notificationId, message);
  }

  void showDeviceOutOfRangeNotification(String deviceName, String deviceType) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.min,
      priority: Priority.min,
      showWhen: true,
      enableVibration: true,
      playSound: true,
      icon: '@mipmap/ic_launcher',
      onlyAlertOnce: true,
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final notificationId = _generateNotificationId(deviceName, deviceType);
    final message = '$deviceName ($deviceType) is no longer nearby';
    logger.i('Showing out-of-range notification: $message (ID: $notificationId)');
    await _notifications.show(
      notificationId,
      'Device Out of Range',
      message,
      details,
      payload: 'out_of_range_$deviceName',
    );

    _queueTtsMessage(notificationId, message);
  }

  void showBeaconDetectedNotification(String beaconName, String distance) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      playSound: true,
      icon: '@mipmap/ic_launcher',
      onlyAlertOnce: true,
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final notificationId = _generateNotificationId(beaconName, 'BLE');
    final message = '$beaconName beacon is nearby at approximately $distance meters';
    logger.i('Showing beacon notification: $message (ID: $notificationId)');
    await _notifications.show(
      notificationId,
      'BLE Beacon Detected!',
      message,
      details,
      payload: 'beacon_$beaconName',
    );

    _queueTtsMessage(notificationId, message);
  }

  void showStatusNotification(String title, String body) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.low,
      priority: Priority.low,
      showWhen: true,
      enableVibration: false,
      playSound: false,
      icon: '@mipmap/ic_launcher',
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final notificationId = _generateNotificationId(title, 'status_${DateTime.now().millisecondsSinceEpoch}');
    logger.i('Showing status notification: $title - $body (ID: $notificationId)');
    await _notifications.show(
      notificationId,
      title,
      body,
      details,
    );

    _queueTtsMessage(notificationId, '$title: $body');
  }

  int _generateNotificationId(String deviceName, String deviceType) {
    final timestamp = DateTime.now().millisecondsSinceEpoch % 100000; // Use last 5 digits of timestamp
    final hash = (deviceName.hashCode + deviceType.hashCode + timestamp) % 2147483647; // Ensure within 32-bit range
    final id = hash.abs();
    logger.d('Generated notification ID: $id for $deviceName ($deviceType)');
    return id;
  }

  Future<void> cancelAllNotifications() async {
    await _notifications.cancelAll();
    await _tts.stop();
    _ttsMessages.clear();
    _isSpeaking = false;
    _currentTtsNotificationId = null;
    logger.i('All notifications and TTS cancelled');
  }

  Future<void> cancelNotification(int id) async {
    await _notifications.cancel(id);
    if (_ttsMessages.containsKey(id)) {
      logger.i('Cancelling notification ID: $id');
      if (_currentTtsNotificationId == id && _isSpeaking) {
        await _tts.stop();
        _isSpeaking = false;
        _currentTtsNotificationId = null;
        logger.i('Stopped TTS for notification ID: $id');
      }
      _ttsMessages.remove(id);
      logger.i('Removed TTS message for notification ID: $id');
    }
    _processNextTtsMessage();
  }

  Future<List<PendingNotificationRequest>> getPendingNotifications() async {
    return await _notifications.pendingNotificationRequests();
  }

  Future<bool> areNotificationsEnabled() async {
    final androidImplementation =
    _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidImplementation != null) {
      return await androidImplementation.areNotificationsEnabled() ?? false;
    }
    return true;
  }

  Future<bool> requestPermissions() async {
    final androidImplementation =
    _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidImplementation != null) {
      return await androidImplementation.requestNotificationsPermission() ?? false;
    }
    return true;
  }
}