import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'attendance_tracker_platform_interface.dart';

/// An implementation of [AttendanceTrackerPlatform] that uses method channels.
class MethodChannelAttendanceTracker extends AttendanceTrackerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('attendance_tracker');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
