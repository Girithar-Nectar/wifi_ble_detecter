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

  @override
  Future<int?> getAndroidSdkInt() async {
    return await methodChannel.invokeMethod<int>('getAndroidSdkInt');
  }

  @override
  Future<bool?> isWifiEnabled() async {
    return await methodChannel.invokeMethod<bool>('isWifiEnabled');
  }

  @override
  Future<bool?> openWifiSettings() async {
    return await methodChannel.invokeMethod<bool>('openWifiSettings');
  }

  @override
  Future<bool?> setWifiEnabled(bool enabled) async {
    return await methodChannel.invokeMethod<bool>('setWifiEnabled', {'enabled': enabled});
  }

  @override
  void setNativeCallHandler(Future<dynamic> Function(MethodCall call)? handler) {
    methodChannel.setMethodCallHandler(handler);
  }

  @override
  Future<void> configure(Map<String, dynamic> config) async {
    await methodChannel.invokeMethod<void>('configure', {'config': config});
  }

  @override
  Future<void> setTrackingEnabled(bool enabled) async {
    await methodChannel.invokeMethod<void>('setTrackingEnabled', {'enabled': enabled});
  }

  @override
  Future<bool> isTrackingEnabled() async {
    return await methodChannel.invokeMethod<bool>('isTrackingEnabled') ?? false;
  }

  @override
  Future<void> refreshMonitoring() async {
    await methodChannel.invokeMethod<void>('refreshMonitoring');
  }

  @override
  Future<Map<dynamic, dynamic>?> scanNow(String trigger) async {
    return await methodChannel.invokeMethod<Map<dynamic, dynamic>>('scanNow', {'trigger': trigger});
  }

  @override
  Future<void> appendEvent(Map<String, dynamic> event) async {
    await methodChannel.invokeMethod<void>('appendEvent', {'event': event});
  }

  @override
  Future<List<Map<dynamic, dynamic>>> getEvents({bool pendingOnly = true}) async {
    final list = await methodChannel.invokeListMethod<Map<dynamic, dynamic>>('getEvents', {
      'pendingOnly': pendingOnly,
    });
    return list ?? const [];
  }

  @override
  Future<void> acknowledgeEvents(List<String> ids) async {
    await methodChannel.invokeMethod<void>('acknowledgeEvents', {'ids': ids});
  }

  @override
  Future<void> markEventsUploaded(List<String> ids) async {
    await methodChannel.invokeMethod<void>('markEventsUploaded', {'ids': ids});
  }

  @override
  Future<Map<dynamic, dynamic>?> recordCheckpoint(Map<String, dynamic> checkpoint) async {
    return await methodChannel.invokeMethod<Map<dynamic, dynamic>>('recordCheckpoint', {
      'checkpoint': checkpoint,
    });
  }

  @override
  Future<Map<dynamic, dynamic>> getZoneState() async {
    return await methodChannel.invokeMethod<Map<dynamic, dynamic>>('getZoneState') ?? const {};
  }

  @override
  Future<void> setZoneState({required bool wasInZone, required int failCount}) async {
    await methodChannel.invokeMethod<void>('setZoneState', {'wasInZone': wasInZone, 'failCount': failCount});
  }

  @override
  Future<void> resetZoneState() async {
    await methodChannel.invokeMethod<void>('resetZoneState');
  }

  @override
  Future<Map<dynamic, dynamic>?> getLastCheckpoint() async {
    return await methodChannel.invokeMethod<Map<dynamic, dynamic>>('getLastCheckpoint');
  }

  @override
  Future<List<Map<dynamic, dynamic>>> takePendingCheckpoints() async {
    final list = await methodChannel.invokeListMethod<Map<dynamic, dynamic>>('takePendingCheckpoints');
    return list ?? const [];
  }

  @override
  Future<void> saveLastResult(Map<String, dynamic> result) async {
    await methodChannel.invokeMethod<void>('saveLastResult', {'result': result});
  }

  @override
  Future<Map<dynamic, dynamic>?> getLastResult() async {
    return await methodChannel.invokeMethod<Map<dynamic, dynamic>>('getLastResult');
  }

  @override
  Future<bool> isNfcAvailable() async {
    return await methodChannel.invokeMethod<bool>('isNfcAvailable') ?? false;
  }

  @override
  Future<Map<dynamic, dynamic>?> readNfcTag({String? alertMessage, int timeoutMs = 30000}) async {
    return await methodChannel.invokeMethod<Map<dynamic, dynamic>>('readNfcTag', {
      'alertMessage': alertMessage,
      'timeoutMs': timeoutMs,
    });
  }

  @override
  Future<void> stopNfcSession() async {
    await methodChannel.invokeMethod<void>('stopNfcSession');
  }

  @override
  Future<bool> isIgnoringBatteryOptimizations() async {
    return await methodChannel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? true;
  }

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async {
    return await methodChannel.invokeMethod<bool>('requestIgnoreBatteryOptimizations') ?? true;
  }

  @override
  Future<void> testNotification() async {
    await methodChannel.invokeMethod<void>('testNotification');
  }
}
