import 'package:attendance_tracker/attendance_tracker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize and Start the Attendance Tracker Plugin
  final tracker = AttendanceTracker();
  await tracker.initialize(AttendanceConfig(
    officeLatitude: 12.9716, // Sample: Bangalore Office
    officeLongitude: 77.5946,
    geofenceRadius: 100.0,
    wifiSSIDs: ['Office_WiFi'],
    bleDeviceNames: ['Attendance_Beacon'],
    shiftStart: const TimeOfDay(hour: 9, minute: 0),
    shiftEnd: const TimeOfDay(hour: 18, minute: 0),
    welcomeTitle: 'Aloha!',
    welcomeBody: 'Welcome to the office. Have a productive day!',
    outOfZoneTitle: 'Leaving?',
    outOfZoneBody: 'Safe travels! Don\'t forget to check out if you\'re done.',
  ));

  await tracker.startTracking();

  // Request permissions
  await _requestPermissions();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Attendance Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

Future<void> _requestPermissions() async {
  await Permission.location.request();
  if (await Permission.location.isGranted) {
    await Permission.locationAlways.request();
  }
  await Permission.bluetooth.request();
  await Permission.bluetoothScan.request();
  await Permission.bluetoothConnect.request();
  await Permission.notification.request();
}
