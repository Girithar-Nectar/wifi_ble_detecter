import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide BluetoothService;
import '../models/device_model.dart';
import '../services/wifi_service.dart';
import '../services/bluetooth_service.dart';

class DeviceCard extends StatelessWidget {
  final DeviceModel device;

  const DeviceCard({
    super.key,
    required this.device,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: device.isInRange
              ? Border.all(color: Colors.green, width: 2)
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _buildDeviceIcon(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          device.name,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _getDeviceTypeDescription(),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (device.isInRange)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'IN RANGE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _buildInfoRow(
                      'Distance',
                      device.distance != null
                          ? '${device.distance!.toStringAsFixed(1)}m'
                          : 'Unknown',
                      Icons.straighten,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _buildInfoRow(
                      'Signal',
                      device.rssi != null
                          ? '${device.rssi} dBm'
                          : 'Unknown',
                      Icons.signal_cellular_alt,
                    ),
                  ),
                ],
              ),
              if (device.rssi != null) ...[
                const SizedBox(height: 8),
                _buildSignalStrengthBar(),
              ],
              if (device.ssid != null && device.ssid!.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildInfoRow(
                  'SSID',
                  device.ssid!,
                  Icons.wifi,
                ),
              ],
              if (device.macAddress != null) ...[
                const SizedBox(height: 8),
                _buildInfoRow(
                  'MAC',
                  device.macAddress!,
                  Icons.info_outline,
                ),
              ],
              if (device.uuid != null && device.uuid!.isNotEmpty && (device.type == 'ble_device' || device.type == 'ibeacon')) ...[
                const SizedBox(height: 8),
                _buildInfoRow(
                  'UUIDs',
                  device.uuid!.join(', '),
                  Icons.fingerprint,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Last seen: ${_formatLastSeen()}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[500],
                ),
              ),
              if (device.lastDetected != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Last detected: ${_formatLastDetected()}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceIcon() {
    IconData iconData;
    Color iconColor;

    switch (device.type) {
      case 'wifi':
        iconData = Icons.wifi;
        iconColor = Colors.blue;
        break;
      case 'bluetooth':
        iconData = Icons.bluetooth;
        iconColor = Colors.blue;
        break;
      case 'ble_device':
      case 'ibeacon':
        iconData = Icons.sensors;
        iconColor = Colors.purple;
        break;
      default:
        iconData = Icons.device_unknown;
        iconColor = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: iconColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        iconData,
        color: iconColor,
        size: 24,
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: Colors.grey[600],
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSignalStrengthBar() {
    String strengthText;
    Color strengthColor;
    double strengthPercentage;

    if (device.rssi == null) {
      strengthText = 'Unknown';
      strengthColor = Colors.grey;
      strengthPercentage = 0.0;
    } else {
      switch (device.type) {
        case 'wifi':
          strengthText = WifiService.getSignalStrengthDescription(device.rssi!);
          break;
        case 'bluetooth':
        case 'ble_device':
        case 'ibeacon':
          strengthText = BluetoothService.getSignalStrengthDescription(device.rssi!);
          break;
        default:
          strengthText = 'Unknown';
      }

      if (device.rssi! >= -50) {
        strengthColor = Colors.green;
        strengthPercentage = 1.0;
      } else if (device.rssi! >= -60) {
        strengthColor = Colors.lightGreen;
        strengthPercentage = 0.8;
      } else if (device.rssi! >= -70) {
        strengthColor = Colors.orange;
        strengthPercentage = 0.6;
      } else if (device.rssi! >= -80) {
        strengthColor = Colors.deepOrange;
        strengthPercentage = 0.4;
      } else {
        strengthColor = Colors.red;
        strengthPercentage = 0.2;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Signal Strength',
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              strengthText,
              style: TextStyle(
                fontSize: 10,
                color: strengthColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: strengthPercentage,
          backgroundColor: Colors.grey[300],
          valueColor: AlwaysStoppedAnimation<Color>(strengthColor),
          minHeight: 4,
        ),
      ],
    );
  }

  String _getDeviceTypeDescription() {
    switch (device.type) {
      case 'wifi':
        return 'WiFi Network';
      case 'bluetooth':
        return 'Bluetooth Device';
      case 'ble_device':
        return 'BLE Device';
      case 'ibeacon':
        return 'iBeacon';
      default:
        return 'Unknown Device';
    }
  }

  String _formatLastSeen() {
    final now = DateTime.now();
    final difference = now.difference(device.lastSeen);

    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }

  String _formatLastDetected() {
    final now = DateTime.now();
    final difference = now.difference(device.lastDetected!);

    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }
}