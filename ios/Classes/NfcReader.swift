import CoreNFC
import Flutter
import Foundation

/// Reads one NFC tag (UID plus NDEF text/URI records) with the system sheet.
/// Needs the "Near Field Communication Tag Reading" capability and
/// NFCReaderUsageDescription in the host app.
final class NfcReader: NSObject, NFCTagReaderSessionDelegate {
  private var session: NFCTagReaderSession?
  private var result: FlutterResult?

  static var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

  func start(alertMessage: String?, result: @escaping FlutterResult) {
    guard NFCTagReaderSession.readingAvailable else {
      result(FlutterError(code: "NFC_UNAVAILABLE", message: "This device cannot read NFC tags.", details: nil))
      return
    }
    finish(error: FlutterError(code: "CANCELLED", message: "Replaced by a new NFC scan.", details: nil))
    session?.invalidate()

    guard let session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: nil) else {
      result(FlutterError(code: "NFC_UNAVAILABLE", message: "Could not start an NFC session.", details: nil))
      return
    }
    self.result = result
    self.session = session
    session.alertMessage = alertMessage ?? "Hold your iPhone near the attendance tag."
    session.begin()
  }

  func stop() {
    finish(error: FlutterError(code: "CANCELLED", message: "NFC scan cancelled.", details: nil))
    session?.invalidate()
    session = nil
  }

  private func finish(value: Any? = nil, error: FlutterError? = nil) {
    guard let result = result else { return }
    self.result = nil
    result(error ?? value)
  }

  /// Completes on the main queue, then closes the sheet; the invalidation
  /// callback that follows finds no pending result.
  private func complete(_ session: NFCTagReaderSession, uid: String?, payloads: [String]) {
    var value: [String: Any] = ["payloads": payloads]
    if let uid = uid { value["uid"] = uid }
    DispatchQueue.main.async {
      self.finish(value: value)
      session.alertMessage = "Checkpoint read."
      session.invalidate()
    }
  }

  // MARK: - NFCTagReaderSessionDelegate

  func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

  func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
    DispatchQueue.main.async {
      let code = (error as? NFCReaderError)?.code
      if code == .readerSessionInvalidationErrorUserCanceled {
        self.finish(error: FlutterError(code: "CANCELLED", message: "NFC scan cancelled.", details: nil))
      } else if code == .readerSessionInvalidationErrorSessionTimeout {
        self.finish(error: FlutterError(code: "TIMEOUT", message: "No NFC tag was detected.", details: nil))
      } else {
        self.finish(error: FlutterError(code: "NFC_ERROR", message: error.localizedDescription, details: nil))
      }
      if self.session === session { self.session = nil }
    }
  }

  func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
    guard let tag = tags.first else { return }
    session.connect(to: tag) { error in
      if error != nil {
        session.invalidate(errorMessage: "Could not read the tag. Try again.")
        return
      }
      let (uid, ndefTag) = Self.identify(tag)
      guard let ndef = ndefTag else {
        self.complete(session, uid: uid, payloads: [])
        return
      }
      ndef.queryNDEFStatus { status, _, error in
        if error != nil || status == .notSupported {
          self.complete(session, uid: uid, payloads: [])
          return
        }
        ndef.readNDEF { message, _ in
          self.complete(session, uid: uid, payloads: message.map(Self.parse) ?? [])
        }
      }
    }
  }

  // MARK: - Parsing

  private static func identify(_ tag: NFCTag) -> (String?, NFCNDEFTag?) {
    switch tag {
    case .miFare(let mifare):
      return (hex(mifare.identifier), mifare)
    case .iso7816(let iso7816):
      return (hex(iso7816.identifier), iso7816)
    case .iso15693(let iso15693):
      return (hex(iso15693.identifier), iso15693)
    case .feliCa(let feliCa):
      return (hex(feliCa.currentIDm), feliCa)
    @unknown default:
      return (nil, nil)
    }
  }

  private static func hex(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: ":")
  }

  private static func parse(_ message: NFCNDEFMessage) -> [String] {
    message.records.compactMap { record in
      if let url = record.wellKnownTypeURIPayload() { return url.absoluteString }
      let (text, _) = record.wellKnownTypeTextPayload()
      if let text = text { return text }
      if record.typeNameFormat == .media, let type = String(data: record.type, encoding: .utf8), type.hasPrefix("text/") {
        return String(data: record.payload, encoding: .utf8)
      }
      if record.typeNameFormat == .nfcExternal { return String(data: record.payload, encoding: .utf8) }
      return nil
    }
  }
}
