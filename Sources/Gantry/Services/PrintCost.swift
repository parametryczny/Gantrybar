import Foundation

/// The user's own prices for turning a print into money: filament per kilogram (optionally per
/// material), electricity per kWh with each printer's average draw, and machine time per hour
/// (wear, depreciation). Stored locally as one JSON value; every field has a default so an older or
/// partial value still decodes.
struct PrintCostSettings: Codable, Equatable, Sendable {
    var currency = "PLN"
    var filamentPerKg = 80.0
    /// Upper-cased material family ("PLA", "PETG") → price per kg; missing ones use `filamentPerKg`.
    var materialPerKg: [String: Double] = [:]
    var electricityPerKWh = 1.0
    var printerWatts = 150.0
    /// Printer serial → average power in watts; missing ones use `printerWatts`.
    var watts: [String: Double] = [:]
    var machinePerHour = 0.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrintCostSettings()
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? d.currency
        filamentPerKg = (try? c.decodeIfPresent(Double.self, forKey: .filamentPerKg)) ?? d.filamentPerKg
        materialPerKg = (try? c.decodeIfPresent([String: Double].self, forKey: .materialPerKg)) ?? d.materialPerKg
        electricityPerKWh = (try? c.decodeIfPresent(Double.self, forKey: .electricityPerKWh)) ?? d.electricityPerKWh
        printerWatts = (try? c.decodeIfPresent(Double.self, forKey: .printerWatts)) ?? d.printerWatts
        watts = (try? c.decodeIfPresent([String: Double].self, forKey: .watts)) ?? d.watts
        machinePerHour = (try? c.decodeIfPresent(Double.self, forKey: .machinePerHour)) ?? d.machinePerHour
    }

    /// "PETG=90, ASA=119,50; TPU = 140" → ["PETG": 90, "ASA": 119.5, "TPU": 140].
    static func parseMaterialPrices(_ text: String) -> [String: Double] {
        guard let pattern = try? NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9+\-]*)\s*=\s*([0-9]+(?:[.,][0-9]+)?)"#) else { return [:] }
        var result: [String: Double] = [:]
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text),
                  let price = Double(text[value].replacingOccurrences(of: ",", with: ".")) else { continue }
            result[text[key].uppercased()] = price
        }
        return result
    }

    func pricePerKg(_ material: String?) -> Double {
        let key = (material ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        return materialPerKg[key] ?? filamentPerKg
    }

    func power(for serial: String) -> Double { watts[serial] ?? printerWatts }

    private static let key = "print-cost-settings-v1"

    static var current: PrintCostSettings {
        get {
            guard let data = BambuDefaults.shared.data(forKey: key),
                  let value = try? JSONDecoder().decode(PrintCostSettings.self, from: data) else { return PrintCostSettings() }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { BambuDefaults.shared.set(data, forKey: key) }
        }
    }
}

/// One print's cost, split so the user can see where the money went.
struct PrintCost: Equatable, Sendable {
    struct Use: Equatable, Sendable {
        var grams: Double
        var material: String?
    }

    /// Nil when Gantry does not know how much filament the print used (no Spoolbase roll assigned).
    var filament: Double?
    var grams: Double?
    var energy: Double
    var machine: Double
    var kWh: Double

    var total: Double { (filament ?? 0) + energy + machine }

    static func compute(durationSeconds: Double, uses: [Use], serial: String,
                        settings: PrintCostSettings) -> PrintCost {
        let hours = max(0, durationSeconds) / 3600
        let kWh = hours * max(0, settings.power(for: serial)) / 1000
        let grams = uses.isEmpty ? nil : uses.reduce(0) { $0 + max(0, $1.grams) }
        let filament = uses.isEmpty ? nil
            : uses.reduce(0) { $0 + max(0, $1.grams) / 1000 * max(0, settings.pricePerKg($1.material)) }
        return PrintCost(filament: filament, grams: grams,
                         energy: kWh * max(0, settings.electricityPerKWh),
                         machine: hours * max(0, settings.machinePerHour), kWh: kWh)
    }

    /// Filament the print used, from Spoolbase's per-print usage records: the records written for this
    /// printer when the print finished (a short grace after the end covers a late FINISH packet).
    @MainActor
    static func uses(serial: String, startedAt: Date, endedAt: Date) -> [Use] {
        let spools = SpoolbaseShared.spools
        let filaments = SpoolbaseShared.filaments.filaments
        let from = startedAt.addingTimeInterval(-60), to = endedAt.addingTimeInterval(600)
        return spools.usageEvents
            .filter { $0.printerSerial == serial && $0.timestamp >= from && $0.timestamp <= to }
            .map { event in
                let definition = spools.spools.first { $0.id == event.spoolID }?.filamentDefinitionID
                let material = definition.flatMap { id in filaments.first { $0.id == id }?.type }
                return Use(grams: event.consumedGrams, material: material)
            }
    }
}
