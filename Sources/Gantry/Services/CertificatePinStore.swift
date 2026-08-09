import CryptoKit
import Foundation

final class CertificatePinStore: @unchecked Sendable {
    static let shared = CertificatePinStore()

    enum ValidationResult: Equatable {
        case firstUse
        case matched
        case mismatch

        var accepted: Bool { self != .mismatch }
    }

    private let lock = NSLock()
    private let storageKey = "printer-certificate-pins-v1"

    func validate(certificateData: Data, for serial: String) -> ValidationResult {
        let fingerprint = SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        defer { lock.unlock() }

        let defaults = BambuDefaults.shared
        var pins = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        if let stored = pins[serial] {
            return stored == fingerprint ? .matched : .mismatch
        }
        pins[serial] = fingerprint
        defaults.set(pins, forKey: storageKey)
        return .firstUse
    }

    func delete(for serial: String) {
        lock.lock()
        defer { lock.unlock() }
        let defaults = BambuDefaults.shared
        var pins = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        pins.removeValue(forKey: serial)
        defaults.set(pins, forKey: storageKey)
    }
}
