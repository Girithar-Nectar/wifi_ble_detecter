import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart' hide ServiceStatus;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import 'package:shared_preferences/shared_preferences.dart';
import 'services/background_executor.dart';
import 'services/checkpoint_service.dart';
import 'services/checkpoint_verifier.dart';
import 'services/detection_fusion.dart';
import 'models/attendance_config.dart';
import 'models/attendance_event.dart';
import 'attendance_tracker_platform_interface.dart';

export 'models/attendance_config.dart';
export 'models/attendance_event.dart';
export 'services/detection_fusion.dart';
export 'services/checkpoint_verifier.dart';
export 'services/checkpoint_service.dart' show CheckpointOutcome;

/// Outcome of an NFC tap or QR scan.
class CheckpointResult {
  /// [CheckpointSource.nfc] or [CheckpointSource.qr].
  final String source;
  final CheckpointVerification verification;

  /// The zone state after the checkpoint was applied (null when invalid).
  final DetectionResult? detection;

  /// NFC only: the tag UID and its NDEF text/URI records, useful when
  /// registering a new tag.
  final String? tagUid;
  final List<String> tagPayloads;

  const CheckpointResult({
    required this.source,
    required this.verification,
    this.detection,
    this.tagUid,
    this.tagPayloads = const [],
  });

  bool get isValid => verification.isValid;
}

/// What the device still needs for attendance to keep working while the app
/// is in the background or killed.
class TrackingReadiness {
  /// "Always" / "Allow all the time" location. Required for geofences and for
  /// iOS to relaunch a killed app.
  final bool backgroundLocation;
  final bool notifications;

  /// Android: the app is exempt from battery optimisation, so the system lets
  /// it restart its foreground service after a kill. Always true on iOS.
  final bool ignoringBatteryOptimizations;
  final bool nfcAvailable;

  const TrackingReadiness({
    required this.backgroundLocation,
    required this.notifications,
    required this.ignoringBatteryOptimizations,
    required this.nfcAvailable,
  });

  bool get isReadyForBackground => backgroundLocation && notifications && ignoringBatteryOptimizations;
}

class AttendanceTracker {
  static final AttendanceTracker _instance = AttendanceTracker._internal();
  factory AttendanceTracker() => _instance;
  AttendanceTracker._internal();

  AttendanceConfig? _config;
  bool _nativeHandlerSet = false;
  final List<StreamSubscription> _serviceSubscriptions = [];

  late final StreamController<DetectionResult> _results = StreamController.broadcast(onListen: _listenToService);
  late final StreamController<AttendanceEvent> _events = StreamController.broadcast(onListen: _listenToService);
  late final StreamController<Map<String, dynamic>> _pings = StreamController.broadcast(onListen: _listenToService);

  AttendanceTrackerPlatform get _platform => AttendanceTrackerPlatform.instance;

  /// Check if all critical permissions (Location, Bluetooth) are granted.
  Future<bool> hasPermissions() async {
    try {
      final isIOS = Platform.isIOS;
      final sdkInt = await AttendanceTrackerPlatform.instance.getAndroidSdkInt() ?? 0;

      // Check location permission via Geolocator
      final locStatus = await Geolocator.checkPermission();
      // iOS MUST have 'always' for background tracking to work reliably
      final hasLoc = isIOS
          ? (locStatus == LocationPermission.always)
          : (locStatus == LocationPermission.always || locStatus == LocationPermission.whileInUse);

      // Check Nearby Wi-Fi Devices (Android 13+ only)
      bool hasNearbyWifi = true;
      if (!isIOS && sdkInt >= 33) {
        hasNearbyWifi = await Permission.nearbyWifiDevices.isGranted;
      }

      // Check Bluetooth permissions (Android 12+ only)
      bool hasBle = true;
      if (!isIOS && sdkInt >= 31) {
        hasBle = await Permission.bluetoothScan.isGranted && await Permission.bluetoothConnect.isGranted;
      } else if (isIOS) {
        // On iOS, Bluetooth permission is handled by CoreBluetooth automatically
        hasBle = true;
      }

      // Check notification permission
      final hasNotification = await Permission.notification.isGranted;

      return hasLoc && hasNotification && hasBle && hasNearbyWifi;
    } catch (e) {
      print('AttendanceTracker: Error checking permissions: $e');
      return false;
    }
  }

