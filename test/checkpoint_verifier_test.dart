import 'package:attendance_tracker/attendance_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

AttendanceConfig _config({
  List<String> nfcTags = const [],
  List<String> qrCodes = const [],
  String? qrSecret,
  String? qrSiteId,
  int checkpointValidityMinutes = 60,
  int shiftStartMs = 0,
  int shiftEndMs = 86399000,
}) {
  return AttendanceConfig(
    officePoints: const [],
    nfcTags: nfcTags,
    qrCodes: qrCodes,
    qrSecret: qrSecret,
    qrSiteId: qrSiteId,
    checkpointValidityMinutes: checkpointValidityMinutes,
    shiftStartMs: shiftStartMs,
    shiftEndMs: shiftEndMs,
  );
}

int _ms(int hours, [int minutes = 0]) => (hours * 60 + minutes) * 60000;

void main() {
  group('NFC', () {
    final config = _config(nfcTags: ['04:A2:3B:1C:55:80', 'LOBBY-1']);

    test('matches the tag UID whatever the separators and case', () {
      final result = CheckpointVerifier.verifyNfc(uid: '04a23b1c5580', config: config);
      expect(result.isValid, isTrue);
      expect(result.checkpointId, '04:A2:3B:1C:55:80');
    });

    test('matches an NDEF text record and a checkpoint URI', () {
      expect(CheckpointVerifier.verifyNfc(payloads: ['lobby-1'], config: config).checkpointId, 'LOBBY-1');
      expect(
        CheckpointVerifier.verifyNfc(payloads: ['attendancetracker://checkpoint?id=LOBBY-1'], config: config).isValid,
        isTrue,
      );
      expect(
        CheckpointVerifier.verifyNfc(payloads: ['https://example.com/checkpoint/LOBBY-1'], config: config).isValid,
        isTrue,
      );
    });

    test('rejects unknown tags and an empty config', () {
      expect(CheckpointVerifier.verifyNfc(uid: '11:22:33:44', payloads: ['OTHER'], config: config).isValid, isFalse);
      expect(CheckpointVerifier.verifyNfc(uid: '04a23b1c5580', config: _config()).isValid, isFalse);
    });
  });

  group('QR', () {
    const secret = 'kiosk-secret';
    final now = DateTime(2026, 10, 13, 10, 0, 0);

    test('accepts a static code or its id inside a URI', () {
      final config = _config(qrCodes: ['GATE-2']);
      expect(CheckpointVerifier.verifyQr('GATE-2', config).checkpointId, 'GATE-2');
      expect(CheckpointVerifier.verifyQr('attendancetracker://checkpoint?id=gate-2', config).isValid, isTrue);
      expect(CheckpointVerifier.verifyQr('GATE-3', config).isValid, isFalse);
    });

    test('accepts a fresh rotating code, plain or as a URI', () {
      final config = _config(qrSecret: secret, qrSiteId: 'HQ');
      final code = CheckpointVerifier.generateDynamicQr(secret: secret, siteId: 'HQ', at: now);
      final uri = CheckpointVerifier.generateDynamicQr(secret: secret, siteId: 'HQ', at: now, asUri: true);

      expect(uri, startsWith('attendancetracker://checkpoint?code='));
      expect(CheckpointVerifier.verifyQr(code, config, now: now).checkpointId, 'HQ');
      expect(CheckpointVerifier.verifyQr(uri, config, now: now).isValid, isTrue);
      // One step of clock drift is allowed.
      expect(CheckpointVerifier.verifyQr(code, config, now: now.add(const Duration(seconds: 30))).isValid, isTrue);
    });

    test('rejects an expired, forged, or other-site rotating code', () {
      final config = _config(qrSecret: secret, qrSiteId: 'HQ');
      final code = CheckpointVerifier.generateDynamicQr(secret: secret, siteId: 'HQ', at: now);

      final expired = CheckpointVerifier.verifyQr(code, config, now: now.add(const Duration(minutes: 2)));
      expect(expired.isValid, isFalse);
      expect(expired.message, contains('expired'));

      final forged = CheckpointVerifier.generateDynamicQr(secret: 'wrong', siteId: 'HQ', at: now);
      expect(CheckpointVerifier.verifyQr(forged, config, now: now).isValid, isFalse);

      final otherSite = CheckpointVerifier.generateDynamicQr(secret: secret, siteId: 'BRANCH', at: now);
      expect(CheckpointVerifier.verifyQr(otherSite, config, now: now).message, contains('another site'));

      expect(CheckpointVerifier.verifyQr(code, _config(), now: now).isValid, isFalse);
    });

    test('refuses site ids that would break the code format', () {
      expect(() => CheckpointVerifier.generateDynamicQr(secret: secret, siteId: 'A:B'), throwsArgumentError);
    });
  });

  group('shift and checkpoint validity', () {
    test('day shift', () {
      final config = _config(shiftStartMs: _ms(9), shiftEndMs: _ms(18));
      expect(config.isWithinShift(DateTime(2026, 10, 13, 10)), isTrue);
      expect(config.isWithinShift(DateTime(2026, 10, 13, 19)), isFalse);
      expect(config.currentShiftStart(DateTime(2026, 10, 13, 10)), DateTime(2026, 10, 13, 9));
    });

    test('overnight shift starts the previous evening after midnight', () {
      final config = _config(shiftStartMs: _ms(22), shiftEndMs: _ms(6));
      expect(config.isWithinShift(DateTime(2026, 10, 13, 2)), isTrue);
      expect(config.isWithinShift(DateTime(2026, 10, 13, 12)), isFalse);
      expect(config.currentShiftStart(DateTime(2026, 10, 13, 2)), DateTime(2026, 10, 12, 22));
      expect(config.currentShiftStart(DateTime(2026, 10, 13, 23)), DateTime(2026, 10, 13, 22));
    });

    test('a checkpoint lasts checkpointValidityMinutes', () {
      final config = _config(checkpointValidityMinutes: 60);
      final tap = DateTime(2026, 10, 13, 9);
      expect(config.isCheckpointValid(tap, tap.add(const Duration(minutes: 59))), isTrue);
      expect(config.isCheckpointValid(tap, tap.add(const Duration(minutes: 61))), isFalse);
    });

    test('validity 0 keeps a checkpoint until the shift ends', () {
      final config = _config(checkpointValidityMinutes: 0, shiftStartMs: _ms(9), shiftEndMs: _ms(18));
      final tap = DateTime(2026, 10, 13, 9, 5);
      expect(config.isCheckpointValid(tap, DateTime(2026, 10, 13, 17, 30)), isTrue);
      expect(config.isCheckpointValid(tap, DateTime(2026, 10, 13, 18, 30)), isFalse);
      // Yesterday's tap does not count today.
      expect(config.isCheckpointValid(tap, DateTime(2026, 10, 14, 10)), isFalse);
    });
  });

  group('iBeacon and Wi-Fi parsing', () {
    test('parses config entries and Apple manufacturer data', () {
      final config = IBeaconId.parse('E2C56DB5-DFFB-48D2-B060-D0F5A71096E0:100');
      expect(config, isNotNull);
      expect(config!.major, 100);
      expect(config.minor, isNull);
      expect(IBeaconId.parse('not-a-uuid'), isNull);

      final data = <int>[
        0x02, 0x15, //
        0xE2, 0xC5, 0x6D, 0xB5, 0xDF, 0xFB, 0x48, 0xD2, 0xB0, 0x60, 0xD0, 0xF5, 0xA7, 0x10, 0x96, 0xE0,
        0x00, 0x64, // major 100
        0x00, 0x07, // minor 7
        0xC5,
      ];
      final seen = IBeaconId.fromManufacturerData(data);
      expect(seen.toString(), 'e2c56db5-dffb-48d2-b060-d0f5a71096e0:100:7');
      expect(config.matches(seen!), isTrue);
      expect(IBeaconId.parse('E2C56DB5-DFFB-48D2-B060-D0F5A71096E0:100:8')!.matches(seen), isFalse);
    });

    test('BSSIDs from iOS lose leading zeros; normalisation restores them', () {
      expect(DetectionFusion.normalizeBssid('3C:64:CF:A6:2B:D0'), '3c:64:cf:a6:2b:d0');
      expect(DetectionFusion.normalizeBssid('a:4:cf:a6:2b:d0'), '0a:04:cf:a6:2b:d0');
    });
  });

  group('JSON round trips shared with native code', () {
    test('DetectionResult', () {
      final result = DetectionResult(
        isInZone: true,
        byQr: true,
        checkpointId: 'HQ',
        status: ServiceStatus(isGpsEnabled: true, isWifiEnabled: false, isBleEnabled: true),
        trigger: DetectionTrigger.qr,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1760000000000),
      );
      final back = DetectionResult.fromJson(result.toJson());
      expect(back.source, 'qr');
      expect(back.checkpointId, 'HQ');
      expect(back.status.isBleEnabled, isTrue);
      expect(back.timestamp, result.timestamp);
    });

    test('AttendanceEvent from a detection drops the source on exit', () {
      final result = DetectionResult(
        isInZone: false,
        status: ServiceStatus(isGpsEnabled: true, isWifiEnabled: true, isBleEnabled: true),
        wifiBssid: '3c:64:cf:a6:2b:d0',
        trigger: DetectionTrigger.region,
      );
      final event = AttendanceEvent.fromDetection(AttendanceEventType.exit, result, appState: 'terminated');
      final back = AttendanceEvent.fromJson(event.toJson());
      expect(back.type, AttendanceEventType.exit);
      expect(back.source, isNull);
      expect(back.appState, 'terminated');
      expect(back.wifiBssid, '3c:64:cf:a6:2b:d0');
    });

    test('AttendanceConfig keeps the new checkpoint fields', () {
      final config = AttendanceConfig.fromJson(
        _config(nfcTags: ['A'], qrSecret: 's', qrSiteId: 'HQ').toJson(),
      );
      expect(config.nfcTags, ['A']);
      expect(config.qrSecret, 's');
      expect(config.qrSiteId, 'HQ');
      expect(config.hasQr, isTrue);
      expect(config.iosContinuousTracking, isTrue);
    });
  });
}
