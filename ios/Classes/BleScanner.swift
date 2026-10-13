import CoreBluetooth
import Foundation
import UIKit

/// Short CoreBluetooth scan for configured device names. iOS never exposes MAC
/// addresses, and in the background it only reports devices that advertise one
/// of `bleServiceUuids`, so set those for background BLE detection (or use iBeacons).
final class BleScanner: NSObject, CBCentralManagerDelegate {
  private static let restoreIdentifier = "attendance_tracker_ble"

  private var central: CBCentralManager?
  private var names: [String] = []
  private var completion: ((String?, Bool, String) -> Void)?
  private var pendingStart: (() -> Void)?
  private var seen = 0
  private var token = 0

  var isPoweredOn: Bool { central?.state == .poweredOn }

  /// [names] must already be normalized with TrackerConfig.normalizeName.
  func scan(
    names: [String], serviceUuids: [String], seconds: TimeInterval,
    completion: @escaping (_ device: String?, _ enabled: Bool, _ note: String) -> Void
  ) {
    guard !names.isEmpty else {
      completion(nil, isPoweredOn, "")
      return
    }
    if #available(iOS 13.1, *) {
      switch CBCentralManager.authorization {
      case .denied, .restricted:
        completion(nil, false, "BLE Skip: Bluetooth permission denied.\n")
        return
      case .notDetermined where UIApplication.shared.applicationState != .active:
        // Creating the manager would show the permission prompt; never do that in the background.
        completion(nil, false, "BLE Skip: Bluetooth permission not requested yet.\n")
        return
      default:
        break
      }
    }

    finish(nil, note: "")
    token += 1
    let scanToken = token
    self.names = names
    self.seen = 0
    self.completion = completion

    let services = serviceUuids.filter(Self.isValidUuid).map { CBUUID(string: $0) }
    let manager = ensureCentral()
    let start = { [weak self] in
      guard let self = self, let central = self.central else { return }
      central.scanForPeripherals(
        withServices: services.isEmpty ? nil : services,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    if manager.state == .poweredOn {
      start()
    } else {
      pendingStart = start
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self = self, self.token == scanToken else { return }
      self.finish(nil, note: "")
    }
  }

  func stop() {
    finish(nil, note: "")
  }

  private func ensureCentral() -> CBCentralManager {
    if let central = central { return central }
    var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
    // State restoration requires the bluetooth-central background mode, otherwise iOS asserts.
    if AttendanceTrackerEngine.hasBackgroundMode("bluetooth-central") {
      options[CBCentralManagerOptionRestoreIdentifierKey] = Self.restoreIdentifier
    }
    let central = CBCentralManager(delegate: self, queue: nil, options: options)
    self.central = central
    return central
  }

  private func finish(_ device: String?, note: String) {
    guard let completion = completion else { return }
    self.completion = nil
    pendingStart = nil
    if central?.isScanning == true { central?.stopScan() }
    let enabled = isPoweredOn
    var log = note
    if device == nil && log.isEmpty {
      log = enabled ? "BLE: No match among \(seen) device(s).\n" : "BLE Skip: Bluetooth is OFF or unavailable.\n"
    }
    completion(device, enabled, log)
  }

  private static func isValidUuid(_ value: String) -> Bool {
    UUID(uuidString: value) != nil
      || value.range(of: "^[0-9A-Fa-f]{4}([0-9A-Fa-f]{4})?$", options: .regularExpression) != nil
  }

  // MARK: - CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      if let start = pendingStart {
        pendingStart = nil
        start()
      }
    case .unknown, .resetting:
      break
    default:
      finish(nil, note: "BLE Skip: Bluetooth is OFF or unavailable.\n")
    }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {}

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    seen += 1
    let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
    guard !name.isEmpty, names.contains(TrackerConfig.normalizeName(name)) else { return }
    finish(name, note: "BLE: MATCH! \(name) RSSI: \(RSSI)\n")
  }
}