  /// Request all necessary permissions and return true if critical ones are granted.
  Future<bool> requestPermissions() async {
    try {
      print('AttendanceTracker: Starting permission REQUEST sequence...');

      // Small delay to let the app settle
      await Future.delayed(const Duration(milliseconds: 500));

      // 0. Detect platform
      final isIOS = Platform.isIOS;
      final sdkInt = await AttendanceTrackerPlatform.instance.getAndroidSdkInt() ?? 0;
      print('AttendanceTracker: Platform: ${isIOS ? "iOS" : "Android API $sdkInt"}');

      // iOS-specific: Request location via Geolocator FIRST
      if (isIOS) {
        final locStatus = await Geolocator.checkPermission();
        print('AttendanceTracker: iOS Location status: $locStatus');

        if (locStatus == LocationPermission.denied) {
          print('AttendanceTracker: Requesting iOS location permission via Geolocator...');
          final newStatus = await Geolocator.requestPermission();
          print('AttendanceTracker: iOS Location permission result: $newStatus');

          if (newStatus == LocationPermission.deniedForever) {
            print('AttendanceTracker: Location permanently denied. Opening Settings...');
            await Geolocator.openLocationSettings();
            await Future.delayed(const Duration(seconds: 2));
          } else if (newStatus == LocationPermission.whileInUse) {
            print('AttendanceTracker: "While In Use" granted. Now requesting "Always" for background...');
            // On iOS, you can only request 'always' after 'whileInUse' is granted
            final alwaysStatus = await Geolocator.requestPermission();
            print('AttendanceTracker: iOS Location "Always" result: $alwaysStatus');
          }
        } else if (locStatus == LocationPermission.whileInUse) {
          print('AttendanceTracker: Already have "While In Use". Upgrading to "Always"...');
          final alwaysStatus = await Geolocator.requestPermission();
          print('AttendanceTracker: iOS Location "Always" upgrade result: $alwaysStatus');
        } else if (locStatus == LocationPermission.deniedForever) {
          print('AttendanceTracker: Location permanently denied. Please enable in Settings.');
          await Geolocator.openAppSettings();
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      // 1. Request ALL Runtime Permissions in ONE BATCH to prevent UI conflicts
      print('AttendanceTracker: Requesting runtime permission BATCH...');
      final Map<Permission, PermissionStatus> statuses = await [
        if (!isIOS) Permission.location, // Android uses permission_handler
        Permission.notification,
        if (!isIOS && sdkInt >= 31) Permission.bluetoothScan,
        if (!isIOS && sdkInt >= 31) Permission.bluetoothConnect,
        if (!isIOS && sdkInt >= 33) Permission.nearbyWifiDevices,
        if (isIOS) Permission.bluetooth,
      ].request();

      print('AttendanceTracker: Batch request finished: $statuses');

      // 1b. Android: "Allow all the time" is a separate step (a Settings page on
      // Android 11+). Geofences and restarts after a kill need it.
      if (!isIOS && (statuses[Permission.location]?.isGranted ?? false)) {
        if (!await Permission.locationAlways.isGranted) {
          print('AttendanceTracker: Requesting Android background location...');
          final always = await Permission.locationAlways.request();
          print('AttendanceTracker: Android background location result: $always');
        }
      }

      // 2. Wait for system UI to settle completely
      print('AttendanceTracker: Waiting for UI to settle...');
      await Future.delayed(const Duration(milliseconds: 1500));

      // 3. Hardware / Service Level Prompts (Settings Panels)
      print('AttendanceTracker: Checking hardware services...');

      // 3a. GPS (Location Services)
      final locStatusFinal = await Geolocator.checkPermission();
      bool gpsEnabled = await Geolocator.isLocationServiceEnabled();
      if (!gpsEnabled &&
          (locStatusFinal == LocationPermission.always || locStatusFinal == LocationPermission.whileInUse)) {
        print('AttendanceTracker: GPS is OFF but permission GRANTED. Prompting user...');
        gpsEnabled = await ensureLocationServiceEnabled();
      }

      // 3c. Wi-Fi Power
      bool wifiPermissionGranted = isIOS || sdkInt < 33 || (statuses[Permission.nearbyWifiDevices]?.isGranted ?? false);
      if (wifiPermissionGranted) {
        bool wifiOn = await isWifiEnabled();
        if (!wifiOn) {
          print('AttendanceTracker: Wi-Fi is OFF. Displaying Settings Panel...');
          wifiOn = await ensureWifiEnabled();
        }
      }

      // 3b. Bluetooth Power
      bool blePermissionGranted = isIOS || sdkInt < 31 || (statuses[Permission.bluetoothConnect]?.isGranted ?? false);
      if (blePermissionGranted) {
        print('AttendanceTracker: Attempting to power on Bluetooth...');
        try {
          await FlutterBluePlus.turnOn().timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              print('AttendanceTracker: Bluetooth turnOn timed out');
            },
          );
          print('AttendanceTracker: Bluetooth turned on successfully');
        } catch (e) {
          // This catches "Bad state: No element" and other bluetooth errors
          print('AttendanceTracker: Bluetooth turnOn failed (expected if permission denied): $e');
        }
      }

      final hasAll = await hasPermissions();
      print('AttendanceTracker: Permission request sequence complete. All granted: $hasAll');
      return hasAll;
    } catch (e, stack) {
      print('AttendanceTracker: FATAL error requesting permissions: $e');
      print('AttendanceTracker: Stack trace: $stack');
      return false;
    }
  }

