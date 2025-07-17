import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:workmanager/workmanager.dart';
import 'controllers/device_controller.dart';
import 'controllers/notification_controller.dart';
import 'helper/logger.dart';
import 'screens/home_screen.dart';
import 'services/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize notifications first
  final notificationController = NotificationController();
  await NotificationController.initialize();

  // Initialize background service
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    "device_detection",
    "detectDevices",
    frequency: const Duration(minutes: 1),
    constraints: Constraints(
      networkType: NetworkType.connected,
    ),
  );

  // Request permissions
  await _requestPermissions();

  // Register controllers before running the app
  Get.put(notificationController); // Register NotificationController
  Get.put(DeviceController()); // Register DeviceController

  runApp(const MyApp());
}

Future<void> _requestPermissions() async {
  await Permission.location.request();
  await Permission.backgroundRefresh.request();
  await Permission.bluetooth.request();
  await Permission.bluetoothScan.request();
  await Permission.bluetoothConnect.request();
  await Permission.bluetoothAdvertise.request();
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
  const MyHomePage({super.key,});


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

