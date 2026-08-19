import Foundation

/// Optional per-printer overrides for setups that differ from the defaults — e.g. a camera on a
/// separate IP, or a non-standard light command. Kept out of `SavedPrinter` (and its many add/update
/// paths) in a small side store keyed by serial.
struct PrinterOverrides: Codable, Equatable, Sendable {
    var cameraHost: String?   // camera reachable on a different IP/host than the printer
    var ledOn: String?        // custom "light on" command (Bambu JSON or Klipper G-code)
    var ledOff: String?       // custom "light off" command

    // Klipper/Moonraker object-name overrides for non-standard configs. Empty = use the default /
    // auto-detected object.
    var nozzleObject: String?   // default "extruder"
    var bedObject: String?      // default "heater_bed"
    var chamberObject: String?  // default: auto-detect a *chamber* temperature_sensor/heater_generic
    var fanObject: String?      // default "fan"

    var isEmpty: Bool {
        [cameraHost, ledOn, ledOff, nozzleObject, bedObject, chamberObject, fanObject]
            .allSatisfy { ($0 ?? "").isEmpty }
    }

    /// Moonraker object names to actually query/parse (falling back to Klipper defaults).
    var moonrakerObjects: MoonrakerObjects {
        MoonrakerObjects(
            nozzle: nonEmpty(nozzleObject) ?? "extruder",
            bed: nonEmpty(bedObject) ?? "heater_bed",
            chamber: nonEmpty(chamberObject),
            fan: nonEmpty(fanObject) ?? "fan")
    }

    private func nonEmpty(_ s: String?) -> String? { (s?.isEmpty == false) ? s : nil }
}

/// The Moonraker object names to read temperatures and the cooling fan from. Custom configs can point
/// these at non-standard object names via per-printer overrides.
struct MoonrakerObjects: Equatable, Sendable {
    var nozzle: String = "extruder"
    var bed: String = "heater_bed"
    var chamber: String?      // nil = auto-detect by the "chamber" name convention
    var fan: String = "fan"
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
