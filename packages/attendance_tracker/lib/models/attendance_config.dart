import 'package:flutter/material.dart';

class AttendanceConfig {
  /// Latitude of the office center.
  final double officeLatitude;

  /// Longitude of the office center.
  final double officeLongitude;

  /// Radius around the office center in meters for the geofence.
  final double geofenceRadius;

  /// List of Wi-Fi SSIDs that confirm presence.
  final List<String> wifiSSIDs;

  /// List of BLE Device Names that confirm presence.
  final List<String> bleDeviceNames;

  /// The time when the shift starts (e.g., 09:00).
  final TimeOfDay shiftStart;

  /// The time when the shift ends (e.g., 18:00).
  final TimeOfDay shiftEnd;

  /// Optional: A URL to hit for automatic check-in/check-out.
  final String? apiEndpoint;

  /// Optional: Headers for the API request.
  final Map<String, String>? apiHeaders;

  AttendanceConfig({
    required this.officeLatitude,
    required this.officeLongitude,
    this.geofenceRadius = 100.0,
    this.wifiSSIDs = const [],
    this.bleDeviceNames = const [],
    required this.shiftStart,
    required this.shiftEnd,
    this.apiEndpoint,
    this.apiHeaders,
  });

  Map<String, dynamic> toJson() => {
    'officeLatitude': officeLatitude,
    'officeLongitude': officeLongitude,
    'geofenceRadius': geofenceRadius,
    'wifiSSIDs': wifiSSIDs,
    'bleDeviceNames': bleDeviceNames,
    'shiftStartHour': shiftStart.hour,
    'shiftStartMinute': shiftStart.minute,
    'shiftEndHour': shiftEnd.hour,
    'shiftEndMinute': shiftEnd.minute,
    'apiEndpoint': apiEndpoint,
    'apiHeaders': apiHeaders,
  };

  factory AttendanceConfig.fromJson(Map<String, dynamic> json) => AttendanceConfig(
    officeLatitude: json['officeLatitude'],
    officeLongitude: json['officeLongitude'],
    geofenceRadius: json['geofenceRadius'] ?? 100.0,
    wifiSSIDs: List<String>.from(json['wifiSSIDs'] ?? []),
    bleDeviceNames: List<String>.from(json['bleDeviceNames'] ?? []),
    shiftStart: TimeOfDay(hour: json['shiftStartHour'], minute: json['shiftStartMinute']),
    shiftEnd: TimeOfDay(hour: json['shiftEndHour'], minute: json['shiftEndMinute']),
    apiEndpoint: json['apiEndpoint'],
    apiHeaders: json['apiHeaders'] != null ? Map<String, String>.from(json['apiHeaders']) : null,
  );
}
