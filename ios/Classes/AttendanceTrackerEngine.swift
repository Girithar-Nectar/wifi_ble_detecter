import AVFoundation
import CoreLocation
import Foundation
import NetworkExtension
import SystemConfiguration
import SystemConfiguration.CaptiveNetwork
import UIKit
import UserNotifications

/// Keeps a background task alive while a scan or upload finishes.
private final class BackgroundTask {
  private var id: UIBackgroundTaskIdentifier = .invalid

  init(name: String) {
    id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
  }

  func end() {
    guard id != .invalid else { return }
    UIApplication.shared.endBackgroundTask(id)
    id = .invalid
  }
}

/// iOS attendance engine.
///
/// iOS suspends Dart timers shortly after the app leaves the screen and never
/// runs them after a kill, so on iOS detection runs here, natively. iOS
/// relaunches the app (even after the user swiped it away) for:
/// * circular region (geofence) enter/exit around the office points,
/// * iBeacon region enter/exit, and when the screen turns on inside one,
/// * significant location changes and visits.
/// Each wake-up runs one scan (GPS, connected Wi-Fi, iBeacon ranging, BLE
/// names), updates the zone state, records the event, notifies the user and
/// uploads to `apiEndpoint`. During the shift a low-power location session
/// keeps the app running in the background so periodic scans continue.
@objc(AttendanceTrackerEngine)
public final class AttendanceTrackerEngine: NSObject, CLLocationManagerDelegate {
  @objc public static let shared = AttendanceTrackerEngine()

  private static let regionPrefix = "at_"
  private static let maxRegions = 20
  private static var bootstrapped = false

  let store = NativeStore.shared
  private let ble = BleScanner()
  private let speech = AVSpeechSynthesizer()
  private var locationManager: CLLocationManager?
  private var scanTimer: Timer?
  private var pingTimer: Timer?
  private var scanning = false
  private var queued: (trigger: String, exitHint: Bool)?
  private var currentCompletions: [([String: Any]) -> Void] = []
  private var nextCompletions: [([String: Any]) -> Void] = []
  private var lastScanAt: Date?
  private var latestLocation: CLLocation?
  private var fixWaiter: ((CLLocation?) -> Void)?
  private var beaconWaiter: ((CLBeacon) -> Void)?
  private var launchedInBackground = false
  private var continuousActive = false
  private var uploading = false

  private var config: TrackerConfig? { store.configDict.map(TrackerConfig.init) }

  private struct Observation {
    var location: CLLocation?
    var gpsEnabled = false
    var ssid: String?
    var bssid: String?
    var wifiEnabled = false
    var beacon: String?
    var bleDevice: String?
    var bleEnabled = false
    var log = ""
  }

  // MARK: - Lifecycle

