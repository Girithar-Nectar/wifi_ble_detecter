import 'dart:async';
import 'package:flutter/material.dart';
import 'package:attendance_tracker/attendance_tracker.dart';
import 'package:permission_handler/permission_handler.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _tracker = AttendanceTracker();
  DetectionResult? _lastResult;
  StreamSubscription? _resultSubscription;
  bool _isManualScanning = false;
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _initializePlugin();
    // Subscribe to real-time updates from the background service
    _resultSubscription = _tracker.onResult.listen((result) {
      if (mounted) {
        setState(() {
          _lastResult = result;
          _isManualScanning = false;
        });
      }
    });
  }

  Future<void> _initializePlugin() async {
    try {
      // 1. Request permissions (non-blocking for the UI)
      await _requestPermissions();

      // 2. Configure and Start Tracking
      await _tracker.initialize(AttendanceConfig(
        officeLatitude: 10.9994799,
        officeLongitude: 76.9834678,
        geofenceRadius: 100.0,
        wifiBSSIDs: [
          '3c:64:cf:a6:2b:d0',
          '3c:64:cf:a6:2b:ce',
          '3c:64:cf:a6:31:6e',
          '3c:64:cf:a6:31:70',
          '3c:64:cf:a5:fc:48',
          '3c:64:cf:a5:fc:46',
        ],
        bleMACs: [
          'd0:5f:64:52:05:e1',
          'd0:5f:64:52:05:e2',
        ],
        shiftStartMs: 32400000, // 09:00 AM
        shiftEndMs: 64800000, // 06:00 PM
        welcomeTitle: 'Aloha!',
        welcomeBody: 'Welcome to the office. Have a productive day!',
        outOfZoneTitle: 'Leaving?',
        outOfZoneBody: 'Safe travels! Don\'t forget to check out if you\'re done.',
      ));

      await _tracker.startTracking();
      await _loadInitialStatus();
    } finally {
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.location.request();
    await Permission.locationAlways.request();
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    await Permission.notification.request();
  }

  @override
  void dispose() {
    _resultSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadInitialStatus() async {
    final result = await _tracker.getLastResult();
    if (mounted) {
      setState(() {
        _lastResult = result;
      });
    }
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
              Text('Initializing Attendance Tracker...'),
              Text('Please grant permissions if prompted.', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    final status = _lastResult?.isInZone ?? false;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Attendance Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Card
            _buildStatusCard(status),
            const SizedBox(height: 25),

            // Diagnostic Panel
            const Text(
              'Diagnostic Information',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blueGrey),
            ),
            const SizedBox(height: 15),
            _buildDiagnosticPanel(),

            const SizedBox(height: 25),
            // Action Buttons
            ElevatedButton.icon(
              onPressed: _isManualScanning
                  ? null
                  : () async {
                      setState(() => _isManualScanning = true);
                      await _tracker.forceScan();
                      Future.delayed(const Duration(seconds: 15), () {
                        if (mounted && _isManualScanning) {
                          setState(() => _isManualScanning = false);
                        }
                      });
                    },
              icon: _isManualScanning
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.bolt),
              label: Text(_isManualScanning ? 'Scanning Hardware...' : 'Force Scan Now'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.all(18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                elevation: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(bool isInZone) {
    return Container(
      padding: const EdgeInsets.all(25),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isInZone
              ? [const Color(0xFF00B09B), const Color(0xFF96C93D)] // Greenish
              : [const Color(0xFFEB3349), const Color(0xFFF45C43)], // Reddish
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
          child: Text('Waiting for background signal... Tap "Force Scan" to start.'),
        ),
      );
    }

    final res = _lastResult!;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _buildInfoRow('GPS Distance', res.distance != null ? '${res.distance!.toStringAsFixed(1)}m' : 'Unknown'),
            const Divider(),
            _buildSensorStatus('GPS Signal', res.status.isGpsEnabled, res.byGps),
            _buildSensorStatus('Wi-Fi Match', res.status.isWifiEnabled, res.byWifi),
            _buildSensorStatus('Bluetooth Match', res.status.isBleEnabled, res.byBle),
            const SizedBox(height: 10),
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
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  res.diagnosticLog,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.blueGrey),
                ),
              ),
            ],
            const SizedBox(height: 10),
            if (!res.status.isGpsEnabled || !res.status.isWifiEnabled || !res.status.isBleEnabled)
              const Text(
                '⚠ Some sensors are disabled. Please enable them for better accuracy.',
                style: TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.bold),
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
