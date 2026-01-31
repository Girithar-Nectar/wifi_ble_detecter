import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'services/background_executor.dart';
import 'services/detection_fusion.dart';
import 'models/attendance_config.dart';

export 'models/attendance_config.dart';
export 'services/detection_fusion.dart';

class AttendanceTracker {
  static final AttendanceTracker _instance = AttendanceTracker._internal();
  factory AttendanceTracker() => _instance;
  AttendanceTracker._internal();

  /// Initialize the plugin with the provided configuration.
  /// This should be called in main() before runApp().
  Future<void> initialize(AttendanceConfig config) async {
    await BackgroundExecutor.initialize(config);
  }

  /// Start tracking attendance.
  Future<void> startTracking() async {
    await BackgroundExecutor.start();
  }

  /// Stop tracking attendance.
  Future<void> stopTracking() async {
    await BackgroundExecutor.stop();
  }

  /// Manually trigger a detection scan immediately.
  Future<void> forceScan() async {
    await BackgroundExecutor.forceScan();
  }

  /// A stream of detection results as they occur in the background.
  Stream<DetectionResult> get onResult {
    return FlutterBackgroundService().on('onUpdate').map((event) {
      return _mapToResult(event!);
    });
  }

  /// Manually check the current status (In-Zone/Out-of-Zone).
  Future<DetectionResult?> getLastResult() async {
    return await BackgroundExecutor.getLastResult();
  }

  Future<bool> isInZone() async {
    final result = await BackgroundExecutor.getLastResult();
    return result?.isInZone ?? false;
  }

  DetectionResult _mapToResult(Map<String, dynamic> map) {
    return DetectionResult(
      isInZone: map['isInZone'],
      byGps: map['byGps'],
      byWifi: map['byWifi'],
      byBle: map['byBle'],
      distance: map['distance'],
      diagnosticLog: map['diagnosticLog'] ?? "",
      status: ServiceStatus(
        isGpsEnabled: map['status']['isGpsEnabled'],
        isWifiEnabled: map['status']['isWifiEnabled'],
        isBleEnabled: map['status']['isBleEnabled'],
      ),
    );
  }
}
