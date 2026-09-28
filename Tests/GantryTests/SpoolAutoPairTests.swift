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

    /// Tag, do którego nic w bazie nie pasuje, staje się pytaniem, a nie ciszą.
    ///
    /// Wcześniej `bestProduct` zwracało nil i pętla po prostu szła dalej, więc rolka, której nie było
    /// w Spoolbase, nigdy się w nim nie pojawiała i nie miała czego obciążyć kosztami.
    @Test func anUnknownTagCarriesEnoughToFillTheAddWindow() {
        var value = slot("PETG", "1F8A3CFF", product: "PETG Basic")
        value.nominalGrams = 1000
        value.remainingWeightGrams = 740
        let offer = SpoolAutoPair.Offer(tagUID: value.spoolUID!, printerSerial: "K",
                                        location: SpoolLocation(printerSerial: "K", feeder: .ams, amsIndex: 0, slot: 0),
                                        slotName: "AMS A A1", material: value.material!,
                                        productName: value.productName, colorHex: value.colorHex!,
                                        nominalGrams: value.nominalGrams!,
                                        remainingGrams: value.remainingWeightGrams)
        let draft = offer.draft
        #expect(draft.brand == "Bambu Lab", "an RFID tag only comes on Bambu filament")
        #expect(draft.name == "PETG Basic")
        #expect(draft.type == "PETG")
        #expect(draft.colorHex == "1F8A3C", "the window wants RRGGBB, the AMS sends RGBA")
        #expect(SpoolOfferPrompt.describe(offer).contains("740"), "the line must say what is left on the roll")
    }

    /// Nazwa koloru bierze się z katalogu, bo tag niesie tylko RGBA.
    ///
    /// Bez tego pole „Nazwa koloru" było puste przy każdej rolce i trzeba je było wpisywać ręcznie,
    /// a wpis bez nazwy koloru jest dla człowieka nie do odróżnienia od innego w tym samym materiale.
    @Test func theColourNameComesFromTheCatalogue() {
        let catalog = [
            CatalogFilament(id: "db-1", brand: "Bambu Lab", name: "Matte", type: "PLA",
                            colorName: "Dark Green", colorHex: "68724D", manufacturerCode: "#68724D"),
            CatalogFilament(id: "db-2", brand: "Bambu Lab", name: "Matte", type: "PLA",
                            colorName: "Terracotta", colorHex: "B15533", manufacturerCode: "#B15533"),
            CatalogFilament(id: "db-3", brand: "eSUN", name: "PLA-Matte", type: "PLA",
                            colorName: "Olive", colorHex: "68724D", manufacturerCode: "")
        ]
        #expect(SpoolAutoPair.Offer.catalogColor(brand: "Bambu Lab", type: "PLA", hex: "68724D",
                                           among: catalog)?.colorName == "Dark Green")
        // O jeden ton obok to wciąż ten sam kolor; o pół palety dalej już nie.
        #expect(SpoolAutoPair.Offer.catalogColor(brand: "Bambu Lab", type: "PLA", hex: "69734E",
                                           among: catalog)?.colorName == "Dark Green")
        #expect(SpoolAutoPair.Offer.catalogColor(brand: "Bambu Lab", type: "PLA", hex: "3366FF",
                                           among: catalog) == nil)
        // Marka i materiał muszą się zgadzać, inaczej nazwa przyszłaby z cudzej szpuli.
        #expect(SpoolAutoPair.Offer.catalogColor(brand: "Bambu Lab", type: "PETG", hex: "68724D",
                                           among: catalog) == nil)
    }

    /// Przyjęta propozycja zakłada rolkę z gramaturą z tagu i wkłada ją do tego slotu.
    @Test func acceptingAnOfferPutsATaggedRollInTheSlot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let location = SpoolLocation(printerSerial: "K", feeder: .ams, amsIndex: 0, slot: 0)
        let offer = SpoolAutoPair.Offer(tagUID: "A1B2C3", printerSerial: "K", location: location,
                                        slotName: "AMS A A1", material: "PETG", productName: "PETG Basic",
                                        colorHex: "1F8A3CFF", nominalGrams: 1000, remainingGrams: 740)
        let product = Filament(brand: "Bambu Lab", name: "PETG Basic", type: "PETG",
                               colorName: "Zielony", colorHex: "1F8A3C")
        // Własny magazyn, nie ten użytkownika: test nie ma prawa dopisywać rolek do czyjejś bazy.
        let store = PhysicalSpoolStore(spoolsURL: dir.appendingPathComponent("spools.json"),
                                       usageURL: dir.appendingPathComponent("usage.json"))
        let roll = SpoolAutoPair.accept(offer, product: product, store: store)
        #expect(roll?.tagUID == "A1B2C3")
        #expect(roll?.nominalWeightGrams == 1000)
        #expect(roll?.remainingWeightGrams == 740)
        #expect(store.spool(at: location)?.id == roll?.id)
    }

    @Test func aTagOfZerosIsNoTag() {
        #expect(BambuStatusParser.tagUID(["tray_uuid": "00000000000000000000000000000000"]) == nil)
        #expect(BambuStatusParser.tagUID(["tray_uuid": "a1b2c3"]) == "A1B2C3")
        #expect(BambuStatusParser.tagUID([:]) == nil)
    }
}
