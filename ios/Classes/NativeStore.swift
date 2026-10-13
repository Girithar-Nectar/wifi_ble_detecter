import Foundation

/// UserDefaults-backed store for config, zone state, events and checkpoints, so
/// native code can work after iOS relaunches the app with no Dart running.
final class NativeStore {
  static let shared = NativeStore()

  private let defaults = UserDefaults.standard
  private let lock = NSLock()
  private let maxEvents = 500
  private let maxPending = 20

  private func key(_ name: String) -> String { "attendance_tracker.\(name)" }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private func readJSON(_ name: String) -> Any? {
    guard let data = defaults.data(forKey: key(name)) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [])
  }

  private func writeJSON(_ name: String, _ value: Any?) {
    guard let value = value, JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [])
    else {
      defaults.removeObject(forKey: key(name))
      return
    }
    defaults.set(data, forKey: key(name))
  }

  var configDict: [String: Any]? {
    get { locked { readJSON("config") as? [String: Any] } }
    set { locked { writeJSON("config", newValue) } }
  }

  var trackingEnabled: Bool {
    get { locked { defaults.bool(forKey: key("tracking_enabled")) } }
    set { locked { defaults.set(newValue, forKey: key("tracking_enabled")) } }
  }

  var wasInZone: Bool {
    get { locked { defaults.bool(forKey: key("was_in_zone")) } }
    set { locked { defaults.set(newValue, forKey: key("was_in_zone")) } }
  }

  var failCount: Int {
    get { locked { defaults.integer(forKey: key("fail_count")) } }
    set { locked { defaults.set(newValue, forKey: key("fail_count")) } }
  }

  /// When the user last checked out with an NFC/QR tap (ms since epoch).
  var tapOutAt: Double? {
    get { locked { defaults.object(forKey: key("tap_out_at")) as? Double } }
    set { locked { defaults.set(newValue, forKey: key("tap_out_at")) } }
  }

  var regionSignature: String? {
    get { locked { defaults.string(forKey: key("region_signature")) } }
    set { locked { defaults.set(newValue, forKey: key("region_signature")) } }
  }

  var lastCheckpoint: [String: Any]? {
    get { locked { readJSON("last_checkpoint") as? [String: Any] } }
    set { locked { writeJSON("last_checkpoint", newValue) } }
  }

  var lastResult: [String: Any]? {
    get { locked { readJSON("last_result") as? [String: Any] } }
    set { locked { writeJSON("last_result", newValue) } }
  }

  func appendEvent(_ event: [String: Any]) {
    locked {
      var events = readEvents()
      events.append(event)
      while events.count > maxEvents {
        let index = events.firstIndex { ($0["acknowledged"] as? Bool) == true } ?? 0
        events.remove(at: index)
      }
      writeJSON("events", events)
    }
  }

  func events(pendingOnly: Bool) -> [[String: Any]] {
    locked { readEvents().filter { !pendingOnly || ($0["acknowledged"] as? Bool) != true } }
  }

  /// The host app synced these; dropped once uploaded too (or when there is no endpoint).
  func acknowledgeEvents(_ ids: Set<String>, hasEndpoint: Bool) {
    updateEvents(ids, hasEndpoint: hasEndpoint) { $0["acknowledged"] = true }
  }

  func markEventsUploaded(_ ids: Set<String>, hasEndpoint: Bool) {
    updateEvents(ids, hasEndpoint: hasEndpoint) { $0["uploaded"] = true }
  }

  func addPendingCheckpoint(_ raw: [String: Any]) {
    locked {
      var pending = (readJSON("pending_checkpoints") as? [[String: Any]]) ?? []
      pending.append(raw)
      writeJSON("pending_checkpoints", Array(pending.suffix(maxPending)))
    }
  }

  /// Returns and clears the raw checkpoints, so each is processed once.
  func takePendingCheckpoints() -> [[String: Any]] {
    locked {
      let pending = (readJSON("pending_checkpoints") as? [[String: Any]]) ?? []
      defaults.removeObject(forKey: key("pending_checkpoints"))
      return pending
    }
  }

  private func readEvents() -> [[String: Any]] {
    (readJSON("events") as? [[String: Any]]) ?? []
  }

  private func updateEvents(_ ids: Set<String>, hasEndpoint: Bool, change: (inout [String: Any]) -> Void) {
    locked {
      var kept: [[String: Any]] = []
      for var event in readEvents() {
        if let id = event["id"] as? String, ids.contains(id) { change(&event) }
        let acknowledged = (event["acknowledged"] as? Bool) == true
        let uploaded = (event["uploaded"] as? Bool) == true
        if !(acknowledged && (uploaded || !hasEndpoint)) { kept.append(event) }
      }
      writeJSON("events", kept)
    }
  }
}
