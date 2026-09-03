import Foundation

enum PrinterState: String, Codable, Sendable {
    case idle
    case printing
    case paused
    case finished
    case error
    case offline

    var label: String {
        switch self {
        case .idle: "Gotowa"
        case .printing: "Drukowanie"
        case .paused: "Wstrzymana"
        case .finished: "Zakończono"
        case .error: "Błąd"
        case .offline: "Offline"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "checkmark.circle.fill"
        case .printing: "printer.fill"
        case .paused: "pause.circle.fill"
        case .finished: "checkmark.seal.fill"
        case .error: "exclamationmark.triangle.fill"
        case .offline: "wifi.slash"
        }
    }
}

struct PrinterTelemetry: Equatable, Sendable {
    var state: PrinterState = .offline
    var progress: Int = 0
    var remainingMinutes: Int?
    var nozzleTemperature: Double?
    var nozzleTargetTemperature: Double?
    // Second nozzle on dual-nozzle printers (H2D); nil on single-nozzle machines.
    var nozzleTemperature2: Double?
    var nozzleTargetTemperature2: Double?
    var bedTemperature: Double?
    var bedTargetTemperature: Double?
    var chamberTemperature: Double?
    /// Set only by machines with a heated chamber (H2D); nil or 0 elsewhere.
    var chamberTargetTemperature: Double?
    var currentLayer: Int?
    var totalLayers: Int?
    // Cooling fans as a percentage (parsed from Bambu's 0–15 gear). Aux = big_fan1, chamber = big_fan2.
    var partFanPercent: Int?
    var auxFanPercent: Int?
    var chamberFanPercent: Int?
    var speedLevel: Int?        // Bambu spd_lvl: 1 Silent, 2 Standard, 3 Sport, 4 Ludicrous
    var speedPercent: Int?      // Bambu spd_mag
    var nozzleDiameter: Double?
    var currentStage: Int?
    var jobName: String?
    /// Klipper/Moonraker `print_stats.filament_used` (mm, cumulative for the current print). Used to
    /// subtract real grams from the assigned spool on finish. Bambu has no equivalent (grams come from
    /// the sliced 3mf instead).
    var filamentUsedMM: Double?
    /// Bambu: the file currently being printed (for fetching the 3mf's per-filament used_g later).
    var gcodeFile: String?
    var errorCode: UInt64 = 0
    var hmsCodes: [String] = []
    // Physical filament modules (AMS / AMS HT / CFS / MMU / external). Replaces the flat slot list
    // as the primary source for the dashboard; `amsSlots` stays as a flat compatibility view used by
    // notifications and the menu bar.
    var filamentGroups: [FilamentGroup] = []
    // One entry for a single-nozzle machine, two (left/right) for dual-nozzle printers like the H2D.
    var nozzles: [NozzleTelemetry] = []
    var amsSlots: [AMSSlot] = []
    var amsHumidity: Int?
    var amsTemperature: Double?
    /// Dev diagnostic: the raw AMS-related JSON the printer last reported (developer mode only).
    var debugAMS: String?
    var lastUpdated: Date?
}

/// Which physical filament system a group came from.
enum FilamentSourceType: String, Codable, Sendable {
    case ams        // standard 4-slot Bambu AMS / AMS Lite
    case amsHT      // single-station Bambu AMS HT
    case cfs        // Creality Filament System
    case mmu        // Klipper / Happy Hare multi-material unit
    case external   // external spool (vt_tray, CFS type 1, …)
    case canvas     // Elegoo Canvas (Centauri Carbon 2)
}

/// One physical filament module and its slots. Empty slots stay in the group so the layout never
/// collapses when a spool is removed.
struct FilamentGroup: Equatable, Identifiable, Sendable {
    let id: String
    let sourceType: FilamentSourceType
    let displayName: String       // AMS A, AMS HT, CFS 1, MMU, EXT
    let declaredCapacity: Int     // 1, 4 or a dynamic gate count
    let humidityPercent: Int?     // per-module, nil when the firmware does not report it
    let temperatureCelsius: Double?
    let isExternal: Bool
    let slots: [FilamentSlot]
}

