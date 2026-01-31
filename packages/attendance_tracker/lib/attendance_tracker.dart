import 'dart:async';
export 'models/attendance_config.dart';
import 'models/attendance_config.dart';
import 'services/background_executor.dart';
export 'services/detection_fusion.dart' show DetectionResult;

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

  /// Manually check the current status (In-Zone/Out-of-Zone).
  Future<bool> isInZone() async {
    return await BackgroundExecutor.checkCurrentStatus();
  }
}
