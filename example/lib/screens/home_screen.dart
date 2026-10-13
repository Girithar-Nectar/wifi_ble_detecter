import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:attendance_tracker/attendance_tracker.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Demo kiosk secret; a real app gets it from its backend.
const _kioskSecret = 'demo-kiosk-secret';
const _kioskSiteId = 'HQ';

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _tracker = AttendanceTracker();
  DetectionResult? _lastResult;
  StreamSubscription? _resultSubscription;
  StreamSubscription? _pingSubscription;
  StreamSubscription? _eventSubscription;
  DateTime? _lastPing;
  Timer? _statusTimer;
  bool _isManualScanning = false;
  bool _isInitializing = true;
  ServiceStatus? _currentHardwareStatus;
  TrackingReadiness? _readiness;
  List<AttendanceEvent> _pendingEvents = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _eventSubscription = _tracker.onEvent.listen((_) => _loadEvents());

    // Move heavy initialization to after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initializePlugin();
    });

    // Subscribe to pings to verify background health
    _pingSubscription = _tracker.onPing.listen((event) {
      if (mounted) {
        setState(() {
          _lastPing = DateTime.now();
        });
      }
    });

    // Subscribe to real-time updates from the background service
    _resultSubscription = _tracker.onResult.listen((result) {
      if (mounted) {
        setState(() {
          _lastResult = result;
          _isManualScanning = false;
          _currentHardwareStatus = result.status;
        });
      }
    });

    // Periodically check hardware status for enforcement - only if NOT initializing
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (_isInitializing) return;

      final status = await _tracker.checkServicesStatus();
      if (mounted) {
        setState(() {
          _currentHardwareStatus = status;
        });
      }
    });
  }

  Future<void> _initializePlugin() async {
    try {
      // Force timeout after 30 seconds to prevent black screen
      await Future.any([
        _performInitialization(),
        Future.delayed(const Duration(seconds: 30), () {
          debugPrint('AttendanceTracker: Initialization timed out after 30s');
        }),
      ]);
    } catch (e, stackTrace) {
      debugPrint('Init Error: $e');
      debugPrint('Stack trace: $stackTrace');
    } finally {
      // ALWAYS exit loading screen, even on error
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  Future<void> _performInitialization() async {
    // 1. Basic initialization (fast)
    await _tracker.initialize(AttendanceConfig(
      officePoints: [
        'POINT(76.9859883 10.9993243)',
        'POINT(76.9326375 10.990581)',

        ///giri location
      ],
      geofenceRadius: 200.0,
      wifiBSSIDs: [
        '3c:64:cf:a6:2b:d0',
        '3c:64:cf:a6:2b:ce',
        '3c:64:cf:a6:31:6e',
        '3c:64:cf:a6:31:70',
        '3c:64:cf:a5:fc:48',
        '3c:64:cf:a5:fc:46',
        'f6:a6:4d:e7:d2:57' //giri wifi
      ],
      bleMACs: [
        'd0:5f:64:52:05:e1',
        'd0:5f:64:52:05:e2',
      ],
      // Indoor checkpoints: an NFC tag holding "LOBBY-1" (or its UID), a printed
      // QR "attendancetracker://checkpoint?id=LOBBY-1", or the rotating kiosk QR.
      nfcTags: ['LOBBY-1'],
      qrCodes: ['LOBBY-1'],
      qrSecret: _kioskSecret,
      qrSiteId: _kioskSiteId,
      checkpointValidityMinutes: 60,
      shiftStartMs: 0, // 12:00 AM
      shiftEndMs: 86399000, // 11:59 PM (Full day for testing)
      welcomeTitle: 'Aloha!',
      welcomeBody: 'Welcome to the office. Have a productive day!',
      outOfZoneTitle: 'Leaving?',
      shiftEndedTitle: 'Shift Ended',
      shiftEndedBody: 'Shift ended. Have a great day!',
      outOfZoneBody: 'Safe travels! Don\'t forget to check out if you\'re done.',
      welcomeVibration: [0, 500, 200, 500, 200, 500], // SOS Pattern for entry
      outOfZoneVibration: [0, 200, 100, 200], // Rapid pulses for exit
      welcomeSound: 'inzone',
      outOfZoneSound: 'outofzone',
      enableTts: false,
      scanIntervalSeconds: 30, // Scan every 30 seconds for good balance of responsiveness and battery
    ));

    // 2. Handle Tracking & Permissions (First-run aware)
    final hasPerms = await _tracker.hasPermissions();
    debugPrint('AttendanceTracker: Has all permissions: $hasPerms');

    if (hasPerms) {
      // Normal path: start immediately
      debugPrint('AttendanceTracker: Starting tracking...');
      await _tracker.startTracking();
      await _loadInitialStatus();
    } else {
      // First run or permissions missing: request and then start
      debugPrint('AttendanceTracker: Permissions missing, requesting...');
      final granted = await _tracker.requestPermissions();
      debugPrint('AttendanceTracker: Permissions granted: $granted');

      if (granted) {
        debugPrint('AttendanceTracker: Starting tracking after permission grant...');
        await _tracker.startTracking();
        await _loadInitialStatus();
      } else {
        debugPrint('AttendanceTracker: Critical permissions denied by user.');
        // Still show UI even if permissions denied
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resultSubscription?.cancel();
    _pingSubscription?.cancel();
    _eventSubscription?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_isInitializing) {
      // NFC taps / checkpoint links that arrived while the app was in the background.
      _tracker.processPendingCheckpoints().then((_) => _loadInitialStatus());
    }
  }

  Future<void> _loadInitialStatus() async {
    final result = await _tracker.getLastResult();
    final readiness = await _tracker.getReadiness();
    if (mounted) {
      setState(() {
        _lastResult = result;
        _readiness = readiness;
        if (result != null) _currentHardwareStatus = result.status;
      });
    }
    await _loadEvents();
  }

  Future<void> _loadEvents() async {
    final events = await _tracker.getPendingEvents();
    if (mounted) setState(() => _pendingEvents = events);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _scanNfc() async {
    try {
      final result = await _tracker.scanNfc();
      _showMessage(result.isValid
          ? 'Checked in at ${result.verification.checkpointId} (NFC)'
          : '${result.verification.message} UID: ${result.tagUid ?? '-'}');
    } on PlatformException catch (e) {
      _showMessage(e.message ?? e.code);
    }
  }

  Future<void> _enterQr() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('QR code content'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Paste what your scanner read'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Submit')),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    final result = await _tracker.submitQrCode(value);
    _showMessage(result.isValid ? 'Checked in at ${result.verification.checkpointId} (QR)' : result.verification.message);
  }

  Future<void> _showKioskCode() async {
    await showDialog<void>(
      context: context,
      builder: (context) => const _KioskCodeDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('Initializing Tracker...', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Checking permissions & hardware', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    final status = _lastResult?.isInZone ?? false;
    final hardwareIssue = _currentHardwareStatus != null &&
        (!_currentHardwareStatus!.isGpsEnabled ||
            !_currentHardwareStatus!.isWifiEnabled ||
            !_currentHardwareStatus!.isBleEnabled);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Attendance Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
      ),
      body: Column(
        children: [
          if (hardwareIssue) _buildHardwareEnforcementBanner(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildStatusCard(status),
                  const SizedBox(height: 25),
                  const Text(
                    'Diagnostic Information',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blueGrey),
                  ),
                  const SizedBox(height: 15),
                  _buildDiagnosticPanel(),
                  const SizedBox(height: 15),
                  _buildCheckpointPanel(),
                  const SizedBox(height: 15),
                  _buildBackgroundPanel(),
                  const SizedBox(height: 15),
                  _buildTestVibrationButton(),
                  const SizedBox(height: 25),
                  _buildActionButton(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHardwareEnforcementBanner() {
    List<String> missing = [];
    if (!_currentHardwareStatus!.isGpsEnabled) missing.add('GPS');
    if (!_currentHardwareStatus!.isWifiEnabled) missing.add('Wi-Fi');
    if (!_currentHardwareStatus!.isBleEnabled) missing.add('Bluetooth');

    return Container(
      width: double.infinity,
      color: Colors.redAccent,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'CRITICAL: ${missing.join(", ")} is OFF. Attendance will NOT be recorded.',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: () => _tracker.requestPermissions(),
            child: const Text('ENABLE', style: TextStyle(color: Colors.white, decoration: TextDecoration.underline)),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton() {
    return ElevatedButton.icon(
      onPressed: _isManualScanning
          ? null
          : () async {
              setState(() => _isManualScanning = true);
              await _tracker.forceScan();
              Future.delayed(const Duration(seconds: 15), () {
                if (mounted && _isManualScanning) setState(() => _isManualScanning = false);
              });
            },
      icon: _isManualScanning
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.bolt),
      label: Text(_isManualScanning ? 'Scanning Hardware...' : 'Force Scan Now'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.all(18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        elevation: 4,
      ),
    );
  }

  Widget _buildTestVibrationButton() {
    return OutlinedButton.icon(
      onPressed: () => _tracker.testVibration(),
      icon: const Icon(Icons.vibration),
      label: const Text('Test Custom Vibration'),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        side: const BorderSide(color: Colors.blueAccent),
      ),
    );
  }

  Widget _buildStatusCard(bool isInZone) {
    return Container(
      padding: const EdgeInsets.all(25),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isInZone
              ? [const Color(0xFF00B09B), const Color(0xFF96C93D)]
              : [const Color(0xFFEB3349), const Color(0xFFF45C43)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: (isInZone ? Colors.green : Colors.red).withOpacity(0.3),
            blurRadius: 15,
            offset: const Offset(0, 8),
          )
        ],
      ),
      child: Column(
        children: [
          Icon(
            isInZone ? Icons.check_circle_outline : Icons.location_off_outlined,
            size: 64,
            color: Colors.white,
          ),
          const SizedBox(height: 15),
          Text(
            isInZone ? 'IN THE OFFICE' : 'NOT DETECTED',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            isInZone ? 'Attendance active' : 'Tracking in progress...',
            style: TextStyle(color: Colors.white.withOpacity(0.9)),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnosticPanel() {
    if (_lastResult == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('Waiting for background signal...'),
        ),
      );
    }

    final res = _lastResult!;
    final pingText =
        _lastPing != null ? 'Alive (${DateTime.now().difference(_lastPing!).inSeconds}s ago)' : 'No signal';

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _buildInfoRow('GPS Distance', res.distance != null ? '${res.distance!.toStringAsFixed(1)}m' : 'Unknown'),
            _buildInfoRow('Background Health', pingText),
            const Divider(),
            _buildSensorStatus('GPS Signal', res.status.isGpsEnabled, res.byGps),
            _buildSensorStatus('Wi-Fi Match', res.status.isWifiEnabled, res.byWifi),
            _buildSensorStatus('Bluetooth Match', res.status.isBleEnabled, res.byBle),
            _buildSensorStatus('iBeacon Match', res.status.isBleEnabled, res.byBeacon),
            _buildSensorStatus('NFC / QR Checkpoint', true, res.byNfc || res.byQr),
            if (res.diagnosticLog.isNotEmpty) ...[
              const Divider(),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Raw Execution Log:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
              ),
              const SizedBox(height: 5),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration:
                    BoxDecoration(color: Colors.black.withOpacity(0.05), borderRadius: BorderRadius.circular(8)),
                child: Text(res.diagnosticLog,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.blueGrey)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCheckpointPanel() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Indoor checkpoints', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(onPressed: _scanNfc, icon: const Icon(Icons.nfc), label: const Text('Tap NFC tag')),
                OutlinedButton.icon(
                    onPressed: _enterQr, icon: const Icon(Icons.qr_code_scanner), label: const Text('Enter QR')),
                OutlinedButton.icon(
                    onPressed: _showKioskCode, icon: const Icon(Icons.qr_code_2), label: const Text('Kiosk code')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackgroundPanel() {
    final readiness = _readiness;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Background & killed state', style: TextStyle(fontWeight: FontWeight.bold)),
            if (readiness != null) ...[
              _buildInfoRow('Location "Always"', readiness.backgroundLocation ? 'Yes' : 'No'),
              _buildInfoRow('Notifications', readiness.notifications ? 'Yes' : 'No'),
              _buildInfoRow('Battery optimisation off', readiness.ignoringBatteryOptimizations ? 'Yes' : 'No'),
              _buildInfoRow('NFC available', readiness.nfcAvailable ? 'Yes' : 'No'),
              if (!readiness.ignoringBatteryOptimizations)
                TextButton(
                  onPressed: () async {
                    await _tracker.requestIgnoreBatteryOptimizations();
                    _loadInitialStatus();
                  },
                  child: const Text('Allow running in background'),
                ),
            ],
            const Divider(),
            Row(
              children: [
                Text('Unsynced events: ${_pendingEvents.length}'),
                const Spacer(),
                if (_pendingEvents.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      await _tracker.acknowledgeEvents(_pendingEvents.map((e) => e.id).toList());
                      _loadEvents();
                    },
                    child: const Text('Mark synced'),
                  ),
              ],
            ),
            for (final event in _pendingEvents.reversed.take(5))
              Text(
                '${event.timestamp.toLocal().toString().substring(0, 19)}  ${event.type}'
                ' ${event.source ?? ''} (${event.appState ?? '-'}, ${event.trigger ?? '-'})',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildSensorStatus(String label, bool isEnabled, bool isMatched) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(
            isEnabled ? Icons.sensors : Icons.sensors_off,
            size: 18,
            color: isEnabled ? Colors.blue : Colors.grey,
          ),
          const SizedBox(width: 10),
          Text(label),
          const Spacer(),
          if (isMatched)
            const Chip(
              label: Text('CONFIRMED', style: TextStyle(fontSize: 10, color: Colors.white)),
              backgroundColor: Colors.green,
              padding: EdgeInsets.zero,
            )
          else
            Text(
              isEnabled ? 'Seeking...' : 'OFF',
              style: TextStyle(
                fontSize: 12,
                color: isEnabled ? Colors.blueGrey : Colors.red,
                fontWeight: isEnabled ? FontWeight.normal : FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }
}

/// What a kiosk at the entrance would render as a QR code. It changes every
/// 30 seconds, so a photo of it stops working.
class _KioskCodeDialog extends StatefulWidget {
  const _KioskCodeDialog();

  @override
  State<_KioskCodeDialog> createState() => _KioskCodeDialogState();
}

class _KioskCodeDialogState extends State<_KioskCodeDialog> {
  late Timer _timer;
  String _code = '';

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  void _refresh() {
    final code = AttendanceTracker.generateKioskQrCode(secret: _kioskSecret, siteId: _kioskSiteId, asUri: true);
    if (code != _code) setState(() => _code = code);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Kiosk QR content'),
      content: SelectableText(_code, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      actions: [
        TextButton(
          onPressed: () async {
            final result = await AttendanceTracker().submitQrCode(_code);
            if (context.mounted) Navigator.pop(context);
            debugPrint('Kiosk self-test: ${result.verification.message}');
          },
          child: const Text('Submit as scan'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
