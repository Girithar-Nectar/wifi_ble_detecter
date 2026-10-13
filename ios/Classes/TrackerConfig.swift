import CoreLocation
import Foundation

/// An iBeacon from the config: "UUID", "UUID:major" or "UUID:major:minor".
struct BeaconSpec {
  let uuid: UUID
  let major: CLBeaconMajorValue?
  let minor: CLBeaconMinorValue?

  init?(_ value: String) {
    let parts = value.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let first = parts.first, let uuid = UUID(uuidString: first) else { return nil }
    self.uuid = uuid
    major = parts.count > 1 ? CLBeaconMajorValue(parts[1]) : nil
    minor = parts.count > 2 && major != nil ? CLBeaconMinorValue(parts[2]) : nil
  }

  var constraint: CLBeaconIdentityConstraint {
    if let major = major, let minor = minor {
      return CLBeaconIdentityConstraint(uuid: uuid, major: major, minor: minor)
    }
    if let major = major {
      return CLBeaconIdentityConstraint(uuid: uuid, major: major)
    }
    return CLBeaconIdentityConstraint(uuid: uuid)
  }

  func region(identifier: String) -> CLBeaconRegion {
    if let major = major, let minor = minor {
      return CLBeaconRegion(uuid: uuid, major: major, minor: minor, identifier: identifier)
    }
    if let major = major {
      return CLBeaconRegion(uuid: uuid, major: major, identifier: identifier)
    }
    return CLBeaconRegion(uuid: uuid, identifier: identifier)
  }

  func matches(_ beacon: CLBeacon) -> Bool {
    beacon.uuid == uuid
      && (major == nil || beacon.major.uint16Value == major)
      && (minor == nil || beacon.minor.uint16Value == minor)
  }

  static func describe(_ beacon: CLBeacon) -> String {
    "\(beacon.uuid.uuidString.lowercased()):\(beacon.major):\(beacon.minor)"
  }
}

/// Native view of the Dart AttendanceConfig (same JSON keys).
struct TrackerConfig {
  let officePoints: [CLLocationCoordinate2D]
  let radius: Double
  let wifiSSIDs: [String]
  /// Normalized with [normalizeBssid].
  let wifiBSSIDs: [String]
  /// Normalized with [normalizeName].
  let bleNames: [String]
  let bleServiceUuids: [String]
  let beacons: [BeaconSpec]
  let checkpointValidityMinutes: Int
  let checkpointToggle: Bool
  let tapOutCooldownMinutes: Int
  let continuousTracking: Bool
  let shiftStartMs: Int
  let shiftEndMs: Int
  let scanIntervalSeconds: Int
  let apiEndpoint: URL?
  let apiHeaders: [String: String]
  let welcomeTitle: String
  let welcomeBody: String
  let outOfZoneTitle: String
  let outOfZoneBody: String
  let shiftEndedTitle: String
  let shiftEndedBody: String
  let welcomeSound: String?
  let outOfZoneSound: String?
  let enableTts: Bool
  let exitDebounceCount: Int

