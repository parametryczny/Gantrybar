import Foundation
import Testing
@testable import Gantry

@MainActor @Suite struct SpoolAutoPairTests {
    private func slot(_ material: String, _ color: String, product: String? = nil) -> FilamentSlot {
        var value = FilamentSlot(id: "ams-0-0", label: "A1", material: material, colorHex: color,
                                 remainingPercent: 100, isActive: false)
        value.spoolUID = "ABCDEF0123"
        value.productName = product
        return value
    }

    @Test func thePrinterBrandAndProductNameWinAtTheSameColour() {
        let other = Filament(brand: "Devil Design", name: "PETG", type: "PETG", colorName: "Black", colorHex: "000000")
        let bambu = Filament(brand: "Bambu Lab", name: "PETG Basic", type: "PETG", colorName: "Black", colorHex: "000000")
        let pla = Filament(brand: "Bambu Lab", name: "PLA Basic", type: "PLA", colorName: "Black", colorHex: "000000")
        let best = SpoolAutoPair.bestProduct(for: slot("PETG", "000000FF", product: "PETG Basic"), among: [other, bambu, pla])
        #expect(best?.id == bambu.id)
    }

    @Test func aDifferentColourIsNotTheSameProduct() {
        let red = Filament(brand: "Bambu Lab", name: "PETG Basic", type: "PETG", colorName: "Red", colorHex: "FF0000")
        #expect(SpoolAutoPair.bestProduct(for: slot("PETG", "0000FFFF"), among: [red]) == nil)
    }

    @Test func aTagOfZerosIsNoTag() {
        #expect(BambuStatusParser.tagUID(["tray_uuid": "00000000000000000000000000000000"]) == nil)
        #expect(BambuStatusParser.tagUID(["tray_uuid": "a1b2c3"]) == "A1B2C3")
        #expect(BambuStatusParser.tagUID([:]) == nil)
    }
}
