// Attendance Configuration Model

class AttendanceConfig {
  /// List of office locations in WKT POINT format: "POINT(longitude latitude)"
  final List<String> officePoints;

  /// Radius around the office center in meters for the geofence.
  final double geofenceRadius;

  /// List of Wi-Fi SSIDs that confirm presence.
  final List<String> wifiSSIDs;

  /// List of Wi-Fi BSSIDs (MAC Addresses) that confirm presence.
  final List<String> wifiBSSIDs;

  /// List of BLE Device Names that confirm presence.
  final List<String> bleDeviceNames;

  /// List of BLE MAC Addresses (or Platform IDs) that confirm presence.
  final List<String> bleMACs;

  /// List of BLE Service UUIDs to filter for (CRITICAL for iOS background scanning).
  final List<String> bleServiceUuids;

  /// The time when the shift starts (milliseconds from start of day).
  final int shiftStartMs;

  /// The time when the shift ends (milliseconds from start of day).
  final int shiftEndMs;

  /// How often to perform background scans (in seconds).
  final int scanIntervalSeconds;

  /// Optional: A URL to hit for automatic check-in/check-out.
  final String? apiEndpoint;

  /// Optional: Headers for the API request.
  final Map<String, String>? apiHeaders;

  // Custom Notifications
  final String welcomeTitle;
  final String welcomeBody;
  final String outOfZoneTitle;
  final String outOfZoneBody;
  final String shiftEndedTitle;
  final String shiftEndedBody;

  /// Custom vibration pattern for welcome [wait, dash, wait, dash...].
  final List<int>? welcomeVibration;

  /// Custom vibration pattern for out of zone.
  final List<int>? outOfZoneVibration;

  /// Custom sound for welcome (no extension for Android, with extension for iOS).
  final String? welcomeSound;

  /// Custom sound for out of zone.
  final String? outOfZoneSound;

  /// Whether to speak the notification content aloud using TTS.
  final bool enableTts;

  AttendanceConfig({
    required this.officePoints,
    this.geofenceRadius = 100.0,
    this.wifiSSIDs = const [],
    this.wifiBSSIDs = const [],
    this.bleDeviceNames = const [],
    this.bleMACs = const [],
    this.bleServiceUuids = const [],
    required this.shiftStartMs,
    required this.shiftEndMs,
    this.scanIntervalSeconds = 60,
    this.apiEndpoint,
    this.apiHeaders,
    this.welcomeTitle = 'Welcome!',
    this.welcomeBody = 'You are in the office zone. Check-in detected.',
    this.outOfZoneTitle = 'Out of Zone',
    this.outOfZoneBody = 'You left the office. Don\'t forget to take a break or checkout.',
    this.shiftEndedTitle = 'Shift Ended',
    this.shiftEndedBody = 'You are outside shift hours. Automatically checking you out.',
    this.welcomeVibration,
    this.outOfZoneVibration,
    this.welcomeSound,
    this.outOfZoneSound,
    this.enableTts = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'officePoints': officePoints,
      'geofenceRadius': geofenceRadius,
      'wifiSSIDs': wifiSSIDs,
      'wifiBSSIDs': wifiBSSIDs,
      'bleDeviceNames': bleDeviceNames,
      'bleMACs': bleMACs,
      'bleServiceUuids': bleServiceUuids,
      'shiftStartMs': shiftStartMs,
      'shiftEndMs': shiftEndMs,
      'scanIntervalSeconds': scanIntervalSeconds,
      'apiEndpoint': apiEndpoint,
      'apiHeaders': apiHeaders,
      'welcomeTitle': welcomeTitle,
      'welcomeBody': welcomeBody,
      'outOfZoneTitle': outOfZoneTitle,
      'outOfZoneBody': outOfZoneBody,
      'shiftEndedTitle': shiftEndedTitle,
      'shiftEndedBody': shiftEndedBody,
      'welcomeVibration': welcomeVibration,
      'outOfZoneVibration': outOfZoneVibration,
      'welcomeSound': welcomeSound,
      'outOfZoneSound': outOfZoneSound,
      'enableTts': enableTts,
    };
  }

  factory AttendanceConfig.fromJson(Map<String, dynamic> json) {
    return AttendanceConfig(
      officePoints: List<String>.from(json['officePoints'] ?? []),
      geofenceRadius: (json['geofenceRadius'] as num?)?.toDouble() ?? 100.0,
      wifiSSIDs: List<String>.from(json['wifiSSIDs'] ?? []),
      wifiBSSIDs: List<String>.from(json['wifiBSSIDs'] ?? []),
      bleDeviceNames: List<String>.from(json['bleDeviceNames'] ?? []),
      bleMACs: List<String>.from(json['bleMACs'] ?? []),
      bleServiceUuids: List<String>.from(json['bleServiceUuids'] ?? []),
      shiftStartMs: (json['shiftStartMs'] as num?)?.toInt() ?? 0,
      shiftEndMs: (json['shiftEndMs'] as num?)?.toInt() ?? 86399000,
      scanIntervalSeconds: (json['scanIntervalSeconds'] as num?)?.toInt() ?? 60,
      apiEndpoint: json['apiEndpoint'],
      apiHeaders: json['apiHeaders'] != null ? Map<String, String>.from(json['apiHeaders']) : null,
      welcomeTitle: json['welcomeTitle'] ?? 'Welcome!',
      welcomeBody: json['welcomeBody'] ?? 'You are in the office zone. Check-in detected.',
      outOfZoneTitle: json['outOfZoneTitle'] ?? 'Out of Zone',
      outOfZoneBody: json['outOfZoneBody'] ?? 'You left the office. Don\'t forget to take a break or checkout.',
      shiftEndedTitle: json['shiftEndedTitle'] ?? 'Shift Ended',
      shiftEndedBody: json['shiftEndedBody'] ?? 'You are outside shift hours. Automatically checking you out.',
      welcomeVibration: json['welcomeVibration'] != null ? List<int>.from(json['welcomeVibration']) : null,
      outOfZoneVibration: json['outOfZoneVibration'] != null ? List<int>.from(json['outOfZoneVibration']) : null,
      welcomeSound: json['welcomeSound'],
      outOfZoneSound: json['outOfZoneSound'],
      enableTts: json['enableTts'] ?? false,
    );
  }

  /// Parses a WKT POINT string "POINT(long lat)" into a [MapEntry] of latitude and longitude.
  static MapEntry<double, double>? parseWktPoint(String wkt) {
    try {
      final match = RegExp(r"POINT\s*\(\s*(-?\d+\.?\d*)\s+(-?\d+\.?\d*)\s*\)", caseSensitive: false).firstMatch(wkt);
      if (match != null) {
        final lon = double.parse(match.group(1)!);
        final lat = double.parse(match.group(2)!);
        return MapEntry(lat, lon);
      }
    } catch (e) {
      // Ignore parse errors
    }
    return null;
  }
}