struct FilamentSlot: Equatable, Identifiable, Sendable {
    let id: String
    let label: String             // A1, B3, T6, EXT
    let material: String?         // nil / empty → empty slot
    let colorHex: String?
    let remainingPercent: Int?
    let isActive: Bool
    /// Remaining filament weight in grams from the AMS NFC/RFID tag (tray_weight × remain), when known.
    var remainingWeightGrams: Double? = nil

    var isPresent: Bool {
        guard let material else { return false }
        return !material.isEmpty && material != "—"
    }
}

/// One point in a printer's rolling temperature history, drawn by the detail window's graph.
struct TemperatureSample: Equatable, Sendable {
    let time: Date
    let nozzle: Double?
    let bed: Double?
    let chamber: Double?
}

enum NozzlePosition: String, Sendable {
    case single, left, right
}

struct NozzleTelemetry: Equatable, Identifiable, Sendable {
    var id: String { position.rawValue }
    let position: NozzlePosition
    let currentTemperature: Double?
    let targetTemperature: Double?
}

struct AMSSlot: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let material: String
    let colorHex: String
    let remainingPercent: Int?
    let isActive: Bool
    let isExternal: Bool
    /// RFID/NFC remaining weight (grams). Nil for a chipless spool, whose `remainingPercent` is not a
    /// trustworthy reading — used to suppress false "low filament" warnings (issue #27).
    var remainingWeightGrams: Double? = nil
}

extension FilamentGroup {
    /// Flat legacy representation still consumed by notifications, the menu bar and self-tests.
    var legacyAMSSlots: [AMSSlot] {
        slots.map { slot in
            AMSSlot(
                id: slot.id,
                label: slot.label,
                material: slot.isPresent ? (slot.material ?? "—") : "—",
                colorHex: slot.colorHex ?? "8E8E93FF",
                remainingPercent: slot.remainingPercent,
                isActive: slot.isActive,
                isExternal: isExternal,
                remainingWeightGrams: slot.remainingWeightGrams
            )
        }
    }
}

enum PrinterKind: String, Codable, Sendable {
    case bambu
    case klipper
    case prusa
    case snapmaker
    case elegooCC1 = "elegoo_cc1"
    case elegooCC2 = "elegoo_cc2"
    case anycubicKobraS1 = "anycubic_kobra_s1"
}

struct SavedPrinter: Codable, Identifiable, Hashable, Sendable {
    var id: String { serial }
    let serial: String
    var name: String
    var model: String
    var host: String
    var kind: PrinterKind
    /// Moonraker port for Klipper printers (default 7125). Unused for Bambu.
    var port: Int?
    /// Optional Moonraker API key for Klipper printers.
    var apiKey: String?

    init(serial: String, name: String, model: String = "Bambu Lab", host: String,
         kind: PrinterKind = .bambu, port: Int? = nil, apiKey: String? = nil) {
        self.serial = serial
        self.name = name
        self.model = model
        self.host = host
        self.kind = kind
        self.port = port
        self.apiKey = apiKey
    }

    enum CodingKeys: String, CodingKey { case serial, name, model, host, kind, port, apiKey }

    // Custom decoding so printers saved before the Klipper fields existed still load as Bambu.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serial = try container.decode(String.self, forKey: .serial)
        name = try container.decode(String.self, forKey: .name)
        model = (try? container.decode(String.self, forKey: .model)) ?? "Bambu Lab"
        host = try container.decode(String.self, forKey: .host)
        kind = (try? container.decode(PrinterKind.self, forKey: .kind)) ?? .bambu
        port = try? container.decodeIfPresent(Int.self, forKey: .port)
        apiKey = try? container.decodeIfPresent(String.self, forKey: .apiKey)
    }
}

struct DiscoveredPrinter: Identifiable, Hashable, Sendable {
    var id: String { serial }
    let serial: String
    let name: String
    let model: String
    let host: String
    var kind: PrinterKind = .bambu
}
