import Foundation

/// Optional per-printer overrides for setups that differ from the defaults — e.g. a camera on a
/// separate IP, or a non-standard light command. Kept out of `SavedPrinter` (and its many add/update
/// paths) in a small side store keyed by serial.
struct PrinterOverrides: Codable, Equatable, Sendable {
    var cameraHost: String?   // camera reachable on a different IP/host than the printer
    var ledOn: String?        // custom "light on" command (Bambu JSON or Klipper G-code)
    var ledOff: String?       // custom "light off" command

    var isEmpty: Bool {
        [cameraHost, ledOn, ledOff].allSatisfy { ($0 ?? "").isEmpty }
    }
}

@MainActor
final class PrinterOverridesStore {
    static let shared = PrinterOverridesStore()
    private let defaults = BambuDefaults.shared
    private let key = "printer-overrides-v1"
    private var all: [String: PrinterOverrides] = [:]

    private init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: PrinterOverrides].self, from: data) {
            all = decoded
        }
    }

    func overrides(for serial: String) -> PrinterOverrides { all[serial] ?? PrinterOverrides() }

    func set(_ overrides: PrinterOverrides, for serial: String) {
        if overrides.isEmpty { all.removeValue(forKey: serial) } else { all[serial] = overrides }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }
}
