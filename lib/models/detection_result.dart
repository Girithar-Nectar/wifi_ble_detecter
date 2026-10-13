class ServiceStatus {
  final bool isGpsEnabled;
  final bool isWifiEnabled;
  final bool isBleEnabled;

  ServiceStatus({required this.isGpsEnabled, required this.isWifiEnabled, required this.isBleEnabled});

  Map<String, dynamic> toJson() => {
        'isGpsEnabled': isGpsEnabled,
        'isWifiEnabled': isWifiEnabled,
        'isBleEnabled': isBleEnabled,
      };

  factory ServiceStatus.fromJson(Map<dynamic, dynamic>? json) => ServiceStatus(
        isGpsEnabled: json?['isGpsEnabled'] ?? false,
        isWifiEnabled: json?['isWifiEnabled'] ?? false,
        isBleEnabled: json?['isBleEnabled'] ?? false,
      );
}

/// What woke the tracker up for a detection.
class DetectionTrigger {
  static const timer = 'timer';
  static const manual = 'manual';
  static const region = 'region';
  static const significantChange = 'significantChange';
  static const visit = 'visit';
  static const backgroundFetch = 'backgroundFetch';
  static const geofence = 'geofence';
  static const boot = 'boot';
  static const nfc = 'nfc';
  static const qr = 'qr';
}

class DetectionResult {
  final bool isInZone;
  final bool byGps;
  final bool byWifi;
  final bool byBle;

  /// Matched an iBeacon (CoreLocation on iOS, advertisement parsing on Android).
  final bool byBeacon;

  /// Presence comes from a still-valid NFC tap.
  final bool byNfc;

  /// Presence comes from a still-valid QR scan.
  final bool byQr;

  final double? distance;
  final ServiceStatus status;
  final String diagnosticLog;

  /// Evidence for the server: what was actually seen.
  final double? latitude;
  final double? longitude;
  final double? accuracy;
  final String? wifiBssid;
  final String? wifiSsid;
  final String? bleDevice;
  final String? beacon;
  final String? checkpointId;

  /// One of [DetectionTrigger].
  final String? trigger;
  final DateTime? timestamp;

  DetectionResult({
    required this.isInZone,
    this.byGps = false,
    this.byWifi = false,
    this.byBle = false,
    this.byBeacon = false,
    this.byNfc = false,
    this.byQr = false,
    this.distance,
    required this.status,
    this.diagnosticLog = "",
    this.latitude,
    this.longitude,
    this.accuracy,
    this.wifiBssid,
    this.wifiSsid,
    this.bleDevice,
    this.beacon,
    this.checkpointId,
    this.trigger,
    this.timestamp,
  });

  /// The strongest signal that proved presence, or null when out of zone.
  String? get source {
    if (byNfc) return 'nfc';
    if (byQr) return 'qr';
    if (byBeacon) return 'beacon';
    if (byWifi) return 'wifi';
    if (byBle) return 'ble';
    if (byGps) return 'gps';
    return null;
  }

  DetectionResult copyWith({
    bool? isInZone,
    bool? byNfc,
    bool? byQr,
    String? checkpointId,
    String? trigger,
    String? diagnosticLog,
  }) {
    return DetectionResult(
      isInZone: isInZone ?? this.isInZone,
      byGps: byGps,
      byWifi: byWifi,
      byBle: byBle,
      byBeacon: byBeacon,
      byNfc: byNfc ?? this.byNfc,
      byQr: byQr ?? this.byQr,
      distance: distance,
      status: status,
      diagnosticLog: diagnosticLog ?? this.diagnosticLog,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      wifiBssid: wifiBssid,
      wifiSsid: wifiSsid,
      bleDevice: bleDevice,
      beacon: beacon,
      checkpointId: checkpointId ?? this.checkpointId,
      trigger: trigger ?? this.trigger,
      timestamp: timestamp,
    );
  }

  Map<String, dynamic> toJson() => {
        'isInZone': isInZone,
        'byGps': byGps,
        'byWifi': byWifi,
        'byBle': byBle,
        'byBeacon': byBeacon,
        'byNfc': byNfc,
        'byQr': byQr,
        'distance': distance,
        'diagnosticLog': diagnosticLog,
        'status': status.toJson(),
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'wifiBssid': wifiBssid,
        'wifiSsid': wifiSsid,
        'bleDevice': bleDevice,
        'beacon': beacon,
        'checkpointId': checkpointId,
        'trigger': trigger,
        'timestamp': timestamp?.millisecondsSinceEpoch,
      };

  factory DetectionResult.fromJson(Map<dynamic, dynamic> map) {
    final ts = (map['timestamp'] as num?)?.toInt();
    return DetectionResult(
      isInZone: map['isInZone'] ?? false,
      byGps: map['byGps'] ?? false,
      byWifi: map['byWifi'] ?? false,
      byBle: map['byBle'] ?? false,
      byBeacon: map['byBeacon'] ?? false,
      byNfc: map['byNfc'] ?? false,
      byQr: map['byQr'] ?? false,
      distance: (map['distance'] as num?)?.toDouble(),
      diagnosticLog: map['diagnosticLog'] ?? "",
      status: ServiceStatus.fromJson(map['status'] as Map?),
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      accuracy: (map['accuracy'] as num?)?.toDouble(),
      wifiBssid: map['wifiBssid'],
      wifiSsid: map['wifiSsid'],
      bleDevice: map['bleDevice'],
      beacon: map['beacon'],
      checkpointId: map['checkpointId'],
      trigger: map['trigger'],
      timestamp: ts != null ? DateTime.fromMillisecondsSinceEpoch(ts) : null,
    );
  }
}