  /// Called at launch (see AttendanceTrackerLoader.m) before Flutter starts, so
  /// the location delegate exists when iOS delivers the event that relaunched the app.
  @objc public static func bootstrap(launchOptions: [AnyHashable: Any]?) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { bootstrap(launchOptions: launchOptions) }
      return
    }
    guard !bootstrapped else { return }
    bootstrapped = true
    shared.start(launchOptions: launchOptions)
  }

  private func start(launchOptions: [AnyHashable: Any]?) {
    launchedInBackground = UIApplication.shared.applicationState == .background
    NotificationCenter.default.addObserver(
      self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    guard store.trackingEnabled else { return }
    let byLocation = launchOptions?[UIApplication.LaunchOptionsKey.location.rawValue] != nil
    log("Bootstrapping tracking (background launch: \(launchedInBackground), location event: \(byLocation))")
    startMonitoring(forceRegions: false, initialScan: false)
  }

  @objc private func appDidBecomeActive() {
    launchedInBackground = false
    guard store.trackingEnabled else { return }
    startMonitoring(forceRegions: false, initialScan: true)
  }

  // MARK: - API used by the plugin

  func configure(_ json: [String: Any]) {
    store.configDict = json
    if store.trackingEnabled { startMonitoring(forceRegions: false, initialScan: false) }
  }

  func setTracking(_ enabled: Bool) {
    store.trackingEnabled = enabled
    if enabled {
      startMonitoring(forceRegions: true, initialScan: true)
    } else {
      stopMonitoring()
      // Next start re-detects presence and emits a fresh enter.
      resetZoneState()
    }
  }

  func refresh() {
    if store.trackingEnabled { startMonitoring(forceRegions: false, initialScan: false) }
  }

  /// Stores a verified checkpoint, logs it, and puts the user in zone right away.
  func recordCheckpoint(_ checkpoint: [String: Any], completion: @escaping ([String: Any]) -> Void) {
    let now = Date()
    var cp = checkpoint
    if cp["timestamp"] == nil { cp["timestamp"] = Self.ms(now) }
    let source = (cp["source"] as? String) == "nfc" ? "nfc" : "qr"
    let checkpointId = cp["checkpointId"] ?? NSNull()

    // checkpointToggle: a tap while in zone is a tap-out.
    if config?.checkpointToggle == true && store.wasInZone {
      tapOut(source: source, checkpointId: checkpointId, at: now, completion: completion)
      return
    }

    store.lastCheckpoint = cp
    _ = recordEvent("checkpoint", result: ["trigger": source, "checkpointId": checkpointId, flag(for: source): true])

    guard let config = config else {
      completion(["isInZone": false, "diagnosticLog": "No config; call initialize() first.\n"])
      return
    }
    let at = Date(timeIntervalSince1970: ((cp["timestamp"] as? NSNumber)?.doubleValue ?? Self.ms(now)) / 1000)
    let valid = config.isWithinShift(now) && config.isCheckpointValid(at: at, now: now)
    let defaultStatus: [String: Any] = ["isGpsEnabled": false, "isWifiEnabled": false, "isBleEnabled": false]
    let status = (store.lastResult?["status"] as? [String: Any]) ?? defaultStatus
    var result: [String: Any] = [
      "isInZone": valid,
      "byGps": false, "byWifi": false, "byBle": false, "byBeacon": false,
      "byNfc": source == "nfc", "byQr": source == "qr",
      "checkpointId": checkpointId,
      "trigger": source,
      "timestamp": Self.ms(now),
      "status": status,
      "diagnosticLog": valid
        ? "CHECKPOINT: \(source.uppercased()) \"\(checkpointId)\" verified.\n"
        : "CHECKPOINT: \(source.uppercased()) recorded outside shift hours.\n",
    ]
    if valid { applyTransition(inZone: true, result: result, config: config, exitHint: false) }
    result["appState"] = appState()
    result["tapOut"] = false
    store.lastResult = result
    AttendanceTrackerPlugin.broadcast("onDetection", result)
    completion(result)
    uploadPendingEvents {}
    // Refresh the passive sensors too.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scan(trigger: source) }
  }

  private func tapOut(source: String, checkpointId: Any, at now: Date, completion: @escaping ([String: Any]) -> Void) {
    store.lastCheckpoint = nil
    store.wasInZone = false
    store.failCount = 0
    store.tapOutAt = Self.ms(now)
    _ = recordEvent("exit", result: ["trigger": source, "checkpointId": checkpointId, flag(for: source): true])
    let defaultStatus: [String: Any] = ["isGpsEnabled": false, "isWifiEnabled": false, "isBleEnabled": false]
    let result: [String: Any] = [
      "isInZone": false, "tapOut": true,
      "byGps": false, "byWifi": false, "byBle": false, "byBeacon": false, "byNfc": false, "byQr": false,
      "checkpointId": checkpointId,
      "trigger": source,
      "timestamp": Self.ms(now),
      "appState": appState(),
      "status": (store.lastResult?["status"] as? [String: Any]) ?? defaultStatus,
      "diagnosticLog": "CHECKPOINT: \(source.uppercased()) \"\(checkpointId)\" tapped again: checked out.\n",
    ]
    store.lastResult = result
    AttendanceTrackerPlugin.broadcast("onDetection", result)
    completion(result)
    uploadPendingEvents {}
  }

  func resetZoneState() {
    store.wasInZone = false
    store.failCount = 0
    store.tapOutAt = nil
    store.lastCheckpoint = nil
  }

  func zoneState() -> [String: Any] {
    var state: [String: Any] = ["wasInZone": store.wasInZone, "failCount": store.failCount]
    if let tapOutAt = store.tapOutAt { state["tapOutAt"] = tapOutAt }
    return state
  }

  /// `attendancetracker://checkpoint?...` opened the app; Dart verifies it.
  func addPendingCheckpoint(url: URL) {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let source = components?.queryItems?.first { $0.name == "src" }?.value == "nfc" ? "nfc" : "qr"
    store.addPendingCheckpoint(["source": source, "payloads": [url.absoluteString], "timestamp": Self.ms(Date())])
    AttendanceTrackerPlugin.broadcast("onPendingCheckpoint", nil)
  }

  func appendEvent(_ event: [String: Any]) {
    var event = event
    if event["appState"] == nil || event["appState"] is NSNull { event["appState"] = appState() }
    store.appendEvent(event)
  }

  func acknowledgeEvents(_ ids: [String]) {
    store.acknowledgeEvents(Set(ids), hasEndpoint: config?.apiEndpoint != nil)
  }

  func markEventsUploaded(_ ids: [String]) {
    store.markEventsUploaded(Set(ids), hasEndpoint: config?.apiEndpoint != nil)
  }

  func testNotification() {
    notify("Vibration Test", "This is a test attendance notification.", sound: nil, config: config)
  }

  // MARK: - Monitoring

  private func manager() -> CLLocationManager {
    if let manager = locationManager { return manager }
    let manager = CLLocationManager()
    manager.delegate = self
    manager.pausesLocationUpdatesAutomatically = false
    // Setting this without the "location" background mode crashes the app.
    if Self.hasBackgroundMode("location") { manager.allowsBackgroundLocationUpdates = true }
    manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    locationManager = manager
    return manager
  }

  private func authorization() -> CLAuthorizationStatus {
    if #available(iOS 14.0, *) { return manager().authorizationStatus }
    return CLLocationManager.authorizationStatus()
  }

  private func isAuthorized() -> Bool {
    let status = authorization()
    return status == .authorizedAlways || status == .authorizedWhenInUse
  }

  private func startMonitoring(forceRegions: Bool, initialScan: Bool) {
    guard let config = config else {
      log("No config; call initialize() first")
      return
    }
    let manager = manager()
    if authorization() == .authorizedAlways {
      if CLLocationManager.significantLocationChangeMonitoringAvailable() {
        manager.startMonitoringSignificantLocationChanges()
      }
      manager.startMonitoringVisits()
      registerRegions(config, force: forceRegions)
    } else {
      log("Location is not 'Always' (\(authorization().rawValue)): iOS will not relaunch the app after a kill.")
    }
    updateContinuous(config)
    startTimers(config)
    if initialScan { scan(trigger: "manual") }
  }

  private func stopMonitoring() {
    scanTimer?.invalidate()
    scanTimer = nil
    pingTimer?.invalidate()
    pingTimer = nil
    ble.stop()
    guard let manager = locationManager else { return }
    manager.stopMonitoringSignificantLocationChanges()
    manager.stopMonitoringVisits()
    if continuousActive {
      manager.stopUpdatingLocation()
      continuousActive = false
    }
    for region in manager.monitoredRegions where region.identifier.hasPrefix(Self.regionPrefix) {
      manager.stopMonitoring(for: region)
    }
    store.regionSignature = nil
    log("Tracking stopped")
  }

  /// iBeacons first (they work indoors), then the office points nearest to the
  /// user; iOS allows 20 regions per app in total.
  private func registerRegions(_ config: TrackerConfig, force: Bool) {
    let manager = manager()
    let ours = manager.monitoredRegions.filter { $0.identifier.hasPrefix(Self.regionPrefix) }
    let signature = config.regionSignature
    // Re-registering drops an event iOS may be about to deliver, so only do it on change.
    if !force && store.regionSignature == signature && !ours.isEmpty { return }
    ours.forEach { manager.stopMonitoring(for: $0) }

    var slots = max(0, Self.maxRegions - (manager.monitoredRegions.count - ours.count))
    var registered: [CLRegion] = []

    if CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) {
      for (index, beacon) in config.beacons.enumerated() where slots > 0 {
        let region = beacon.region(identifier: "\(Self.regionPrefix)beacon_\(index)")
        region.notifyOnEntry = true
        region.notifyOnExit = true
        region.notifyEntryStateOnDisplay = true
        manager.startMonitoring(for: region)
        registered.append(region)
        slots -= 1
      }
    }

    if CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
      let radius = min(max(config.radius, 100), manager.maximumRegionMonitoringDistance)
      var points = Array(config.officePoints.enumerated())
      if let here = latestLocation ?? manager.location {
        points.sort {
          here.distance(from: CLLocation(latitude: $0.element.latitude, longitude: $0.element.longitude))
            < here.distance(from: CLLocation(latitude: $1.element.latitude, longitude: $1.element.longitude))
        }
      }
      for point in points.prefix(slots) {
        let region = CLCircularRegion(
          center: point.element, radius: radius, identifier: "\(Self.regionPrefix)geo_\(point.offset)")
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        registered.append(region)
      }
    }

    store.regionSignature = signature
    log("Monitoring \(registered.count) region(s)")
    // Ask for the current state, so a phone that is already inside checks in.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      registered.forEach { manager.requestState(for: $0) }
    }
  }

  /// A low-accuracy (cell/Wi-Fi based) location session during the shift keeps
  /// the app running in the background, so the scan timer keeps firing.
  private func updateContinuous(_ config: TrackerConfig) {
    let wanted = config.continuousTracking && store.trackingEnabled && config.isWithinShift(Date())
      && Self.hasBackgroundMode("location") && isAuthorized()
    let manager = manager()
    if wanted && !continuousActive {
      manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
      manager.distanceFilter = 100
      manager.startUpdatingLocation()
      continuousActive = true
      log("Background keep-alive location on")
    } else if !wanted && continuousActive {
      manager.stopUpdatingLocation()
      continuousActive = false
      log("Background keep-alive location off")
    }
  }

  private func startTimers(_ config: TrackerConfig) {
    let interval = TimeInterval(min(max(config.scanIntervalSeconds, 10), 300))
    if scanTimer?.timeInterval != interval {
      scanTimer?.invalidate()
      scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
        guard let self = self, let config = self.config else { return }
        self.updateContinuous(config)
        self.scan(trigger: "timer")
      }
    }
    if pingTimer == nil {
      pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
        AttendanceTrackerPlugin.broadcast("onPing", ["timestamp": Self.ms(Date())])
      }
    }
  }

  // MARK: - Scanning

  /// Runs one detection. [exitHint] is set for a region exit: with no other
  /// signal, that confirms the exit without waiting for the debounce.
  func scan(trigger: String, exitHint: Bool = false, completion: (([String: Any]) -> Void)? = nil) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.scan(trigger: trigger, exitHint: exitHint, completion: completion) }
      return
    }
    if scanning {
      queued = (trigger, (queued?.exitHint ?? false) || exitHint)
      if let completion = completion { nextCompletions.append(completion) }
      return
    }
    let eventDriven = ["significantChange", "visit", "region"].contains(trigger)
    if eventDriven && !exitHint, let last = lastScanAt, Date().timeIntervalSince(last) < 15 {
      completion?(store.lastResult ?? [:])
      return
    }
    guard let config = config else {
      completion?(["isInZone": false, "diagnosticLog": "No config; call initialize() first.\n"])
      return
    }

    scanning = true
    if let completion = completion { currentCompletions.append(completion) }
    let task = BackgroundTask(name: "AttendanceScan")
    observe(config, trigger: trigger) { [weak self] observation in
      guard let self = self else { return }
      let result = self.evaluate(observation, config: config, trigger: trigger, exitHint: exitHint)
      self.finishScan(result, task: task)
    }
  }

  private func finishScan(_ result: [String: Any], task: BackgroundTask) {
    lastScanAt = Date()
    scanning = false
    store.lastResult = result
    AttendanceTrackerPlugin.broadcast("onDetection", result)
    let completions = currentCompletions
    currentCompletions = []
    completions.forEach { $0(result) }
    uploadPendingEvents { task.end() }

    if let next = queued {
      queued = nil
      let waiting = nextCompletions
      nextCompletions = []
      let forward: (([String: Any]) -> Void)? = waiting.isEmpty ? nil : { r in waiting.forEach { $0(r) } }
      scan(trigger: next.trigger, exitHint: next.exitHint, completion: forward)
    }
  }

  private func observe(_ config: TrackerConfig, trigger: String, completion: @escaping (Observation) -> Void) {
    let started = Date()
    var observation = Observation()
    observation.log = "Scan started at \(Self.clock(started)) (\(trigger), iOS native, app \(appState()))\n"
    guard config.isWithinShift(started) else {
      completion(observation)
      return
    }

    let group = DispatchGroup()

    group.enter()
    DispatchQueue.global(qos: .utility).async {
      // Can block, so off the main thread.
      let enabled = CLLocationManager.locationServicesEnabled()
      DispatchQueue.main.async {
        observation.gpsEnabled = enabled
        group.leave()
      }
    }

    group.enter()
    acquireLocation(config, since: started) { location, note in
      observation.location = location
      observation.log += note
      group.leave()
    }

    group.enter()
    fetchWifi(config) { ssid, bssid, note in
      observation.ssid = ssid
      observation.bssid = bssid
      observation.wifiEnabled = Self.isOnWifi()
      observation.log += note
      group.leave()
    }

    group.enter()
    rangeBeacons(config) { beacon, note in
      observation.beacon = beacon
      observation.log += note
      group.leave()
    }

    group.enter()
    ble.scan(names: config.bleNames, serviceUuids: config.bleServiceUuids, seconds: 4) { device, enabled, note in
      observation.bleDevice = device
      observation.bleEnabled = enabled
      observation.log += note
      group.leave()
    }

    group.notify(queue: .main) { completion(observation) }
  }

  private func acquireLocation(
    _ config: TrackerConfig, since started: Date, completion: @escaping (CLLocation?, String) -> Void
  ) {
    guard !config.officePoints.isEmpty else {
      completion(nil, "GPS Skip: No Config\n")
      return
    }
    guard isAuthorized() else {
      completion(nil, "GPS Skip: location not authorized.\n")
      return
    }
    if let recent = latestLocation, Date().timeIntervalSince(recent.timestamp) < 15,
      recent.horizontalAccuracy >= 0, recent.horizontalAccuracy <= 65
    {
      completion(recent, "GPS: Using fix from \(Int(Date().timeIntervalSince(recent.timestamp)))s ago.\n")
      return
    }

    let manager = manager()
    var best: CLLocation?
    var done = false
    let finish: () -> Void = { [weak self] in
      guard let self = self, !done else { return }
      done = true
      self.fixWaiter = nil
      manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
      if best == nil, let last = self.latestLocation, Date().timeIntervalSince(last.timestamp) < 120 {
        best = last
      }
      if let best = best {
        completion(best, "GPS: Fix acquired (±\(Int(best.horizontalAccuracy))m).\n")
      } else {
        completion(nil, "GPS Skip: Could not obtain any location fix.\n")
      }
    }
    fixWaiter = { [weak self] location in
      guard let self = self else { return }
      guard let location = location else {
        if !self.continuousActive { finish() }
        return
      }
      if location.timestamp >= started.addingTimeInterval(-5), location.horizontalAccuracy >= 0,
        best == nil || location.horizontalAccuracy < best!.horizontalAccuracy
      {
        best = location
      }
      // requestLocation() answers once; continuous updates improve over a few seconds.
      if let fix = best, fix.horizontalAccuracy <= 65 || !self.continuousActive { finish() }
    }
    manager.desiredAccuracy = kCLLocationAccuracyBest
    if !continuousActive { manager.requestLocation() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }
  }

  private func fetchWifi(_ config: TrackerConfig, completion: @escaping (String?, String?, String) -> Void) {
    guard config.hasWifi else {
      completion(nil, nil, "")
      return
    }
    var done = false
    let finish: (String?, String?, String) -> Void = { ssid, bssid, note in
      DispatchQueue.main.async {
        guard !done else { return }
        done = true
        completion(ssid, bssid, note)
      }
    }
    if #available(iOS 14.0, *) {
      NEHotspotNetwork.fetchCurrent { network in
        if let network = network {
          finish(network.ssid, network.bssid, "Wi-Fi: Connected to '\(network.ssid)' (\(network.bssid))\n")
        } else {
          finish(
            nil, nil,
            "Wi-Fi Skip: no network info (needs a Wi-Fi connection, location permission and the Access WiFi Information entitlement).\n"
          )
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil, nil, "Wi-Fi Skip: network info timed out.\n") }
    } else {
      let info = Self.legacyWifiInfo()
      finish(info.ssid, info.bssid, info.bssid != nil ? "Wi-Fi: Connected to '\(info.ssid ?? "")' (\(info.bssid!))\n" : "Wi-Fi Skip: Not connected.\n")
    }
  }

  private func rangeBeacons(_ config: TrackerConfig, completion: @escaping (String?, String) -> Void) {
    guard !config.beacons.isEmpty else {
      completion(nil, "")
      return
    }
    guard CLLocationManager.isRangingAvailable(), isAuthorized() else {
      completion(nil, "iBeacon Skip: ranging unavailable or location not authorized.\n")
      return
    }
    let manager = manager()
    let constraints = config.beacons.map { $0.constraint }
    var done = false
    let finish: (CLBeacon?) -> Void = { [weak self] beacon in
      guard !done else { return }
      done = true
      self?.beaconWaiter = nil
      constraints.forEach { manager.stopRangingBeacons(satisfying: $0) }
      if let beacon = beacon {
        completion(BeaconSpec.describe(beacon), "iBeacon: MATCH! \(BeaconSpec.describe(beacon)) RSSI: \(beacon.rssi)\n")
      } else {
        completion(nil, "iBeacon: none of \(constraints.count) configured beacon(s) in range.\n")
      }
    }
    beaconWaiter = { beacon in
      if config.beacons.contains(where: { $0.matches(beacon) }) { finish(beacon) }
    }
    constraints.forEach { manager.startRangingBeacons(satisfying: $0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(nil) }
  }

  // MARK: - Zone state

  private func evaluate(_ observation: Observation, config: TrackerConfig, trigger: String, exitHint: Bool) -> [String: Any] {
    let now = Date()
    var log = observation.log
    var result: [String: Any] = [
      "trigger": trigger,
      "timestamp": Self.ms(now),
      "appState": appState(),
      "status": [
        "isGpsEnabled": observation.gpsEnabled,
        "isWifiEnabled": observation.wifiEnabled,
        "isBleEnabled": observation.bleEnabled,
      ],
    ]

    guard config.isWithinShift(now) else {
      log += "Scan skipped: Outside of shift hours (\(Self.clock(now))).\n"
      result["isInZone"] = false
      result["diagnosticLog"] = log
      if store.wasInZone {
        store.wasInZone = false
        store.failCount = 0
        _ = recordEvent("shiftEnded", result: result)
        notify(config.shiftEndedTitle, config.shiftEndedBody, sound: config.outOfZoneSound, config: config)
      }
      return result
    }

    var byGps = false
    if let location = observation.location {
      if #available(iOS 15.0, *), location.sourceInformation?.isSimulatedBySoftware == true {
        log += "GPS: REJECTED - simulated location.\n"
      } else {
        result["latitude"] = location.coordinate.latitude
        result["longitude"] = location.coordinate.longitude
        result["accuracy"] = location.horizontalAccuracy
        let distance = config.officePoints
          .map { location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }
          .min()
        if let distance = distance {
          result["distance"] = distance
          byGps = distance <= config.radius
          log += byGps
            ? "GPS: MATCH (\(String(format: "%.1f", distance))m)\n"
            : "GPS: NO MATCH (\(String(format: "%.1f", distance))m from office)\n"
        }
      }
    }

    var byWifi = false
    if let bssid = observation.bssid {
      result["wifiBssid"] = bssid
      byWifi = config.wifiBSSIDs.contains(TrackerConfig.normalizeBssid(bssid))
    }
    if let ssid = observation.ssid {
      result["wifiSsid"] = ssid
      byWifi = byWifi || config.wifiSSIDs.contains(ssid)
    }
    if byWifi { log += "Wi-Fi: MATCH!\n" }

    let byBeacon = observation.beacon != nil
    if let beacon = observation.beacon { result["beacon"] = beacon }
    let byBle = observation.bleDevice != nil
    if let device = observation.bleDevice { result["bleDevice"] = device }

    var inZone = byGps || byWifi || byBeacon || byBle
    var byNfc = false
    var byQr = false
    if !inZone, let checkpoint = store.lastCheckpoint, let ts = (checkpoint["timestamp"] as? NSNumber)?.doubleValue {
      let at = Date(timeIntervalSince1970: ts / 1000)
      if config.isCheckpointValid(at: at, now: now) {
        inZone = true
        let source = checkpoint["source"] as? String
        byNfc = source == "nfc"
        byQr = source == "qr"
        result["checkpointId"] = checkpoint["checkpointId"]
        log += "CHECKPOINT: \(source?.uppercased() ?? "") \"\(checkpoint["checkpointId"] ?? "")\" from \(Self.clock(at)) is still valid.\n"
      }
    }

    let matched = [byGps ? "GPS" : nil, byWifi ? "Wi-Fi" : nil, byBeacon ? "iBeacon" : nil, byBle ? "BLE" : nil]
      .compactMap { $0 }
    let via = matched.isEmpty ? (byNfc ? "NFC" : "QR") : matched.joined(separator: " + ")
    log += inZone ? "FUSION SUCCESS (via \(via))\n" : "FUSION FAIL: Nothing matched\n"

    result["isInZone"] = inZone
    result["byGps"] = byGps
    result["byWifi"] = byWifi
    result["byBeacon"] = byBeacon
    result["byBle"] = byBle
    result["byNfc"] = byNfc
    result["byQr"] = byQr
    result["diagnosticLog"] = log

    applyTransition(inZone: inZone, result: result, config: config, exitHint: exitHint)
    return result
  }

  /// Same state machine as the Android Dart service: enter at once, exit after
  /// [exitDebounceCount] misses (or one miss confirmed by a region exit).
  private func applyTransition(inZone: Bool, result: [String: Any], config: TrackerConfig, exitHint: Bool) {
    let wasInZone = store.wasInZone
    let byCheckpoint = (result["byNfc"] as? Bool) == true || (result["byQr"] as? Bool) == true
    if inZone && !wasInZone && !byCheckpoint, let tapOutAt = store.tapOutAt,
      Self.ms(Date()) - tapOutAt < Double(config.tapOutCooldownMinutes) * 60_000
    {
      // Just tapped out; sensors may still see the user walking away.
      log("In zone again right after a tap-out; waiting for the cool-down")
    } else if inZone && !wasInZone {
      store.wasInZone = true
      store.failCount = 0
      _ = recordEvent("enter", result: result)
      let label = [
        "nfc": "NFC tag", "qr": "QR code", "beacon": "iBeacon", "wifi": "Wi-Fi", "ble": "Bluetooth", "gps": "GPS",
      ][Self.source(of: result) ?? ""]
      notify(
        config.welcomeTitle, "\(config.welcomeBody)\(label.map { " (via \($0))" } ?? "")",
        sound: config.welcomeSound, config: config)
    } else if inZone {
      store.failCount = 0
    } else if wasInZone {
      let threshold = min(max(config.exitDebounceCount, 1), 10)
      let fails = store.failCount + 1
      if exitHint || fails >= threshold {
        store.wasInZone = false
        store.failCount = 0
        _ = recordEvent("exit", result: result)
        notify(config.outOfZoneTitle, config.outOfZoneBody, sound: config.outOfZoneSound, config: config)
      } else {
        store.failCount = fails
        log("Debouncing exit (\(fails)/\(threshold))")
      }
    }
  }

  private func recordEvent(_ type: String, result: [String: Any]) -> [String: Any] {
    let now = Date()
    var event: [String: Any] = [
      "id": "\(Int64(now.timeIntervalSince1970 * 1_000_000))-\(type)",
      "type": type,
      "appState": appState(),
      "timestamp": Self.ms(now),
      "uploaded": false,
    ]
    // Exits carry a source only when they come from an NFC/QR tap-out.
    if type == "enter" || type == "checkpoint" || type == "exit", let source = Self.source(of: result) {
      event["source"] = source
    }
    for key in ["trigger", "checkpointId", "latitude", "longitude", "accuracy", "wifiBssid", "wifiSsid", "bleDevice", "beacon"] {
      if let value = result[key], !(value is NSNull) { event[key] = value }
    }
    store.appendEvent(event)
    AttendanceTrackerPlugin.broadcast("onEvent", event)
    log("Recorded \(type) event")
    return event
  }

  // MARK: - Output

  private func notify(_ title: String, _ body: String, sound: String?, config: TrackerConfig?) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if let sound = sound, !sound.isEmpty {
      content.sound = UNNotificationSound(named: UNNotificationSoundName(sound.contains(".") ? sound : "\(sound).wav"))
    } else {
      content.sound = .default
    }
    let request = UNNotificationRequest(
      identifier: "attendance_tracker_\(UUID().uuidString)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { [weak self] error in
      if let error = error { self?.log("Notification failed: \(error.localizedDescription)") }
    }
    if config?.enableTts == true && UIApplication.shared.applicationState == .active {
      speech.speak(AVSpeechUtterance(string: "\(title). \(body)"))
    }
  }

  /// POSTs events to `apiEndpoint` one by one; stops at the first failure and retries on the next scan.
  private func uploadPendingEvents(completion: @escaping () -> Void) {
    guard let config = config, let url = config.apiEndpoint, !uploading else {
      completion()
      return
    }
    let events = Array(store.events(pendingOnly: false).filter { ($0["uploaded"] as? Bool) != true }.prefix(20))
    guard !events.isEmpty else {
      completion()
      return
    }
    uploading = true
    let task = BackgroundTask(name: "AttendanceUpload")
    var uploaded: [String] = []

    func done() {
      if !uploaded.isEmpty { self.store.markEventsUploaded(Set(uploaded), hasEndpoint: true) }
      self.uploading = false
      task.end()
      completion()
    }

    func send(_ index: Int) {
      guard index < events.count else {
        done()
        return
      }
      var request = URLRequest(url: url, timeoutInterval: 15)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      config.apiHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
      request.httpBody = try? JSONSerialization.data(withJSONObject: events[index], options: [])
      URLSession.shared.dataTask(with: request) { _, response, error in
        DispatchQueue.main.async {
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          if error == nil, (200..<300).contains(status), let id = events[index]["id"] as? String {
            uploaded.append(id)
            send(index + 1)
          } else {
            done()
          }
        }
      }.resume()
    }

    send(0)
  }

  // MARK: - CLLocationManagerDelegate

  public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    latestLocation = location
    if let waiter = fixWaiter {
      waiter(location)
      return
    }
    // Without the keep-alive session, an update here is a significant-change wake-up.
    guard !continuousActive, store.trackingEnabled else { return }
    if let config = config, config.officePoints.count + config.beacons.count > Self.maxRegions {
      // Only the nearest offices fit in 20 regions; re-pick them for the new position.
      registerRegions(config, force: true)
    }
    scan(trigger: "significantChange")
  }

  public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    if let error = error as? CLError, error.code == .locationUnknown, continuousActive { return }
    log("Location error: \(error.localizedDescription)")
    fixWaiter?(nil)
  }

  public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    guard isOurs(region), store.trackingEnabled else { return }
    log("Entered region \(region.identifier)")
    scan(trigger: "region")
  }

  public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard isOurs(region), store.trackingEnabled else { return }
    log("Exited region \(region.identifier)")
    scan(trigger: "region", exitHint: true)
  }

  public func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
    guard isOurs(region), store.trackingEnabled else { return }
    if state == .inside || (state == .outside && store.wasInZone) { scan(trigger: "region") }
  }

  public func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    guard store.trackingEnabled else { return }
    scan(trigger: "visit")
  }

  public func locationManager(
    _ manager: CLLocationManager, didRange beacons: [CLBeacon], satisfying beaconConstraint: CLBeaconIdentityConstraint
  ) {
    for beacon in beacons where beacon.proximity != .unknown { beaconWaiter?(beacon) }
  }

  public func locationManager(
    _ manager: CLLocationManager, didFailRangingFor beaconConstraint: CLBeaconIdentityConstraint, error: Error
  ) {
    log("iBeacon ranging failed: \(error.localizedDescription)")
  }

  public func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
    log("Region monitoring failed for \(region?.identifier ?? "?"): \(error.localizedDescription)")
  }

  @available(iOS 14.0, *)
  public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    authorizationChanged()
  }

  public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    authorizationChanged()
  }

  private func authorizationChanged() {
    if store.trackingEnabled { startMonitoring(forceRegions: false, initialScan: false) }
  }

  // MARK: - Helpers

  /// foreground: on screen; background: running hidden; terminated: relaunched by iOS and not opened yet.
  func appState() -> String {
    if UIApplication.shared.applicationState == .active { return "foreground" }
    return launchedInBackground ? "terminated" : "background"
  }

  private func isOurs(_ region: CLRegion) -> Bool { region.identifier.hasPrefix(Self.regionPrefix) }

  private func flag(for source: String) -> String { source == "nfc" ? "byNfc" : "byQr" }

  private func log(_ message: String) { NSLog("AttendanceTracker: %@", message) }

  static func source(of result: [String: Any]) -> String? {
    for (key, source) in [("byNfc", "nfc"), ("byQr", "qr"), ("byBeacon", "beacon"), ("byWifi", "wifi"), ("byBle", "ble"), ("byGps", "gps")]
    where (result[key] as? Bool) == true {
      return source
    }
    return nil
  }

  static func hasBackgroundMode(_ mode: String) -> Bool {
    (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains(mode) ?? false
  }

  static func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }

  private static func clock(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
    return String(format: "%d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
  }

  /// True when the current route is Wi-Fi (iOS cannot read the Wi-Fi radio state).
  static func isOnWifi() -> Bool {
    var zeroAddress = sockaddr_in()
    zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    zeroAddress.sin_family = sa_family_t(AF_INET)

    guard
      let reachability = withUnsafePointer(
        to: &zeroAddress,
        {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            SCNetworkReachabilityCreateWithAddress(nil, $0)
          }
        })
    else { return false }

    var flags: SCNetworkReachabilityFlags = []
    guard SCNetworkReachabilityGetFlags(reachability, &flags) else { return false }
    return flags.contains(.reachable) && !flags.contains(.isWWAN)
  }

  private static func legacyWifiInfo() -> (ssid: String?, bssid: String?) {
    guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return (nil, nil) }
    for name in interfaces {
      if let info = CNCopyCurrentNetworkInfo(name as CFString) as? [String: Any] {
        return (info[kCNNetworkInfoKeySSID as String] as? String, info[kCNNetworkInfoKeyBSSID as String] as? String)
      }
    }
    return (nil, nil)
  }
}
