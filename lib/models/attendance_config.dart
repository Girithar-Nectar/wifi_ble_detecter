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
  /// iOS never exposes MAC addresses, so on iOS use [bleDeviceNames] or [iBeacons].
  final List<String> bleMACs;

  /// List of BLE Service UUIDs to filter for (CRITICAL for iOS background scanning).
  final List<String> bleServiceUuids;

  /// iBeacons that confirm presence, as "UUID", "UUID:major" or "UUID:major:minor".
  /// On iOS these are monitored by CoreLocation, which relaunches a killed app
  /// when the phone enters or leaves the beacon's range.
  final List<String> iBeacons;

  /// NFC checkpoints: tag UIDs (hex, separators ignored) or checkpoint ids written
  /// on the tag as NDEF text or as an `attendancetracker://checkpoint?id=<id>` URI.
  final List<String> nfcTags;

  /// Static QR checkpoints: the exact QR content or the checkpoint id in its URI.
  final List<String> qrCodes;

  /// Secret for rotating QR codes (shown on a kiosk, see [AttendanceTracker.generateKioskQrCode]).
  /// When null, only [qrCodes] are accepted.
  final String? qrSecret;

  /// Site id a rotating QR code must carry. When null, any site signed with [qrSecret] is accepted.
  final String? qrSiteId;

  /// How long one rotating QR code stays valid, in seconds.
  final int qrStepSeconds;

  /// How many steps before or after the current one are still accepted (clock drift).
  final int qrDriftSteps;

  /// How long an NFC tap or QR scan keeps the user in the zone when no other
  /// sensor matches. 0 keeps it until the current shift ends.
  final int checkpointValidityMinutes;

  /// When true, an NFC tap or QR scan while the user is already in the zone
  /// checks them out (tap in at the entrance, tap out when leaving).
  final bool checkpointToggle;

  /// After a tap-out, Wi-Fi/BLE/GPS/iBeacon matches do not check the user back
  /// in for this many minutes (they may still be in range while walking out).
  final int tapOutCooldownMinutes;

  /// iOS only: keep a low-power location session running during the shift so
  /// periodic scans continue while the app is in the background.
  final bool iosContinuousTracking;

  /// The time when the shift starts (milliseconds from start of day).
  final int shiftStartMs;

  /// The time when the shift ends (milliseconds from start of day).
  final int shiftEndMs;

  /// How often to perform background scans (in seconds).
  final int scanIntervalSeconds;

  /// Optional: A URL that every attendance event is POSTed to as JSON, including
  /// events recorded while the app is killed (iOS posts natively).
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

  /// Number of consecutive failed scans required before declaring "out of zone".
  /// Higher values prevent false "leaving" notifications. Default: 3.
  final int exitDebounceCount;

  AttendanceConfig({
    required this.officePoints,
    this.geofenceRadius = 100.0,
    this.wifiSSIDs = const [],
    this.wifiBSSIDs = const [],
    this.bleDeviceNames = const [],
    this.bleMACs = const [],
    this.bleServiceUuids = const [],
    this.iBeacons = const [],
    this.nfcTags = const [],
    this.qrCodes = const [],
    this.qrSecret,
    this.qrSiteId,
    this.qrStepSeconds = 30,
    this.qrDriftSteps = 1,
    this.checkpointValidityMinutes = 60,
    this.checkpointToggle = false,
    this.tapOutCooldownMinutes = 5,
    this.iosContinuousTracking = true,
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
    this.exitDebounceCount = 3,
  });

  bool get hasWifi => wifiSSIDs.isNotEmpty || wifiBSSIDs.isNotEmpty;
  bool get hasBle => bleDeviceNames.isNotEmpty || bleMACs.isNotEmpty;
  bool get hasBeacons => iBeacons.isNotEmpty;
  bool get hasNfc => nfcTags.isNotEmpty;
  bool get hasQr => qrCodes.isNotEmpty || (qrSecret != null && qrSecret!.isNotEmpty);
  bool get hasGps => officePoints.isNotEmpty;

  /// Whether anything is sensed without the user acting (everything except NFC/QR).
  bool get hasPassiveSensors => hasGps || hasWifi || hasBle || hasBeacons;

  Map<String, dynamic> toJson() {
    return {
      'officePoints': officePoints,
      'geofenceRadius': geofenceRadius,
      'wifiSSIDs': wifiSSIDs,
      'wifiBSSIDs': wifiBSSIDs,
      'bleDeviceNames': bleDeviceNames,
      'bleMACs': bleMACs,
      'bleServiceUuids': bleServiceUuids,
      'iBeacons': iBeacons,
      'nfcTags': nfcTags,
      'qrCodes': qrCodes,
      'qrSecret': qrSecret,
      'qrSiteId': qrSiteId,
      'qrStepSeconds': qrStepSeconds,
      'qrDriftSteps': qrDriftSteps,
      'checkpointValidityMinutes': checkpointValidityMinutes,
      'checkpointToggle': checkpointToggle,
      'tapOutCooldownMinutes': tapOutCooldownMinutes,
      'iosContinuousTracking': iosContinuousTracking,
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
      'exitDebounceCount': exitDebounceCount,
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
      iBeacons: List<String>.from(json['iBeacons'] ?? []),
      nfcTags: List<String>.from(json['nfcTags'] ?? []),
      qrCodes: List<String>.from(json['qrCodes'] ?? []),
      qrSecret: json['qrSecret'],
      qrSiteId: json['qrSiteId'],
      qrStepSeconds: (json['qrStepSeconds'] as num?)?.toInt() ?? 30,
      qrDriftSteps: (json['qrDriftSteps'] as num?)?.toInt() ?? 1,
      checkpointValidityMinutes: (json['checkpointValidityMinutes'] as num?)?.toInt() ?? 60,
      checkpointToggle: json['checkpointToggle'] ?? false,
      tapOutCooldownMinutes: (json['tapOutCooldownMinutes'] as num?)?.toInt() ?? 5,
      iosContinuousTracking: json['iosContinuousTracking'] ?? true,
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
      exitDebounceCount: (json['exitDebounceCount'] as num?)?.toInt() ?? 3,
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

  /// Whether [now] falls inside the shift window.
  bool isWithinShift(DateTime now) {
    final currentMs = _msOfDay(now);
    if (shiftStartMs <= shiftEndMs) {
      return currentMs >= shiftStartMs && currentMs <= shiftEndMs;
    }
    // Shift spans across midnight (e.g., 22:00 to 06:00)
    return currentMs >= shiftStartMs || currentMs <= shiftEndMs;
  }

  /// Start of the shift that contains [now] (or the most recent one).
  DateTime currentShiftStart(DateTime now) {
    final midnight = DateTime(now.year, now.month, now.day);
    final todayStart = midnight.add(Duration(milliseconds: shiftStartMs));
    return todayStart.isAfter(now) ? todayStart.subtract(const Duration(days: 1)) : todayStart;
  }

  /// Whether a checkpoint recorded at [checkpointAt] still proves presence at [now].
  bool isCheckpointValid(DateTime checkpointAt, DateTime now) {
    if (checkpointAt.isAfter(now.add(const Duration(minutes: 1)))) return false;
    if (checkpointValidityMinutes > 0) {
      return now.difference(checkpointAt) <= Duration(minutes: checkpointValidityMinutes);
    }
    return isWithinShift(now) && !checkpointAt.isBefore(currentShiftStart(now));
  }

  static int _msOfDay(DateTime t) => (t.hour * 3600000) + (t.minute * 60000) + (t.second * 1000) + t.millisecond;
}
