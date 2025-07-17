class AppConfig {
  static const Map<String, String> allowedBleMacAddresses = {
    'd0:5f:64:52:05:e1': 'Nectar BLE 1',
    'd0:5f:64:52:05:e2': 'Nectar BLE 2',
  };
  // Other AppConfig properties (e.g., scanTimeout, rangeThreshold, txPower, pathLossExponent, minRssi, maxRssi, maxRange)
  static const Duration scanTimeout = Duration(seconds: 8);

  static const double rangeThreshold = 10.0; // Align with _bleRangeThreshold
  static const int txPower = -59; // Adjust based on your devices
  static const double pathLossExponent = 2.0; // Adjust based on environment
  static const int minRssi = -100;
  static const int maxRssi = -30;
  static const double maxRange = 100.0;
  static const Duration scanInterval = Duration(seconds: 8);
}