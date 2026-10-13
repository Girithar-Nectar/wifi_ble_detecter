import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../attendance_tracker_platform_interface.dart';
import '../models/attendance_config.dart';
import '../models/detection_result.dart';
import 'checkpoint_verifier.dart';

/// A raw checkpoint (from the native queue or a deep link) after verification.
class CheckpointOutcome {
  /// [CheckpointSource.nfc] or [CheckpointSource.qr].
  final String source;
  final CheckpointVerification verification;
  final DateTime timestamp;

  const CheckpointOutcome(this.source, this.verification, this.timestamp);
}

class CheckpointService {
  static AttendanceTrackerPlatform get _platform => AttendanceTrackerPlatform.instance;

  /// Verifies a raw checkpoint map: `{source, uid?, payloads}`.
  static CheckpointVerification verifyRaw(Map<dynamic, dynamic> raw, AttendanceConfig config) {
    final payloads = List<String>.from((raw['payloads'] as List?) ?? const []);
    if (raw['source'] == CheckpointSource.nfc) {
      return CheckpointVerifier.verifyNfc(uid: raw['uid'] as String?, payloads: payloads, config: config);
    }
    var result = const CheckpointVerification.invalid('The QR code is empty.');
    for (final payload in payloads) {
      result = CheckpointVerifier.verifyQr(payload, config);
      if (result.isValid) break;
    }
    return result;
  }

  /// Stores a verified checkpoint natively; this also records a checkpoint event.
  /// iOS evaluates the zone natively and returns the detection.
  static Future<Map<dynamic, dynamic>?> record(String source, String checkpointId, {DateTime? at}) {
    return _platform.recordCheckpoint({
      'source': source,
      'checkpointId': checkpointId,
      'timestamp': (at ?? DateTime.now()).millisecondsSinceEpoch,
    });
  }

  /// Verifies and records checkpoints captured natively while Dart was not
  /// running (NFC tap or `attendancetracker://` link that launched the app).
  static Future<List<CheckpointOutcome>> processPending(AttendanceConfig config) async {
    final outcomes = <CheckpointOutcome>[];
    try {
      final raws = await _platform.takePendingCheckpoints();
      for (final raw in raws) {
        final source = raw['source'] == CheckpointSource.nfc ? CheckpointSource.nfc : CheckpointSource.qr;
        final ts = (raw['timestamp'] as num?)?.toInt();
        final at = ts != null ? DateTime.fromMillisecondsSinceEpoch(ts) : DateTime.now();
        final verification = verifyRaw(raw, config);
        if (verification.isValid) {
          await record(source, verification.checkpointId!, at: at);
        }
        outcomes.add(CheckpointOutcome(source, verification, at));
      }
    } catch (e) {
      print('AttendanceTracker: processing pending checkpoints failed: $e');
    }
    return outcomes;
  }

  /// Marks [result] in zone when the last NFC/QR checkpoint is still valid and
  /// no passive sensor matched.
  static Future<DetectionResult> applyLastCheckpoint(DetectionResult result, AttendanceConfig config) async {
    if (result.isInZone) return result;
    try {
      final checkpoint = await _platform.getLastCheckpoint();
      final ts = (checkpoint?['timestamp'] as num?)?.toInt();
      if (checkpoint == null || ts == null) return result;

      final at = DateTime.fromMillisecondsSinceEpoch(ts);
      if (!config.isCheckpointValid(at, DateTime.now())) return result;

      final source = checkpoint['source'] as String?;
      return result.copyWith(
        isInZone: true,
        byNfc: source == CheckpointSource.nfc,
        byQr: source == CheckpointSource.qr,
        checkpointId: checkpoint['checkpointId'] as String?,
        diagnosticLog: '${result.diagnosticLog}CHECKPOINT: ${source?.toUpperCase()} '
            '"${checkpoint['checkpointId']}" from ${at.hour}:${at.minute.toString().padLeft(2, '0')} is still valid.\n',
      );
    } catch (_) {
      return result;
    }
  }
}

/// POSTs queued events to [AttendanceConfig.apiEndpoint] (Android; iOS posts natively).
class EventUploader {
  static bool _busy = false;

  static Future<void> uploadPending(AttendanceConfig config) async {
    final endpoint = config.apiEndpoint;
    if (endpoint == null || endpoint.isEmpty || _busy) return;
    _busy = true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final events = await AttendanceTrackerPlatform.instance.getEvents(pendingOnly: false);
      final uploaded = <String>[];
      for (final event in events.where((e) => e['uploaded'] != true).take(20)) {
        final request = await client.postUrl(Uri.parse(endpoint));
        request.headers.contentType = ContentType.json;
        config.apiHeaders?.forEach(request.headers.set);
        request.add(utf8.encode(jsonEncode(event)));
        final response = await request.close().timeout(const Duration(seconds: 15));
        await response.drain<void>();
        if (response.statusCode < 200 || response.statusCode >= 300) break;
        uploaded.add(event['id'] as String);
      }
      if (uploaded.isNotEmpty) {
        await AttendanceTrackerPlatform.instance.markEventsUploaded(uploaded);
      }
    } catch (e) {
      print('AttendanceTracker: event upload failed, will retry: $e');
    } finally {
      client.close(force: true);
      _busy = false;
    }
  }
}
