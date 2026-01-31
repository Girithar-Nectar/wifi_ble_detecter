import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/device_controller.dart';
import '../controllers/notification_controller.dart';
import '../widgets/device_card.dart';
import '../widgets/status_card.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final DeviceController deviceController = Get.find<DeviceController>();
    final NotificationController notificationController = Get.find<NotificationController>();
    final RxBool hasScanned = false.obs;

    ever(deviceController.isScanning, (_) {
      if (!deviceController.isScanning.value) {
        hasScanned.value = true;
      }
    });
    ever(deviceController.wifiDevices, (_) {
      if (deviceController.wifiDevices.isNotEmpty || deviceController.bleDevices.isNotEmpty) {
        hasScanned.value = true;
      }
    });
    ever(deviceController.bleDevices, (_) {
      if (deviceController.wifiDevices.isNotEmpty || deviceController.bleDevices.isNotEmpty) {
        hasScanned.value = true;
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('WiFi & BLE Detector'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_off),
            tooltip: 'Clear Notifications',
            onPressed: () async {
              await notificationController.cancelAllNotifications();
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Clear Devices',
            onPressed: () {
              deviceController.clearDevices();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await deviceController.performManualScan();
          hasScanned.value = true;
        },
        child: Obx(() {
          final devices = deviceController.getDevicesByType(deviceController.selectedFilter.value);
          final hasNoData = devices.isEmpty;

          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      StatusCard(
                        title: 'Scanning Status',
                        icon: deviceController.isScanning.value ? Icons.radar : Icons.radar_outlined,
                        color: deviceController.isScanning.value ? Colors.green : Colors.grey,
                        subtitle: deviceController.isScanning.value ? 'Scanning Active' : 'Scanning Stopped',
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                deviceController.toggleFilter('wifi');
                              },
                              child: StatusCard(
                                title: 'WiFi',
                                icon: deviceController.isWifiEnabled.value ? Icons.wifi : Icons.wifi_off,
                                color: deviceController.selectedFilter.value == 'wifi' ? Colors.blue : Colors.grey,
                                subtitle: '${deviceController.getDeviceCountByType('wifi')} networks',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                deviceController.toggleFilter('ble_device');
                              },
                              child: StatusCard(
                                title: 'BLE Devices',
                                icon: Icons.sensors,
                                color:
                                    deviceController.selectedFilter.value == 'ble_device' ? Colors.purple : Colors.grey,
                                subtitle: '${deviceController.getDeviceCountByType('ble_device')} devices',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (deviceController.isScanning.value && !hasScanned.value)
                const SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text(
                          'Scanning for devices...',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ),
              if (devices.isNotEmpty)
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final device = devices[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                        child: DeviceCard(device: device),
                      );
                    },
                    childCount: devices.length,
                  ),
                ),
              if (hasNoData && hasScanned.value)
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.search_off,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No ${deviceController.selectedFilter.value == 'wifi' ? 'WiFi Networks' : 'BLE Devices'}',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                color: Colors.grey[600],
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No devices detected. Try switching filters or pull to refresh.',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.grey[500],
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          );
        }),
      ),
    );
  }
}
