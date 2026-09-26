import Foundation
import Testing
@testable import Gantry

@Suite struct PrintCostTests {
    @Test func splitsFilamentEnergyAndMachineTime() {
        var settings = PrintCostSettings()
        settings.filamentPerKg = 80; settings.materialPerKg = ["PETG": 100]
        settings.electricityPerKWh = 1.2; settings.printerWatts = 200; settings.machinePerHour = 2
        let cost = PrintCost.compute(durationSeconds: 3 * 3600,
                                     uses: [.init(grams: 250, material: "pla"), .init(grams: 100, material: "PETG")],
                                     serial: "X", settings: settings)
        #expect(abs((cost.filament ?? 0) - 30) < 0.0001)     // 0.25 kg × 80 + 0.1 kg × 100
        #expect(abs(cost.kWh - 0.6) < 0.0001)                // 3 h × 200 W
        #expect(abs(cost.energy - 0.72) < 0.0001)
        #expect(abs(cost.machine - 6) < 0.0001)
        #expect(abs(cost.total - 36.72) < 0.0001)
        #expect(cost.grams == 350)
    }

    @Test func unknownFilamentStaysUnknown() {
        let cost = PrintCost.compute(durationSeconds: 3600, uses: [], serial: "X", settings: PrintCostSettings())
        #expect(cost.filament == nil)
        #expect(cost.grams == nil)
        #expect(cost.total == cost.energy + cost.machine)
    }

    @Test func perPrinterPowerOverridesDefault() {
        var settings = PrintCostSettings(); settings.printerWatts = 100; settings.watts = ["BIG": 400]
        #expect(PrintCost.compute(durationSeconds: 3600, uses: [], serial: "BIG", settings: settings).kWh == 0.4)
        #expect(PrintCost.compute(durationSeconds: 3600, uses: [], serial: "SMALL", settings: settings).kWh == 0.1)
    }

    @Test func partialStoredSettingsKeepDefaults() throws {
        let decoded = try JSONDecoder().decode(PrintCostSettings.self, from: Data(#"{"filamentPerKg": 95}"#.utf8))
        #expect(decoded.filamentPerKg == 95)
        #expect(decoded.electricityPerKWh == PrintCostSettings().electricityPerKWh)
        #expect(decoded.currency == PrintCostSettings().currency)
    }

    @Test func rollPriceWinsOverMaterialPrice() {
        var settings = PrintCostSettings(); settings.filamentPerKg = 80
        let roll = PhysicalSpool(id: "SP-1", filamentDefinitionID: UUID(), nominalWeightGrams: 750, price: 90)
        #expect(roll.pricePerKg == 120)
        let cost = PrintCost.compute(durationSeconds: 0,
                                     uses: [.init(grams: 100, material: "PLA", pricePerKg: roll.pricePerKg),
                                            .init(grams: 100, material: "PLA")],
                                     serial: "X", settings: settings)
        #expect(abs((cost.filament ?? 0) - 20) < 0.0001)   // 0.1 × 120 + 0.1 × 80
    }

    @Test func filamentWithoutNewFieldsStillDecodes() throws {
        let old = #"{"id":"7F0C8C1E-3C77-4A60-9B7E-0E1B1E2B3C4D","brand":"Polymaker","name":"PolyTerra PLA","type":"PLA","colorName":"Cotton White","colorHex":"EDE8E0","manufacturerCode":"PA04001","spoolCount":6,"notes":"","updatedAt":0}"#
        var filament = try JSONDecoder().decode(Filament.self, from: Data(old.utf8))
        #expect(filament.ean == nil && filament.pricePerRoll == nil)
        filament.ean = "5901234123457"; filament.pricePerRoll = 89.9
        let back = try JSONDecoder().decode(Filament.self, from: JSONEncoder().encode(filament))
        #expect(back.ean == "5901234123457" && back.pricePerRoll == 89.9)
        let fromLinux = old.replacingOccurrences(of: #""notes":"""#, with: #""ean":null,"pricePerRoll":null,"notes":"""#)
        #expect(try JSONDecoder().decode(Filament.self, from: Data(fromLinux.utf8)).pricePerRoll == nil)
    }

    @Test func eanCheckDigit() {
        #expect(EANCode.isPlausible("5901234123457"))      // EAN-13
        #expect(!EANCode.isPlausible("5901234123458"))
        #expect(EANCode.isPlausible("96385074"))           // EAN-8
        #expect(EANCode.isPlausible("036000291452"))       // UPC-A
        #expect(!EANCode.isPlausible("12345"))
        #expect(EANCode.isPlausible("BL-PLA-1001"))        // not an EAN, left alone
    }

    @Test func parsesMaterialPricesWithDecimalComma() {
        #expect(PrintCostSettings.parseMaterialPrices("petg=90, ASA = 119,50; TPU=140\nbroken") ==
                ["PETG": 90, "ASA": 119.5, "TPU": 140])
    }
}