  init(_ json: [String: Any]) {
    func strings(_ key: String) -> [String] { (json[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
    func string(_ key: String) -> String? { json[key] as? String }
    func int(_ key: String, _ fallback: Int) -> Int { (json[key] as? NSNumber)?.intValue ?? fallback }

    officePoints = strings("officePoints").compactMap(TrackerConfig.parseWktPoint)
    radius = (json["geofenceRadius"] as? NSNumber)?.doubleValue ?? 100
    wifiSSIDs = strings("wifiSSIDs")
    wifiBSSIDs = strings("wifiBSSIDs").map(TrackerConfig.normalizeBssid)
    bleNames = strings("bleDeviceNames").map(TrackerConfig.normalizeName)
    bleServiceUuids = strings("bleServiceUuids")
    beacons = strings("iBeacons").compactMap(BeaconSpec.init)
    checkpointValidityMinutes = int("checkpointValidityMinutes", 60)
    checkpointToggle = (json["checkpointToggle"] as? NSNumber)?.boolValue ?? false
    tapOutCooldownMinutes = int("tapOutCooldownMinutes", 5)
    continuousTracking = (json["iosContinuousTracking"] as? NSNumber)?.boolValue ?? true
    shiftStartMs = int("shiftStartMs", 0)
    shiftEndMs = int("shiftEndMs", 86_399_000)
    scanIntervalSeconds = int("scanIntervalSeconds", 60)
    apiEndpoint = string("apiEndpoint").flatMap { $0.isEmpty ? nil : URL(string: $0) }
    apiHeaders = (json["apiHeaders"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
    welcomeTitle = string("welcomeTitle") ?? "Welcome!"
    welcomeBody = string("welcomeBody") ?? "You are in the office zone. Check-in detected."
    outOfZoneTitle = string("outOfZoneTitle") ?? "Out of Zone"
    outOfZoneBody = string("outOfZoneBody") ?? "You left the office. Don't forget to take a break or checkout."
    shiftEndedTitle = string("shiftEndedTitle") ?? "Shift Ended"
    shiftEndedBody = string("shiftEndedBody") ?? "You are outside shift hours. Automatically checking you out."
    welcomeSound = string("welcomeSound")
    outOfZoneSound = string("outOfZoneSound")
    enableTts = (json["enableTts"] as? NSNumber)?.boolValue ?? false
    exitDebounceCount = int("exitDebounceCount", 3)
  }

  var hasWifi: Bool { !wifiSSIDs.isEmpty || !wifiBSSIDs.isEmpty }

  /// Changes whenever the monitored regions must be registered again.
  var regionSignature: String {
    let points = officePoints.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";")
    let beaconIds = beacons.map { "\($0.uuid.uuidString):\($0.major ?? 0):\($0.minor ?? 0)" }.joined(separator: ";")
    return "\(points)|\(radius)|\(beaconIds)"
  }

  func isWithinShift(_ date: Date) -> Bool {
    let current = TrackerConfig.msOfDay(date)
    if shiftStartMs <= shiftEndMs {
      return current >= shiftStartMs && current <= shiftEndMs
    }
    // Shift spans across midnight (e.g., 22:00 to 06:00)
    return current >= shiftStartMs || current <= shiftEndMs
  }

  /// Start of the shift that contains [now] (or the most recent one).
  func currentShiftStart(_ now: Date) -> Date {
    let start = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(shiftStartMs) / 1000)
    return start > now ? start.addingTimeInterval(-86_400) : start
  }

  /// Whether an NFC/QR checkpoint taken at [at] still proves presence at [now].
  func isCheckpointValid(at: Date, now: Date) -> Bool {
    if at > now.addingTimeInterval(60) { return false }
    if checkpointValidityMinutes > 0 {
      return now.timeIntervalSince(at) <= Double(checkpointValidityMinutes) * 60
    }
    return isWithinShift(now) && at >= currentShiftStart(now)
  }

  static func msOfDay(_ date: Date) -> Int {
    let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
    return (c.hour ?? 0) * 3_600_000 + (c.minute ?? 0) * 60_000 + (c.second ?? 0) * 1000
      + (c.nanosecond ?? 0) / 1_000_000
  }

  /// Lower-cases and pads each octet to two digits; iOS drops leading zeros.
  static func normalizeBssid(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespaces).lowercased().split(separator: ":", omittingEmptySubsequences: false)
      .map { $0.count == 1 ? "0\($0)" : String($0) }
      .joined(separator: ":")
  }

  /// Same as the Dart side: lower-case, no colons, trimmed.
  static func normalizeName(_ value: String) -> String {
    value.replacingOccurrences(of: ":", with: "").lowercased().trimmingCharacters(in: .whitespaces)
  }

  /// "POINT(lng lat)" -> coordinate.
  static func parseWktPoint(_ wkt: String) -> CLLocationCoordinate2D? {
    let pattern = "POINT\\s*\\(\\s*(-?\\d+\\.?\\d*)\\s+(-?\\d+\\.?\\d*)\\s*\\)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let match = regex.firstMatch(in: wkt, range: NSRange(wkt.startIndex..., in: wkt)),
      let lngRange = Range(match.range(at: 1), in: wkt),
      let latRange = Range(match.range(at: 2), in: wkt),
      let lng = Double(wkt[lngRange]),
      let lat = Double(wkt[latRange])
    else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lng)
  }
}
