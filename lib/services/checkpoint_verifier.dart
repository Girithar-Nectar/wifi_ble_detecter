import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/attendance_config.dart';

/// How a checkpoint was presented.
class CheckpointSource {
  static const nfc = 'nfc';
  static const qr = 'qr';
}

class CheckpointVerification {
  final bool isValid;

  /// The configured checkpoint (or QR site id) that matched.
  final String? checkpointId;

  /// Human readable reason, suitable for showing to the user.
  final String message;

  const CheckpointVerification._(this.isValid, this.checkpointId, this.message);

  const CheckpointVerification.valid(String checkpointId) : this._(true, checkpointId, 'Checkpoint verified.');

  const CheckpointVerification.invalid(String message) : this._(false, null, message);
}

/// Verifies NFC tags and QR codes against [AttendanceConfig].
///
/// Supported checkpoint formats:
/// * NFC tag UID, e.g. `04:A2:3B:1C:55:80` (any separators).
/// * A checkpoint id written as NDEF text, or inside a URI as `?id=<id>`,
///   e.g. `attendancetracker://checkpoint?id=LOBBY-1`. That URI also opens the
///   app from a killed state when the tag is tapped or the QR is scanned with
///   the phone camera.
/// * A rotating QR code `ATQR1:<siteId>:<counter>:<signature>` produced by
///   [generateDynamicQr], so a photo of the code stops working after
///   [AttendanceConfig.qrStepSeconds].
class CheckpointVerifier {
  static const uriScheme = 'attendancetracker';
  static const dynamicPrefix = 'ATQR1';
  static const _idParams = ['id', 'checkpoint', 'code', 'qr'];

  static String normalize(String value) => value.trim().toLowerCase().replaceAll(RegExp(r'[\s:\-]'), '');

  /// Every value inside [raw] that could be a checkpoint id.
  static List<String> candidates(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return const [];
    final out = <String>{value};
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme && !value.startsWith('$dynamicPrefix:')) {
      for (final key in _idParams) {
        final param = uri.queryParameters[key];
        if (param != null && param.trim().isNotEmpty) out.add(param.trim());
      }
      final segments = uri.pathSegments.where((s) => s.isNotEmpty);
      if (segments.isNotEmpty) out.add(segments.last);
    }
    return out.toList();
  }

  static CheckpointVerification verifyNfc({
    String? uid,
    List<String> payloads = const [],
    required AttendanceConfig config,
  }) {
    if (config.nfcTags.isEmpty) {
      return const CheckpointVerification.invalid('No NFC checkpoints are configured.');
    }
    final allowed = {for (final tag in config.nfcTags) normalize(tag): tag};

    if (uid != null && uid.isNotEmpty) {
      final match = allowed[normalize(uid)];
      if (match != null) return CheckpointVerification.valid(match);
    }
    for (final payload in payloads) {
      for (final candidate in candidates(payload)) {
        final match = allowed[normalize(candidate)];
        if (match != null) return CheckpointVerification.valid(match);
      }
    }
    return const CheckpointVerification.invalid('This NFC tag is not an attendance checkpoint.');
  }

  static CheckpointVerification verifyQr(String raw, AttendanceConfig config, {DateTime? now}) {
    final all = candidates(raw);
    if (all.isEmpty) return const CheckpointVerification.invalid('The QR code is empty.');

    for (final candidate in all) {
      if (candidate.startsWith('$dynamicPrefix:')) {
        return _verifyDynamic(candidate, config, now ?? DateTime.now());
      }
    }

    if (config.qrCodes.isEmpty) {
      return const CheckpointVerification.invalid('This QR code is not an attendance checkpoint.');
    }
    final allowed = {for (final code in config.qrCodes) normalize(code): code};
    for (final candidate in all) {
      final match = allowed[normalize(candidate)];
      if (match != null) return CheckpointVerification.valid(match);
    }
    return const CheckpointVerification.invalid('This QR code is not an attendance checkpoint.');
  }

  /// Builds the rotating QR content a kiosk shows for [siteId] at [at].
  /// Set [asUri] to wrap it in `attendancetracker://checkpoint?code=...`, so the
  /// phone camera can open the app straight from the code.
  static String generateDynamicQr({
    required String secret,
    required String siteId,
    DateTime? at,
    int stepSeconds = 30,
    bool asUri = false,
  }) {
    if (siteId.isEmpty || siteId.contains(':')) {
      throw ArgumentError.value(siteId, 'siteId', 'must be non-empty and must not contain ":"');
    }
    final counter = _counter(at ?? DateTime.now(), stepSeconds);
    final code = '$dynamicPrefix:$siteId:$counter:${_sign(secret, siteId, counter)}';
    if (!asUri) return code;
    return Uri(scheme: uriScheme, host: 'checkpoint', queryParameters: {'code': code}).toString();
  }

  static CheckpointVerification _verifyDynamic(String code, AttendanceConfig config, DateTime now) {
    final secret = config.qrSecret;
    if (secret == null || secret.isEmpty) {
      return const CheckpointVerification.invalid('Rotating QR codes are not configured.');
    }
    final parts = code.split(':');
    final counter = parts.length == 4 ? int.tryParse(parts[2]) : null;
    if (counter == null) return const CheckpointVerification.invalid('The QR code is damaged.');

    final siteId = parts[1];
    if (config.qrSiteId != null && config.qrSiteId != siteId) {
      return const CheckpointVerification.invalid('This QR code belongs to another site.');
    }
    if (!_constantTimeEquals(parts[3], _sign(secret, siteId, counter))) {
      return const CheckpointVerification.invalid('This QR code is not genuine.');
    }
    final step = config.qrStepSeconds < 1 ? 30 : config.qrStepSeconds;
    if ((counter - _counter(now, step)).abs() > config.qrDriftSteps) {
      return const CheckpointVerification.invalid('This QR code has expired. Scan the code on the screen again.');
    }
    return CheckpointVerification.valid(siteId);
  }

  static int _counter(DateTime at, int stepSeconds) => at.millisecondsSinceEpoch ~/ 1000 ~/ stepSeconds;

  static String _sign(String secret, String siteId, int counter) {
    final hmac = Hmac(sha256, utf8.encode(secret));
    return hmac.convert(utf8.encode('$dynamicPrefix:$siteId:$counter')).toString().substring(0, 20);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
