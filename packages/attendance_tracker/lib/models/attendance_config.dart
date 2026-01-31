// Attendance Configuration Model

class AttendanceConfig {
  /// Latitude of the office center.
  final double officeLatitude;

  /// Longitude of the office center.
  final double officeLongitude;

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

  /// The time when the shift starts (milliseconds from start of day).
  final int shiftStartMs;

  /// The time when the shift ends (milliseconds from start of day).
  final int shiftEndMs;

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

  AttendanceConfig({
    required this.officeLatitude,
    required this.officeLongitude,
    this.geofenceRadius = 100.0,
    this.wifiSSIDs = const [],
    this.wifiBSSIDs = const [],
    this.bleDeviceNames = const [],
    this.bleMACs = const [],
    required this.shiftStartMs,
    required this.shiftEndMs,
    this.apiEndpoint,
    this.apiHeaders,
    this.welcomeTitle = 'Welcome!',
    this.welcomeBody = 'You are in the office zone. Check-in detected.',
    this.outOfZoneTitle = 'Out of Zone',
    this.outOfZoneBody = 'You left the office. Don\'t forget to take a break or checkout.',
    this.shiftEndedTitle = 'Shift Ended',
    this.shiftEndedBody = 'You are outside shift hours. Automatically checking you out.',
  });

  Map<String, dynamic> toJson() {
    return {
      'officeLatitude': officeLatitude,
      'officeLongitude': officeLongitude,
      'geofenceRadius': geofenceRadius,
      'wifiSSIDs': wifiSSIDs,
      'wifiBSSIDs': wifiBSSIDs,
      'bleDeviceNames': bleDeviceNames,
      'bleMACs': bleMACs,
      'shiftStartMs': shiftStartMs,
      'shiftEndMs': shiftEndMs,
      'apiEndpoint': apiEndpoint,
      'apiHeaders': apiHeaders,
      'welcomeTitle': welcomeTitle,
      'welcomeBody': welcomeBody,
      'outOfZoneTitle': outOfZoneTitle,
      'outOfZoneBody': outOfZoneBody,
      'shiftEndedTitle': shiftEndedTitle,
      'shiftEndedBody': shiftEndedBody,
    };
  }

  factory AttendanceConfig.fromJson(Map<String, dynamic> json) {
    return AttendanceConfig(
      officeLatitude: json['officeLatitude'],
      officeLongitude: json['officeLongitude'],
      geofenceRadius: json['geofenceRadius'],
      wifiSSIDs: List<String>.from(json['wifiSSIDs'] ?? []),
      wifiBSSIDs: List<String>.from(json['wifiBSSIDs'] ?? []),
      bleDeviceNames: List<String>.from(json['bleDeviceNames'] ?? []),
      bleMACs: List<String>.from(json['bleMACs'] ?? []),
      shiftStartMs: json['shiftStartMs'],
      shiftEndMs: json['shiftEndMs'],
      apiEndpoint: json['apiEndpoint'],
      apiHeaders: json['apiHeaders'] != null ? Map<String, String>.from(json['apiHeaders']) : null,
      welcomeTitle: json['welcomeTitle'] ?? 'Welcome!',
      welcomeBody: json['welcomeBody'] ?? 'You are in the office zone. Check-in detected.',
      outOfZoneTitle: json['outOfZoneTitle'] ?? 'Out of Zone',
      outOfZoneBody: json['outOfZoneBody'] ?? 'You left the office. Don\'t forget to take a break or checkout.',
      shiftEndedTitle: json['shiftEndedTitle'] ?? 'Shift Ended',
      shiftEndedBody: json['shiftEndedBody'] ?? 'You are outside shift hours. Automatically checking you out.',
    );
  }
}
