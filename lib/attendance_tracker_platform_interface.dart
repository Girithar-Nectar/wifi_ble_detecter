import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'attendance_tracker_method_channel.dart';

abstract class AttendanceTrackerPlatform extends PlatformInterface {
  /// Constructs a AttendanceTrackerPlatform.
  AttendanceTrackerPlatform() : super(token: _token);

  static final Object _token = Object();

  static AttendanceTrackerPlatform _instance = MethodChannelAttendanceTracker();

  /// The default instance of [AttendanceTrackerPlatform] to use.
  ///
  /// Defaults to [MethodChannelAttendanceTracker].
  static AttendanceTrackerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [AttendanceTrackerPlatform] when
  /// they register themselves.
  static set instance(AttendanceTrackerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<int?> getAndroidSdkInt() {
    throw UnimplementedError('getAndroidSdkInt() has not been implemented.');
  }

  Future<bool?> isWifiEnabled() {
    throw UnimplementedError('isWifiEnabled() has not been implemented.');
  }

  Future<bool?> openWifiSettings() {
    throw UnimplementedError('openWifiSettings() has not been implemented.');
  }

  Future<bool?> setWifiEnabled(bool enabled) {
    throw UnimplementedError('setWifiEnabled() has not been implemented.');
  }
}
