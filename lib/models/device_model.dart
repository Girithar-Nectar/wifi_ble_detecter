// device_model.dart
import 'dart:convert';

class DeviceModel {
  final String id;
  final String name;
  final String type;
  final double? distance;
  final int? rssi;
  final String? ssid;
  final String? macAddress;
  final DateTime lastSeen;
  final DateTime? lastDetected;
  final bool isInRange;
  final double? latitude;
  final double? longitude;
  final List<String>? uuid;

  DeviceModel({
    required this.id,
    required this.name,
    required this.type,
    this.distance,
    this.rssi,
    this.ssid,
    this.macAddress,
    required this.lastSeen,
    this.lastDetected,
    this.isInRange = false,
    this.latitude,
    this.longitude,
    this.uuid,
  });

  factory DeviceModel.fromJson(Map<String, dynamic> json) {
    return DeviceModel(
      id: json['id'],
      name: json['name'],
      type: json['type'],
      distance: json['distance']?.toDouble(),
      rssi: json['rssi'],
      ssid: json['ssid'],
      macAddress: json['macAddress'],
      lastSeen: DateTime.parse(json['lastSeen']),
      lastDetected: json['lastDetected'] != null ? DateTime.parse(json['lastDetected']) : null,
      isInRange: json['isInRange'] ?? false,
      latitude: json['latitude']?.toDouble(),
      longitude: json['longitude']?.toDouble(),
      uuid: json['uuid'] != null ? List<String>.from(json['uuid']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'distance': distance,
      'rssi': rssi,
      'ssid': ssid,
      'macAddress': macAddress,
      'lastSeen': lastSeen.toIso8601String(),
      'lastDetected': lastDetected?.toIso8601String(),
      'isInRange': isInRange,
      'latitude': latitude,
      'longitude': longitude,
      'uuid': uuid,
    };
  }

  DeviceModel copyWith({
    String? id,
    String? name,
    String? type,
    double? distance,
    int? rssi,
    String? ssid,
    String? macAddress,
    DateTime? lastSeen,
    DateTime? lastDetected,
    bool? isInRange,
    double? latitude,
    double? longitude,
    List<String>? uuid,
  }) {
    return DeviceModel(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      distance: distance ?? this.distance,
      rssi: rssi ?? this.rssi,
      ssid: ssid ?? this.ssid,
      macAddress: macAddress ?? this.macAddress,
      lastSeen: lastSeen ?? this.lastSeen,
      lastDetected: lastDetected ?? this.lastDetected,
      isInRange: isInRange ?? this.isInRange,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      uuid: uuid ?? this.uuid,
    );
  }

  factory DeviceModel.defaultDevice(String id, String name) {
    return DeviceModel(
      id: id,
      name: name,
      type: 'ble_device',
      lastSeen: DateTime.now(),
      isInRange: false,
    );
  }

  @override
  String toString() {
    return 'DeviceModel(id: $id, name: $name, type: $type, distance: $distance, rssi: $rssi, isInRange: $isInRange, lastDetected: $lastDetected)';
  }
}