  /// Reports what is still missing for background and killed-state tracking.
  Future<TrackingReadiness> getReadiness() async {
    final locStatus = await Geolocator.checkPermission();
    return TrackingReadiness(
      backgroundLocation: locStatus == LocationPermission.always,
      notifications: await Permission.notification.isGranted,
      ignoringBatteryOptimizations: await isIgnoringBatteryOptimizations(),
      nfcAvailable: await isNfcAvailable(),
    );
  }

  /// Android: whether the app is exempt from battery optimisation. Always true on iOS.
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (Platform.isIOS) return true;
    try {
      return await _platform.isIgnoringBatteryOptimizations();
    } catch (_) {
      return false;
    }
  }

  /// Android: asks the user to exempt the app from battery optimisation, which
  /// lets the system restart tracking after the app is swiped away. Opens the
  /// direct prompt when the host app declares
  /// REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, otherwise the settings list.
  Future<bool> requestIgnoreBatteryOptimizations() async {
    if (Platform.isIOS) return true;
    try {
      return await _platform.requestIgnoreBatteryOptimizations();
    } catch (_) {
      return false;
    }
  }

  /// Attempts to prompt the user to enable Location Services.
  /// Returns the state of the service after the prompt.
  Future<bool> ensureLocationServiceEnabled() async {
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (enabled) return true;

    // Geolocator.openLocationSettings() returns true if it opened the settings
    await Geolocator.openLocationSettings();

    // Give user time to toggle
    await Future.delayed(const Duration(seconds: 2));

    return await Geolocator.isLocationServiceEnabled();
  }

  /// Attempts to prompt the user to enable Wi-Fi hardware.
  Future<bool> ensureWifiEnabled() async {
    bool enabled = await isWifiEnabled();
    if (enabled) return true;

    await openWifiSettings();

    // Give user time to toggle
    await Future.delayed(const Duration(seconds: 2));

    return await isWifiEnabled();
  }

  /// Check if Wi-Fi hardware is enabled.
  Future<bool> isWifiEnabled() async {
    try {
      return await AttendanceTrackerPlatform.instance.isWifiEnabled() ?? false;
    } catch (_) {
      // Fallback: if we can't check, assume true if we have a BSSID or false otherwise
      final wifiBssid = await NetworkInfo().getWifiBSSID();
      return wifiBssid != null;
    }
  }

  /// Programmatically set Wi-Fi state (deprecated and restricted on Android 10+).
  /// Returns true if successful. On Android 10+, this will likely return false.
  Future<bool> setWifiEnabled(bool enabled) async {
    try {
      return await AttendanceTrackerPlatform.instance.setWifiEnabled(enabled) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Open Wi-Fi settings.
  Future<void> openWifiSettings() async {
    try {
      await AttendanceTrackerPlatform.instance.openWifiSettings();
    } catch (_) {}
  }

  /// Check if all required services (GPS, Wi-Fi, Bluetooth) are enabled hardware-wise.
  Future<ServiceStatus> checkServicesStatus() async {
    // 1. GPS
    final isGpsEnabled = await Geolocator.isLocationServiceEnabled();

    // 2. Wi-Fi
    final wifiOn = await isWifiEnabled();

    // 3. BLE with timeout
    bool isBleEnabled = false;
    try {
      if (await FlutterBluePlus.isSupported) {
        final state = await FlutterBluePlus.adapterState.first.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => BluetoothAdapterState.unknown,
        );
        isBleEnabled = state == BluetoothAdapterState.on;
      }
    } catch (_) {}

    return ServiceStatus(isGpsEnabled: isGpsEnabled, isWifiEnabled: wifiOn, isBleEnabled: isBleEnabled);
  }

  /// Initialize the plugin with the provided configuration.
  ///
  /// Call this on every app launch: it also verifies NFC taps and
  /// `attendancetracker://` links that launched the app while it was killed.
  Future<void> initialize(AttendanceConfig config) async {
    _config = config;
    _ensureNativeHandler();
    await _platform.configure(config.toJson());
    if (Platform.isIOS) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(BackgroundExecutor.configKey, jsonEncode(config.toJson()));
    } else {
      await BackgroundExecutor.initialize(config);
    }
    await processPendingCheckpoints();
  }

  /// Start tracking attendance.
  Future<void> startTracking() async {
    _ensureNativeHandler();
    await _platform.setTrackingEnabled(true);
    if (!Platform.isIOS) {
      await BackgroundExecutor.start();
    }
  }

  /// Stop tracking attendance.
  Future<void> stopTracking() async {
    await _platform.setTrackingEnabled(false);
    if (!Platform.isIOS) {
      await BackgroundExecutor.stop();
    }
  }

  Future<bool> isTracking() => _platform.isTrackingEnabled();

  /// Manually trigger a detection scan immediately.
  Future<void> forceScan() async {
    if (Platform.isIOS) {
      _ensureNativeHandler();
      await _platform.scanNow(DetectionTrigger.manual);
    } else {
      await BackgroundExecutor.forceScan();
    }
  }

  /// A stream of detection results as they occur in the background.
  Stream<DetectionResult> get onResult => _results.stream;

  /// Enter, exit, checkpoint and shift-ended events as they are recorded.
  /// Events recorded while the app was killed are in [getPendingEvents].
  Stream<AttendanceEvent> get onEvent => _events.stream;

  /// A stream of 'ping' events from the background to verify it's alive.
  Stream<Map<String, dynamic>> get onPing => _pings.stream;

  /// Manually trigger a test vibration notification.
  Future<void> testVibration() async {
    if (Platform.isIOS) {
      await _platform.testNotification();
    } else {
      FlutterBackgroundService().invoke('testVibration');
    }
  }

  /// Manually check the current status (In-Zone/Out-of-Zone).
  Future<DetectionResult?> getLastResult() async {
    try {
      final map = await _platform.getLastResult();
      return map != null ? DetectionResult.fromJson(map) : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> isInZone() async {
    final result = await getLastResult();
    return result?.isInZone ?? false;
  }

  /// Events not yet acknowledged, oldest first — including ones recorded while
  /// the app was in the background or killed. Sync them to your server, then
  /// call [acknowledgeEvents].
  Future<List<AttendanceEvent>> getPendingEvents() async {
    final list = await _platform.getEvents(pendingOnly: true);
    return list.map(AttendanceEvent.fromJson).toList();
  }

  Future<void> acknowledgeEvents(List<String> ids) => _platform.acknowledgeEvents(ids);

  Future<bool> isNfcAvailable() async {
    try {
      return await _platform.isNfcAvailable();
    } catch (_) {
      return false;
    }
  }

  /// Waits for the user to tap an NFC checkpoint tag, verifies it and records
  /// attendance. Throws a [PlatformException] when NFC is unavailable, the
  /// user cancels, or [timeout] passes (Android; iOS ends its sheet after 60s).
  Future<CheckpointResult> scanNfc({
    String alertMessage = 'Hold your phone near the attendance tag.',
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final config = await _requireConfig();
    final tag = await _platform.readNfcTag(alertMessage: alertMessage, timeoutMs: timeout.inMilliseconds);
    final uid = tag?['uid'] as String?;
    final payloads = List<String>.from((tag?['payloads'] as List?) ?? const []);
    final verification = CheckpointVerifier.verifyNfc(uid: uid, payloads: payloads, config: config);
    return _commitCheckpoint(CheckpointSource.nfc, verification, tagUid: uid, tagPayloads: payloads);
  }

  /// Cancels a running [scanNfc].
  Future<void> cancelNfcScan() => _platform.stopNfcSession();

  /// Verifies a scanned QR value (from any scanner the host app uses) and
  /// records attendance when it is a valid checkpoint.
  Future<CheckpointResult> submitQrCode(String rawValue) async {
    final config = await _requireConfig();
    return _commitCheckpoint(CheckpointSource.qr, CheckpointVerifier.verifyQr(rawValue, config));
  }

  /// Handles a checkpoint link the host app received, e.g. a universal link
  /// written on an NFC tag (iOS background tag reading) or scanned by the camera.
  Future<CheckpointResult> handleCheckpointUri(Uri uri, {String source = CheckpointSource.qr}) async {
    final config = await _requireConfig();
    final verification = source == CheckpointSource.nfc
        ? CheckpointVerifier.verifyNfc(payloads: [uri.toString()], config: config)
        : CheckpointVerifier.verifyQr(uri.toString(), config);
    return _commitCheckpoint(source, verification);
  }

  /// Verifies NFC taps and `attendancetracker://` links captured natively while
  /// Dart was not running. Called by [initialize]; call it again on app resume.
  Future<List<CheckpointOutcome>> processPendingCheckpoints() async {
    final config = await _loadConfig();
    if (config == null) return const [];
    final outcomes = await CheckpointService.processPending(config);
    final valid = outcomes.where((o) => o.verification.isValid).toList();
    if (valid.isNotEmpty && !Platform.isIOS) {
      await BackgroundExecutor.notifyCheckpoint(valid.last.source);
    }
    return outcomes;
  }

  /// The QR content a kiosk should display right now for rotating codes.
  /// Regenerate it every [stepSeconds] (match [AttendanceConfig.qrStepSeconds]).
  static String generateKioskQrCode({
    required String secret,
    required String siteId,
    int stepSeconds = 30,
    bool asUri = false,
    DateTime? at,
  }) {
    return CheckpointVerifier.generateDynamicQr(
      secret: secret,
      siteId: siteId,
      stepSeconds: stepSeconds,
      asUri: asUri,
      at: at,
    );
  }

  Future<CheckpointResult> _commitCheckpoint(
    String source,
    CheckpointVerification verification, {
    String? tagUid,
    List<String> tagPayloads = const [],
  }) async {
    if (!verification.isValid) {
      return CheckpointResult(
        source: source,
        verification: verification,
        tagUid: tagUid,
        tagPayloads: tagPayloads,
      );
    }

    _ensureNativeHandler();
    final native = await CheckpointService.record(source, verification.checkpointId!);
    DetectionResult detection;
    if (native != null) {
      // iOS evaluated the zone natively (and already emitted onDetection).
      detection = DetectionResult.fromJson(native);
    } else {
      final last = await getLastResult();
      final config = await _requireConfig();
      detection = DetectionResult(
        isInZone: config.isWithinShift(DateTime.now()),
        byNfc: source == CheckpointSource.nfc,
        byQr: source == CheckpointSource.qr,
        checkpointId: verification.checkpointId,
        status: last?.status ?? ServiceStatus(isGpsEnabled: false, isWifiEnabled: false, isBleEnabled: false),
        trigger: source,
        timestamp: DateTime.now(),
        diagnosticLog: 'CHECKPOINT: ${source.toUpperCase()} "${verification.checkpointId}" verified.\n',
      );
      _results.add(detection);
      await BackgroundExecutor.notifyCheckpoint(source);
    }
    return CheckpointResult(
      source: source,
      verification: verification,
      detection: detection,
      tagUid: tagUid,
      tagPayloads: tagPayloads,
    );
  }

  Future<AttendanceConfig> _requireConfig() async {
    final config = await _loadConfig();
    if (config == null) {
      throw StateError('AttendanceTracker.initialize() must be called before using checkpoints.');
    }
    return config;
  }

  Future<AttendanceConfig?> _loadConfig() async {
    if (_config != null) return _config;
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(BackgroundExecutor.configKey);
    if (json == null) return null;
    return _config = AttendanceConfig.fromJson(jsonDecode(json));
  }

  void _ensureNativeHandler() {
    if (_nativeHandlerSet) return;
    _nativeHandlerSet = true;
    _platform.setNativeCallHandler(_onNativeCall);
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'onDetection':
        if (args is Map) _results.add(DetectionResult.fromJson(args));
        break;
      case 'onEvent':
        if (args is Map) _events.add(AttendanceEvent.fromJson(args));
        break;
      case 'onPing':
        if (args is Map) _pings.add(Map<String, dynamic>.from(args));
        break;
      case 'onPendingCheckpoint':
        await processPendingCheckpoints();
        break;
    }
    return null;
  }

  /// Bridges flutter_background_service events (Android) into the public streams.
  void _listenToService() {
    _ensureNativeHandler();
    if (Platform.isIOS || _serviceSubscriptions.isNotEmpty) return;
    final service = FlutterBackgroundService();
    _serviceSubscriptions
      ..add(service.on('onUpdate').listen((e) {
        if (e != null) _results.add(DetectionResult.fromJson(e));
      }))
      ..add(service.on('onEvent').listen((e) {
        if (e != null) _events.add(AttendanceEvent.fromJson(e));
      }))
      ..add(service.on('ping').listen((e) {
        if (e != null) _pings.add(e);
      }));
  }
}
