import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart' hide ServiceStatus;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import '../models/attendance_config.dart';
import '../models/attendance_event.dart';
import '../attendance_tracker_platform_interface.dart';
import 'checkpoint_service.dart';
import 'detection_fusion.dart';

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  BackgroundExecutor.executeOnStart(service);
}

/// iOS detection runs natively (see ios/Classes), so the background fetch hook is a no-op.
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

/// Android background detection, run inside the flutter_background_service
/// foreground service. iOS uses the native engine instead, because iOS
/// suspends Dart timers in the background and never runs them after a kill.
@pragma('vm:entry-point')
class BackgroundExecutor {
  static const String configKey = 'attendance_config_cache';
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  static FlutterTts? _tts;
  static Timer? _scanTimer;
  static bool _cycleRunning = false;
  static String? _queuedTrigger;

  @pragma('vm:entry-point')
  static FlutterTts _getTts() {
    _tts ??= FlutterTts();
    return _tts!;
  }

  static Future<void> initialize(AttendanceConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(configKey, jsonEncode(config.toJson()));

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
    await _notifications.initialize(settings: initializationSettings);

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'attendance_tracker_foreground',
      'Attendance Tracking Service',
      description: 'Keeps attendance tracking active in background',
      importance: Importance.low,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await _createAlertChannels(config);

    print('AttendanceTracker: Configuring Background Service...');
    try {
      await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: onStart,
          autoStart: false,
          // Restart after reboot; onStart stops itself again when tracking is off.
          autoStartOnBoot: true,
          isForegroundMode: true,
          notificationChannelId: 'attendance_tracker_foreground',
          initialNotificationTitle: 'Attendance Tracking',
          initialNotificationContent: 'Searching for office zone...',
          foregroundServiceNotificationId: 888,
        ),
        iosConfiguration: IosConfiguration(autoStart: false, onForeground: onStart, onBackground: onIosBackground),
      );
      print('AttendanceTracker: Background Service Configured successfully.');
    } catch (e) {
      print('AttendanceTracker: CRITICAL Error during service.configure: $e');
      rethrow;
    }
  }

  static Future<void> start() async {
    final service = FlutterBackgroundService();
    print('AttendanceTracker: Attempting to start service...');

    try {
      if (await service.isRunning()) {
        // Already running: pick up a new config and scan with it.
        service.invoke('refresh');
        return;
      }
      await service.startService();
      print('AttendanceTracker: service.startService() called.');
    } catch (e) {
      print('AttendanceTracker: Error in startService: $e');
    }
  }

  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    print('AttendanceTracker: Stopping service...');
    service.invoke('stopService');
  }

  static Future<void> forceScan() async {
    final service = FlutterBackgroundService();
    service.invoke('forceScan');
  }

  /// Makes the service evaluate a checkpoint that was just recorded natively.
  static Future<void> notifyCheckpoint(String source) async {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke('checkpoint', {'trigger': source});
    } else {
      await service.startService();
    }
  }

  @pragma('vm:entry-point')
  static void executeOnStart(ServiceInstance service) async {
    print('AttendanceTracker: Background isolate (executeOnStart) entered.');
    try {
      DartPluginRegistrant.ensureInitialized();
      print('AttendanceTracker: DartPluginRegistrant initialized in background isolate.');
    } catch (e) {
      print('AttendanceTracker: Error in DartPluginRegistrant.ensureInitialized: $e');
    }

    if (service is AndroidServiceInstance) {
      // Android 14 Requirement: Must call this immediately (within 5 seconds)
      try {
        await service.setAsForegroundService();
      } catch (e) {
        print('AttendanceTracker: Failed to set foreground: $e');
      }
    }

    // The service also starts after a reboot or a watchdog restart; it must
    // not run when the user stopped tracking.
    final platform = AttendanceTrackerPlatform.instance;
    try {
      if (!await platform.isTrackingEnabled()) {
        print('AttendanceTracker: Tracking is disabled, stopping service.');
        service.stopSelf();
        return;
      }
      await platform.refreshMonitoring();
    } catch (e) {
      print('AttendanceTracker: Native tracking state unavailable: $e');
    }

    // Ping Timer to let UI know background is alive
    Timer.periodic(const Duration(seconds: 10), (timer) {
      service.invoke('ping', {'timestamp': DateTime.now().millisecondsSinceEpoch});
    });

    try {
      if (service is AndroidServiceInstance) {
        service.on('setAsForeground').listen((event) {
          service.setAsForegroundService();
        });

        service.on('setAsBackground').listen((event) {
          service.setAsBackgroundService();
        });
      }

      service.on('stopService').listen((event) {
        _scanTimer?.cancel();
        service.stopSelf();
      });

      service.on('forceScan').listen((event) {
        _runDetectionCycle(service, trigger: DetectionTrigger.manual);
      });

      service.on('checkpoint').listen((event) {
        _runDetectionCycle(service, trigger: event?['trigger'] as String? ?? DetectionTrigger.manual);
      });

      service.on('refresh').listen((event) async {
        await _startScanTimer(service);
        _runDetectionCycle(service, trigger: DetectionTrigger.manual);
      });

      service.on('testVibration').listen((event) {
        _showNotification(
          "Vibration Test",
          "This is a test of the SOS vibration pattern.",
          channelId: 'attendance_entry_v50',
          channelName: 'Attendance Entry Alerts',
          vibrationPattern: [0, 500, 200, 500, 200, 500],
        );
      });

      // Native wake-ups: geofence transitions and NFC/QR links captured by Android.
      platform.setNativeCallHandler((MethodCall call) async {
        switch (call.method) {
          case 'onWake':
            _runDetectionCycle(service, trigger: (call.arguments as Map?)?['trigger'] ?? DetectionTrigger.geofence);
            break;
          case 'onPendingCheckpoint':
            _runDetectionCycle(service, trigger: DetectionTrigger.nfc);
            break;
        }
        return null;
      });

      // Ensure notifications are initialized even if onStart is called alone (AOT entry point)
      const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
        requestAlertPermission: false, // Permissions already handled in UI
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _notifications.initialize(
        settings: const InitializationSettings(android: androidSettings, iOS: iosSettings),
      );

      // CRITICAL: Recreate notification channels in background isolate
      final config = await _loadConfig();
      if (config == null) {
        debugPrint('AttendanceTracker: Background config NOT found in SharedPreferences');
      }
      await _createAlertChannels(config);

      // Run initial detection immediately
      await _runDetectionCycle(service, trigger: DetectionTrigger.manual);
      await _startScanTimer(service);
    } catch (criticalError) {
      debugPrint('AttendanceTracker: CRITICAL Background Failure: $criticalError');
    }
  }

  static Future<void> _startScanTimer(ServiceInstance service) async {
    final config = await _loadConfig();
    final intervalSec = (config?.scanIntervalSeconds ?? 30).clamp(10, 300); // min 10s, max 5min
    debugPrint('AttendanceTracker: Scan interval set to ${intervalSec}s');

    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(Duration(seconds: intervalSec), (timer) {
      _runDetectionCycle(service, trigger: DetectionTrigger.timer);
    });
  }

  /// Reads the config written by the UI isolate. reload() is required: this
  /// isolate's SharedPreferences cache does not see the other isolate's writes.
  static Future<AttendanceConfig?> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final configJson = prefs.getString(configKey);
    if (configJson == null) return null;
    return AttendanceConfig.fromJson(jsonDecode(configJson));
  }

  static Future<void> _createAlertChannels(AttendanceConfig? config) async {
    // Explicitly create MAX-importance channels for entry/exit (v50/v51 to force reset after incorrect config)
    // NOTE: enableVibration must be true for the system to honor custom patterns
    final AndroidNotificationChannel entryChannel = AndroidNotificationChannel(
      'attendance_entry_v50',
      'Attendance Entry Alerts',
      description: 'Triggered when entering the office zone',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('inzone'),
      enableVibration: true,
      vibrationPattern: (config?.welcomeVibration != null && config!.welcomeVibration!.isNotEmpty)
          ? Int64List.fromList(config.welcomeVibration!)
          : Int64List.fromList([0, 500, 200, 500]),
    );
    final AndroidNotificationChannel exitChannel = AndroidNotificationChannel(
      'attendance_exit_v51',
      'Attendance Exit Alerts',
      description: 'Triggered when leaving the office zone',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('outofzone'),
      enableVibration: true,
      vibrationPattern: (config?.outOfZoneVibration != null && config!.outOfZoneVibration!.isNotEmpty)
          ? Int64List.fromList(config.outOfZoneVibration!)
          : Int64List.fromList([0, 200, 100, 200]),
    );

    final android =
        _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(entryChannel);
    await android?.createNotificationChannel(exitChannel);
  }

  /// Runs one detection; a request that arrives mid-scan runs right after it.
  @pragma('vm:entry-point')
  static Future<void> _runDetectionCycle(ServiceInstance service, {required String trigger}) async {
    if (_cycleRunning) {
      _queuedTrigger = trigger;
      return;
    }
    _cycleRunning = true;
    try {
      await _detect(service, trigger);
    } catch (e) {
      debugPrint('AttendanceTracker: Detection cycle ($trigger) failed: $e');
    } finally {
      _cycleRunning = false;
    }
    final queued = _queuedTrigger;
    if (queued != null) {
      _queuedTrigger = null;
      await _runDetectionCycle(service, trigger: queued);
    }
  }

  static Future<void> _detect(ServiceInstance service, String trigger) async {
    final config = await _loadConfig();
    if (config == null) {
      print('AttendanceTracker: No config found in background, skipping cycle.');
      return;
    }
    final now = DateTime.now();

    print('AttendanceTracker: Starting background detection cycle ($trigger) at ${now.hour}:${now.minute}:${now.second}');

    // NFC taps / links captured natively while Dart was not running.
    await CheckpointService.processPending(config);

    // 1. Check if within shift hours
    if (!config.isWithinShift(now)) {
      print('AttendanceTracker: Outside shift hours. Handling cleanup...');
      final status = await _getHardwareStatus();
      final result = DetectionResult(
        isInZone: false,
        status: status,
        trigger: trigger,
        timestamp: now,
        diagnosticLog: 'Scan skipped: Outside of shift hours (${now.hour}:${now.minute}).',
      );
      await _handleShiftEnded(config, result, service);
      await _publishResult(result, service);
      await EventUploader.uploadPending(config);
      return;
    }

    // 2. Perform Detection Fusion, then let a still-valid NFC/QR checkpoint count.
    print('AttendanceTracker: Performing Detection Fusion...');
    var detection = await DetectionFusion.performScan(config, trigger: trigger);
    detection = await CheckpointService.applyLastCheckpoint(detection, config);

    // 3. Service Guard: Check if all required sensors are on
    print('AttendanceTracker: Checking Service Guard...');
    await _handleServiceGuard(detection, service, config);

    // 4. Update Status and Notifications
    print('AttendanceTracker: Cycle complete. Updating UI and notifications...');
    await _handleDetectionResult(detection, config, service);
    await EventUploader.uploadPending(config);
  }

  /// Safely gets hardware status with timeouts to prevent hangups.
  @pragma('vm:entry-point')
  static Future<ServiceStatus> _getHardwareStatus() async {
    bool gps = false;
    bool wifi = false;
    bool ble = false;

    try {
      // GPS Status with timeout
      gps = await Geolocator.isLocationServiceEnabled().timeout(const Duration(seconds: 2), onTimeout: () => false);
    } catch (_) {}

    try {
      // Wi-Fi Status via platform channel or fallback
      wifi =
          await AttendanceTrackerPlatform.instance.isWifiEnabled().timeout(
            const Duration(seconds: 2),
            onTimeout: () => false,
          ) ??
          false;
    } catch (_) {
      // Fallback: Check if we have a BSSID if platform check fails
      try {
        final wifiBssid = await NetworkInfo().getWifiBSSID();
        wifi = wifiBssid != null;
      } catch (_) {}
    }

    try {
      // BLE Status with timeout
      if (await FlutterBluePlus.isSupported) {
        final state = await FlutterBluePlus.adapterState.first.timeout(
          const Duration(seconds: 2),
          onTimeout: () => BluetoothAdapterState.unknown,
        );
        ble = state == BluetoothAdapterState.on;
      }
    } catch (_) {}

    return ServiceStatus(isGpsEnabled: gps, isWifiEnabled: wifi, isBleEnabled: ble);
  }

  static Future<void> _handleServiceGuard(
    DetectionResult result,
    ServiceInstance service,
    AttendanceConfig config,
  ) async {
    final status = result.status;

    // Check what is REQUIRED vs what is ENABLED
    bool gpsRequired = config.officePoints.isNotEmpty;
    bool wifiRequired = config.hasWifi;
    bool bleRequired = config.hasBle || config.hasBeacons;

    List<String> missingRequired = [];
    if (gpsRequired && !status.isGpsEnabled) missingRequired.add('GPS');
    if (wifiRequired && !status.isWifiEnabled) missingRequired.add('Wi-Fi');
    if (bleRequired && !status.isBleEnabled) {
      missingRequired.add('Bluetooth');
      // Attempt to auto-enable Bluetooth on Android ONLY
      if (!Platform.isIOS) {
        try {
          if (await FlutterBluePlus.isSupported && await Permission.bluetoothConnect.isGranted) {
            await FlutterBluePlus.turnOn();
          }
        } catch (_) {}
      }
    }

    // A valid NFC/QR checkpoint keeps attendance working without sensors.
    if (missingRequired.isNotEmpty && !result.isInZone) {
      final allRequiredMissing =
          (gpsRequired ? !status.isGpsEnabled : true) &&
          (wifiRequired ? !status.isWifiEnabled : true) &&
          (bleRequired ? !status.isBleEnabled : true);

      if (allRequiredMissing) {
        _showNotification(
          'Detection Paused',
          'All required sensors (${missingRequired.join(", ")}) are OFF. Tracking is impossible.',
          channelId: 'attendance_system',
          channelName: 'System Alerts',
          enableTts: config.enableTts,
        );
      } else {
        // Limited detection: at least one required sensor is working, but others are off
        debugPrint('AttendanceTracker: Tracking limited, missing required: $missingRequired');

        if (service is AndroidServiceInstance) {
          service.setForegroundNotificationInfo(
            title: 'Attendance Tracking (Limited)',
            content: 'Please enable ${missingRequired.join(" and ")} for better accuracy.',
          );
        }
      }
    }
  }

  static Future<void> _publishResult(DetectionResult result, ServiceInstance service) async {
    final json = result.toJson();
    try {
      await AttendanceTrackerPlatform.instance.saveLastResult(json);
    } catch (e) {
      debugPrint('AttendanceTracker: saving last result failed: $e');
    }
    service.invoke('onUpdate', json);
  }

  static Future<void> _recordEvent(String type, DetectionResult result, ServiceInstance service) async {
    final event = AttendanceEvent.fromDetection(type, result);
    try {
      // Native fills in appState and keeps the event until the host app acknowledges it.
      await AttendanceTrackerPlatform.instance.appendEvent(event.toJson());
    } catch (e) {
      debugPrint('AttendanceTracker: recording $type event failed: $e');
    }
    service.invoke('onEvent', event.toJson());
  }

  static Future<void> _handleDetectionResult(
    DetectionResult result,
    AttendanceConfig config,
    ServiceInstance service,
  ) async {
    // Zone state lives natively so the UI isolate (NFC/QR tap-out) and this
    // service share one copy.
    final platform = AttendanceTrackerPlatform.instance;
    final state = await platform.getZoneState();
    final wasInZone = state['wasInZone'] == true;
    final isInZone = result.isInZone;

    await _publishResult(result, service);

    if (isInZone && !wasInZone && _inTapOutCooldown(result, config, state)) {
      debugPrint('AttendanceTracker: In zone again right after a tap-out; waiting for the cool-down.');
    } else if (isInZone && !wasInZone) {
      // ENTERING: Reset fail counter and mark as in-zone
      await platform.setZoneState(wasInZone: true, failCount: 0);
      await _recordEvent(AttendanceEventType.enter, result, service);

      final sourceLabel = const {
        'nfc': 'NFC tag',
        'qr': 'QR code',
        'beacon': 'iBeacon',
        'wifi': 'Wi-Fi',
        'ble': 'Bluetooth',
        'gps': 'GPS',
      }[result.source];

      _showNotification(
        config.welcomeTitle,
        "${config.welcomeBody}${sourceLabel != null ? ' (via $sourceLabel)' : ''}",
        channelId: 'attendance_entry_v50',
        channelName: 'Attendance Entry Alerts',
        sound: config.welcomeSound,
        vibrationPattern: config.welcomeVibration,
        enableTts: config.enableTts,
      );
    } else if (isInZone && wasInZone) {
      // STILL IN ZONE: Reset fail counter (healthy scan)
      if (state['failCount'] != 0) await platform.setZoneState(wasInZone: true, failCount: 0);
    } else if (!isInZone && wasInZone) {
      // POTENTIALLY LEAVING: Apply debounce — require multiple consecutive fails
      final threshold = config.exitDebounceCount.clamp(1, 10);
      final failCount = ((state['failCount'] as num?)?.toInt() ?? 0) + 1;

      debugPrint('AttendanceTracker: Out-of-zone fail count: $failCount / $threshold');

      if (failCount >= threshold) {
        // Confirmed exit after multiple consecutive fails
        await platform.setZoneState(wasInZone: false, failCount: 0);
        await _recordEvent(AttendanceEventType.exit, result, service);
        _showNotification(
          config.outOfZoneTitle,
          config.outOfZoneBody,
          channelId: 'attendance_exit_v51',
          channelName: 'Attendance Exit Alerts',
          sound: config.outOfZoneSound,
          vibrationPattern: config.outOfZoneVibration,
          enableTts: config.enableTts,
        );
      } else {
        await platform.setZoneState(wasInZone: true, failCount: failCount);
        debugPrint('AttendanceTracker: Debouncing exit ($failCount/$threshold). Not yet confirmed.');
      }
    }

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Attendance Tracking',
        content: isInZone ? 'Currently IN Zone' : 'Searching for zone...',
      );
    }
  }

  /// After a tap-out, only another tap/scan may check the user back in for
  /// [AttendanceConfig.tapOutCooldownMinutes].
  static bool _inTapOutCooldown(DetectionResult result, AttendanceConfig config, Map<dynamic, dynamic> state) {
    final tapOutAt = (state['tapOutAt'] as num?)?.toInt();
    if (tapOutAt == null || result.byNfc || result.byQr) return false;
    final since = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(tapOutAt));
    return since < Duration(minutes: config.tapOutCooldownMinutes);
  }

  static Future<void> _handleShiftEnded(
    AttendanceConfig config,
    DetectionResult result,
    ServiceInstance service,
  ) async {
    final platform = AttendanceTrackerPlatform.instance;
    final wasInZone = (await platform.getZoneState())['wasInZone'] == true;
    if (wasInZone) {
      await platform.setZoneState(wasInZone: false, failCount: 0);
      await _recordEvent(AttendanceEventType.shiftEnded, result, service);
      _showNotification(
        config.shiftEndedTitle,
        config.shiftEndedBody,
        channelId: 'attendance_exit_v51',
        channelName: 'Attendance Exit Alerts',
        sound: config.outOfZoneSound,
        vibrationPattern: config.outOfZoneVibration,
        enableTts: config.enableTts,
      );
    }
  }

  static void _showNotification(
    String title,
    String body, {
    required String channelId,
    required String channelName,
    String? sound,
    List<int>? vibrationPattern,
    bool enableTts = false,
  }) {
    Int64List? pattern;
    if (vibrationPattern != null) {
      pattern = Int64List.fromList(vibrationPattern);
    }

    final soundFile = (sound != null && sound.isNotEmpty) ? RawResourceAndroidNotificationSound(sound) : null;

    final int notificationId = DateTime.now().millisecondsSinceEpoch % 100000;
    _notifications.show(
      id: notificationId,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: Importance.max, // Ensure MAX matches channel
          priority: Priority.max, // Ensure MAX priority
          visibility: NotificationVisibility.public, // Show on lock screen
          icon: '@mipmap/ic_launcher',
          vibrationPattern: pattern,
          sound: soundFile,
          enableVibration: true,
          playSound: true,
          ticker: 'Attendance Status Update',
          fullScreenIntent: true, // High priority
          category: AndroidNotificationCategory.status,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          sound: (sound != null && sound.isNotEmpty) ? (sound.endsWith('.wav') ? sound : '$sound.wav') : null,
        ),
      ),
    );

    // Definitive Fix: Explicit hardware vibration bypassing notification limitations
    if (vibrationPattern != null && vibrationPattern.isNotEmpty) {
      try {
        Vibration.hasVibrator()
            .then((hasVibrator) {
              if (hasVibrator == true) {
                Vibration.vibrate(pattern: vibrationPattern);
              }
            })
            .catchError((e) {
              debugPrint('AttendanceTracker: Vibration Error: $e');
              return null;
            });
      } catch (e) {
        debugPrint('AttendanceTracker: Vibration initialization error: $e');
      }
    }

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
