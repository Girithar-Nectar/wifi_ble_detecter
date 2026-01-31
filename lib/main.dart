import 'package:attendance_tracker/attendance_tracker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'controllers/device_controller.dart';
import 'controllers/notification_controller.dart';
import 'helper/logger.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize notifications
  await NotificationController.initialize();

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
  ));

  await tracker.startTracking();

  // Request permissions
  await _requestPermissions();

  // Register controllers
  Get.put(NotificationController());
  Get.put(DeviceController());

  runApp(const MyApp());
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'WiFi & BLE Detector',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
  });

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  @override
  Widget build(BuildContext context) {
    return const HomeScreen();
  }

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);

    super.initState();
  }

  ///Flutter LifeCycleState
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    switch (state) {
      case AppLifecycleState.resumed:
        logger.i("App is in the foreground (Resumed)");
        break;
      case AppLifecycleState.inactive:
        logger.i("App is inactive");
        break;
      case AppLifecycleState.paused:
        logger.i("App is in the background (Paused)");
        break;
      case AppLifecycleState.detached:
        logger.i("App is detached");
        break;
      case AppLifecycleState.hidden:
        logger.i("App is in hidden state"); // ✅ fixed
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
