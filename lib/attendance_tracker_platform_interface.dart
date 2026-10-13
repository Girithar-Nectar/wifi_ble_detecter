import 'package:flutter/services.dart';
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

  /// Receives calls the native side makes on its own: `onDetection`, `onEvent`,
  /// `onPing`, `onPendingCheckpoint` and `onWake`.
  void setNativeCallHandler(Future<dynamic> Function(MethodCall call)? handler) {
    throw UnimplementedError('setNativeCallHandler() has not been implemented.');
  }

  /// Stores the config natively so native code can use it while Dart is not running.
  Future<void> configure(Map<String, dynamic> config) {
    throw UnimplementedError('configure() has not been implemented.');
  }

  /// Turns native monitoring on or off: geofences on Android; regions,
  /// significant changes, visits, iBeacons and periodic scans on iOS.
  Future<void> setTrackingEnabled(bool enabled) {
    throw UnimplementedError('setTrackingEnabled() has not been implemented.');
  }

  Future<bool> isTrackingEnabled() {
    throw UnimplementedError('isTrackingEnabled() has not been implemented.');
  }

  /// Re-registers native monitoring (e.g. after Android cleared its geofences).
  Future<void> refreshMonitoring() {
    throw UnimplementedError('refreshMonitoring() has not been implemented.');
  }

  /// iOS: runs a native detection now and returns the result.
  Future<Map<dynamic, dynamic>?> scanNow(String trigger) {
    throw UnimplementedError('scanNow() has not been implemented.');
  }

  Future<void> appendEvent(Map<String, dynamic> event) {
    throw UnimplementedError('appendEvent() has not been implemented.');
  }

  Future<List<Map<dynamic, dynamic>>> getEvents({bool pendingOnly = true}) {
    throw UnimplementedError('getEvents() has not been implemented.');
  }

  Future<void> acknowledgeEvents(List<String> ids) {
    throw UnimplementedError('acknowledgeEvents() has not been implemented.');
  }

  Future<void> markEventsUploaded(List<String> ids) {
    throw UnimplementedError('markEventsUploaded() has not been implemented.');
  }

  /// Stores a verified checkpoint and records a checkpoint event, or, with
  /// `checkpointToggle` while in zone, records a tap-out exit. Returns
  /// `{tapOut}`; iOS also evaluates the zone and returns the detection result.
  Future<Map<dynamic, dynamic>?> recordCheckpoint(Map<String, dynamic> checkpoint) {
    throw UnimplementedError('recordCheckpoint() has not been implemented.');
  }

  /// Native zone state shared by every engine: `{wasInZone, failCount, tapOutAt}`.
  Future<Map<dynamic, dynamic>> getZoneState() {
    throw UnimplementedError('getZoneState() has not been implemented.');
  }

  Future<void> setZoneState({required bool wasInZone, required int failCount}) {
    throw UnimplementedError('setZoneState() has not been implemented.');
  }

  /// Forgets presence: out of zone, no fail count, no tap-out, no checkpoint.
  Future<void> resetZoneState() {
    throw UnimplementedError('resetZoneState() has not been implemented.');
  }

  Future<Map<dynamic, dynamic>?> getLastCheckpoint() {
    throw UnimplementedError('getLastCheckpoint() has not been implemented.');
  }

  /// Raw, not yet verified checkpoints captured natively (NFC tap or
  /// `attendancetracker://` link that launched the app). Each is returned once.
  Future<List<Map<dynamic, dynamic>>> takePendingCheckpoints() {
    throw UnimplementedError('takePendingCheckpoints() has not been implemented.');
  }

  Future<void> saveLastResult(Map<String, dynamic> result) {
    throw UnimplementedError('saveLastResult() has not been implemented.');
  }

  Future<Map<dynamic, dynamic>?> getLastResult() {
    throw UnimplementedError('getLastResult() has not been implemented.');
  }

  Future<bool> isNfcAvailable() {
    throw UnimplementedError('isNfcAvailable() has not been implemented.');
  }

  /// Waits for one NFC tag and returns `{uid, payloads}`.
  Future<Map<dynamic, dynamic>?> readNfcTag({String? alertMessage, int timeoutMs = 30000}) {
    throw UnimplementedError('readNfcTag() has not been implemented.');
  }

  Future<void> stopNfcSession() {
    throw UnimplementedError('stopNfcSession() has not been implemented.');
  }

  Future<bool> isIgnoringBatteryOptimizations() {
    throw UnimplementedError('isIgnoringBatteryOptimizations() has not been implemented.');
  }

  Future<bool> requestIgnoreBatteryOptimizations() {
    throw UnimplementedError('requestIgnoreBatteryOptimizations() has not been implemented.');
  }

  /// iOS: shows a test notification through the native notifier.
  Future<void> testNotification() {
    throw UnimplementedError('testNotification() has not been implemented.');
  }
}
