import 'detection_result.dart';

/// Kinds of attendance event. The string values are shared with the native
/// Android and iOS code, which records events while Dart is not running.
class AttendanceEventType {
  static const enter = 'enter';
  static const exit = 'exit';
  static const checkpoint = 'checkpoint';
  static const shiftEnded = 'shiftEnded';
}

/// Where the app was when the event was recorded.
class AttendanceAppState {
  static const foreground = 'foreground';
  static const background = 'background';

  /// The app was launched by the OS for this event (it had been killed).
  static const terminated = 'terminated';
}

/// One attendance transition, kept in a native queue until the host app
/// acknowledges it (and, when `apiEndpoint` is set, until it is uploaded).
class AttendanceEvent {
  final String id;

  /// One of [AttendanceEventType].
  final String type;

  /// gps, wifi, ble, beacon, nfc, qr, or null for exits.
  final String? source;

  /// One of [DetectionTrigger].
  final String? trigger;

  /// One of [AttendanceAppState].
  final String? appState;

  final DateTime timestamp;
  final String? checkpointId;
  final double? latitude;
  final double? longitude;
  final double? accuracy;
  final String? wifiBssid;
  final String? wifiSsid;
  final String? bleDevice;
  final String? beacon;
  final bool uploaded;

  AttendanceEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    this.source,
    this.trigger,
    this.appState,
    this.checkpointId,
    this.latitude,
    this.longitude,
    this.accuracy,
    this.wifiBssid,
    this.wifiSsid,
    this.bleDevice,
    this.beacon,
    this.uploaded = false,
  });

  factory AttendanceEvent.fromDetection(
    String type,
    DetectionResult result, {
    String? appState,
    DateTime? at,
  }) {
    final time = at ?? DateTime.now();
    return AttendanceEvent(
      id: '${time.microsecondsSinceEpoch}-$type',
      type: type,
      timestamp: time,
      source: type == AttendanceEventType.exit || type == AttendanceEventType.shiftEnded ? null : result.source,
      trigger: result.trigger,
      appState: appState,
      checkpointId: result.checkpointId,
      latitude: result.latitude,
      longitude: result.longitude,
      accuracy: result.accuracy,
      wifiBssid: result.wifiBssid,
      wifiSsid: result.wifiSsid,
      bleDevice: result.bleDevice,
      beacon: result.beacon,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'source': source,
        'trigger': trigger,
        'appState': appState,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'checkpointId': checkpointId,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'wifiBssid': wifiBssid,
        'wifiSsid': wifiSsid,
        'bleDevice': bleDevice,
        'beacon': beacon,
        'uploaded': uploaded,
      };

  factory AttendanceEvent.fromJson(Map<dynamic, dynamic> json) => AttendanceEvent(
        id: json['id'] as String,
        type: json['type'] as String,
        source: json['source'],
        trigger: json['trigger'],
        appState: json['appState'],
        timestamp: DateTime.fromMillisecondsSinceEpoch((json['timestamp'] as num).toInt()),
        checkpointId: json['checkpointId'],
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        accuracy: (json['accuracy'] as num?)?.toDouble(),
        wifiBssid: json['wifiBssid'],
        wifiSsid: json['wifiSsid'],
        bleDevice: json['bleDevice'],
        beacon: json['beacon'],
        uploaded: json['uploaded'] ?? false,
      );

  @override
  String toString() => 'AttendanceEvent($type via ${source ?? '-'} at $timestamp)';
}
