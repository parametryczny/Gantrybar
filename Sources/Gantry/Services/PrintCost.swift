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

    // MARK: Selling

    /// How the seller is set up, which decides VAT and the default tax.
    enum Business: String, Codable, CaseIterable, Sendable {
        /// Działalność nierejestrowana: no VAT, income taxed on the PIT scale.
        case unregistered
        /// A registered business that is VAT-exempt.
        case company
        /// A registered business charging VAT.
        case companyVAT
    }

    var business: Business = .unregistered
    /// Income tax in percent. Taken from the profit, or from the revenue when `taxOnRevenue` is on
    /// (the Polish lump-sum "ryczałt").
    var incomeTaxPercent = 12.0
    var taxOnRevenue = false
    var vatPercent = 23.0
    /// Mark-up on everything it costs to make and ship one print.
    var marginPercent = 30.0
    /// A marketplace's cut of the gross price (Allegro, Etsy).
    var platformFeePercent = 0.0
    /// Hands-on time per print (taking it off the plate, cleaning, packing) and what that hour is worth.
    var laborPerHour = 0.0
    var laborMinutes = 10.0
    /// Box, filler and label per order.
    var packaging = 0.0
    /// Extra material and machine time set aside for prints that fail, in percent.
    var failurePercent = 5.0

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
        business = (try? c.decodeIfPresent(Business.self, forKey: .business)) ?? d.business
        incomeTaxPercent = (try? c.decodeIfPresent(Double.self, forKey: .incomeTaxPercent)) ?? d.incomeTaxPercent
        taxOnRevenue = (try? c.decodeIfPresent(Bool.self, forKey: .taxOnRevenue)) ?? d.taxOnRevenue
        vatPercent = (try? c.decodeIfPresent(Double.self, forKey: .vatPercent)) ?? d.vatPercent
        marginPercent = (try? c.decodeIfPresent(Double.self, forKey: .marginPercent)) ?? d.marginPercent
        platformFeePercent = (try? c.decodeIfPresent(Double.self, forKey: .platformFeePercent)) ?? d.platformFeePercent
        laborPerHour = (try? c.decodeIfPresent(Double.self, forKey: .laborPerHour)) ?? d.laborPerHour
        laborMinutes = (try? c.decodeIfPresent(Double.self, forKey: .laborMinutes)) ?? d.laborMinutes
        packaging = (try? c.decodeIfPresent(Double.self, forKey: .packaging)) ?? d.packaging
        failurePercent = (try? c.decodeIfPresent(Double.self, forKey: .failurePercent)) ?? d.failurePercent
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
        /// From the price entered for the roll that was used; wins over the material price list.
        var pricePerKg: Double? = nil
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
            : uses.reduce(0) { $0 + max(0, $1.grams) / 1000 * max(0, $1.pricePerKg ?? settings.pricePerKg($1.material)) }
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
                let spool = spools.spools.first { $0.id == event.spoolID }
                let definition = spool.flatMap { s in filaments.first { $0.id == s.filamentDefinitionID } }
                // The roll's own price first, then the product's price per roll over that roll's size.
                let productPerKg = definition?.pricePerRoll.flatMap { price -> Double? in
                    guard let full = spool?.nominalWeightGrams, full > 0 else { return nil }
                    return price / full * 1000
                }
                return Use(grams: event.consumedGrams, material: definition?.type,
                           pricePerKg: spool?.pricePerKg ?? productPerKg)
            }
    }
}

/// What a print should sell for, built up from what it cost.
///
/// Costs first: the print itself (filament, electricity, machine time), an allowance for prints that
/// fail, the hands-on work and the packaging. The mark-up is the profit wanted on top of those, after
/// tax. The price is then solved so that, once the marketplace has taken its cut and the tax office
/// its share, exactly that profit is left; VAT, when charged, goes on top.
///
///     income tax on profit:   net = (costs + profit / (1 − tax)) / (1 − fee)
///     tax on revenue (ryczałt): net = (costs + profit) / (1 − fee − tax)
///     gross = net × (1 + VAT)
///
/// The marketplace fee is charged on the gross price, which is how Allegro and Etsy bill it.
/// An estimate for pricing, not tax advice.
struct SaleQuote: Equatable, Sendable {
    var print: Double
    var failures: Double
    var labor: Double
    var packaging: Double
    var costs: Double { print + failures + labor + packaging }
    var profit: Double
    var fee: Double
    var tax: Double
    var vat: Double
    /// Price without VAT.
    var net: Double
    /// What the customer pays.
    var gross: Double
    /// False when the print's filament use is unknown, so the price leaves the material out.
    var complete: Bool

    static func compute(cost: PrintCost, settings s: PrintCostSettings) -> SaleQuote {
        let print = cost.total
        let failures = print * max(0, s.failurePercent) / 100
        let labor = max(0, s.laborPerHour) * max(0, s.laborMinutes) / 60
        let packaging = max(0, s.packaging)
        let costs = print + failures + labor + packaging
        let profit = costs * max(0, s.marginPercent) / 100
        let vatRate = s.business == .companyVAT ? max(0, s.vatPercent) / 100 : 0
        let taxRate = min(0.9, max(0, s.incomeTaxPercent) / 100)
        // The fee is a share of the gross price; as a share of the net it is that times (1 + VAT).
        let feeRate = min(0.9, max(0, s.platformFeePercent) / 100)
        let net: Double
        if s.taxOnRevenue {
            net = (costs + profit) / max(0.05, 1 - feeRate - taxRate)
        } else {
            net = (costs + profit / max(0.05, 1 - taxRate)) / max(0.05, 1 - feeRate)
        }
        let gross = net * (1 + vatRate)
        let fee = gross * feeRate / (1 + vatRate)
        let tax = s.taxOnRevenue ? net * taxRate : max(0, net - fee - costs) * taxRate
        return SaleQuote(print: print, failures: failures, labor: labor, packaging: packaging,
                         profit: profit, fee: fee, tax: tax, vat: gross - net, net: net, gross: gross,
                         complete: cost.filament != nil)
    }
}
