import Foundation

/// Pairs a Bambu RFID roll loaded in an AMS with its roll in Spoolbase, so what the print used is
/// charged to that roll and priced with what you paid for it, not with the slicer's price.
///
/// A roll with an RFID tag carries its own id. The first time a tag shows up, Gantry looks for the
/// product in Spoolbase (same material, closest colour, Bambu Lab first, the tag's product name
/// preferred) and takes a roll of it from storage, or adds one priced like that product. The tag is
/// kept on the roll, so the next time that roll goes into any slot of any printer it is recognised
/// straight away. A roll you assigned by hand to a slot is never replaced, and rolls without a tag
/// (third-party filament) are left for you to assign.
@MainActor
enum SpoolAutoPair {
    /// Rolka z tagiem, której w Spoolbase nie ma, razem ze wszystkim, co o niej powiedział AMS.
    ///
    /// Tag Bambu niesie materiał (`tray_type`), nazwę produktu (`tray_sub_brands`), kolor
    /// (`tray_color`) i pełną wagę szpuli (`tray_weight`). To wystarczy, żeby wypełnić okno dodawania
    /// za użytkownika: zostaje mu nazwa koloru i cena. Wcześniej taki tag po prostu wypadał z pętli i
    /// nie działo się nic, więc rolka, której nie było w bazie, nigdy się w niej nie pojawiała.
    struct Offer: Equatable, Identifiable {
        var id: String { tagUID }
        var tagUID: String
        var printerSerial: String
        var location: SpoolLocation
        var slotName: String
        var material: String
        var productName: String?
        var colorHex: String
        var nominalGrams: Double
        var remainingGrams: Double?

        /// Wpis do bazy filamentów, jaki proponuje AMS. Marka to Bambu Lab, bo tag RFID ma tylko
        /// filament Bambu; resztę użytkownik i tak zobaczy w oknie i może poprawić.
        ///
        /// Nazwy koloru tag nie niesie, tylko RGBA, więc bierze się ją z katalogu: Bambu ma w nim
        /// wszystkie swoje kolory z ich własnymi nazwami, a `68724D` to dokładnie „Dark Green".
        /// Puste pole trzeba było wypełniać ręcznie przy każdej rolce, a bez nazwy wpis jest
        /// nierozpoznawalny dla człowieka, choćby kolor się zgadzał.
        var draft: Filament {
            let hex = String(colorHex.prefix(6)).uppercased()
            let named = Self.catalogColor(brand: "Bambu Lab", type: material, hex: hex)
            var value = Filament(brand: "Bambu Lab",
                                 name: productName ?? material,
                                 type: material,
                                 colorName: named?.colorName ?? "",
                                 colorHex: hex,
                                 manufacturerCode: named?.manufacturerCode ?? "")
            // Ten sam identyfikator katalogowy co wpis dodany ręcznie z katalogu, ale tylko gdy zgadza
            // się też nazwa serii: inaczej „PLA Matte" z tagu scaliłoby się z „Matte" z katalogu.
            if let named, named.name.caseInsensitiveCompare(value.name) == .orderedSame {
                value.catalogID = named.id
            }
            return value
        }

        /// Pozycja katalogu w tym samym materiale i kolorze. Najpierw dokładne trafienie w kod koloru,
        /// potem najbliższa w promieniu, w którym dwa kolory to jeszcze ten sam kolor, a nie sąsiedni.
        static func catalogColor(brand: String, type: String, hex: String,
                                 among catalog: [CatalogFilament] = CatalogFile.filaments) -> CatalogFilament? {
            let candidates = catalog.filter {
                $0.brand.caseInsensitiveCompare(brand) == .orderedSame
                    && $0.type.caseInsensitiveCompare(type) == .orderedSame
                    && !$0.colorName.isEmpty
            }
            if let exact = candidates.first(where: { $0.colorHex.caseInsensitiveCompare(hex) == .orderedSame }) {
                return exact
            }
            return candidates
                .compactMap { item -> (CatalogFilament, Double)? in
                    guard let distance = FarmRules.colorDistance(item.colorHex, hex), distance <= 12 else { return nil }
                    return (item, distance)
                }
                .min { $0.1 < $1.1 }?.0
        }
    }

    /// Pairs every tagged, unpaired roll in these groups and returns one line per pairing, for the card.
    static func pair(serial: String, groups: [FilamentGroup]) -> [String] {
        result(serial: serial, groups: groups).notices
    }

    /// The same pass, with the tags it could not place: same material and colour as nothing in
    /// Spoolbase, so there is no product to take a roll of.
    static func result(serial: String, groups: [FilamentGroup]) -> (notices: [String], offers: [Offer]) {
        let settings = AppSettings.shared
        guard settings.spoolbaseEnabled, settings.spoolAutoPair else { return ([], []) }
        let store = SpoolbaseShared.spools
        let filaments = SpoolbaseShared.filaments.filaments
        var notices: [String] = []
        var offers: [Offer] = []
        for (groupIndex, group) in groups.enumerated() {
            for (slotIndex, slot) in group.slots.enumerated() {
                guard slot.isPresent, let uid = slot.spoolUID else { continue }
                let location = SpoolLocation(printerSerial: serial, feeder: group.isExternal ? .ext : .ams,
                                             amsIndex: groupIndex, slot: slotIndex)
                let current = store.spool(at: location)
                if current?.tagUID == uid { continue }
                // A roll assigned by hand stays: only an empty slot or one holding another tagged roll
                // (taken out and replaced) is paired again.
                if let current, current.tagUID == nil { continue }
                let slotName = group.isExternal ? group.displayName : "\(group.displayName) \(slot.label)"

                if let known = store.spools.first(where: { $0.tagUID == uid }) {
                    store.assign(spoolID: known.id, to: location)
                    notices.append(settings.t("{0} recognised in {1}", known.id, slotName))
                    continue
                }
                guard let product = bestProduct(for: slot, among: filaments) else {
                    // Nie ma w bazie niczego w tym materiale i kolorze. Nie zgadujemy i nie tworzymy
                    // produktu po cichu: pytamy, bo tylko użytkownik wie, czy to nowa rolka w magazynie.
                    if let material = slot.material?.trimmingCharacters(in: .whitespaces), !material.isEmpty {
                        offers.append(Offer(tagUID: uid, printerSerial: serial, location: location,
                                            slotName: slotName, material: material,
                                            productName: slot.productName,
                                            colorHex: slot.colorHex ?? "8E8E93FF",
                                            nominalGrams: slot.nominalGrams ?? 1000,
                                            remainingGrams: slot.remainingWeightGrams))
                    }
                    continue
                }
                let waiting = store.spools(forDefinition: product.id)
                    .filter { $0.location.isStorage && $0.tagUID == nil && $0.status != .empty && $0.status != .archived }
                    .sorted { a, b in
                        // An opened roll first, then the oldest: the one most likely to be the roll in hand.
                        if (a.openedAt != nil) != (b.openedAt != nil) { return a.openedAt != nil }
                        return a.createdAt < b.createdAt
                    }
                var roll: PhysicalSpool
                if let first = waiting.first {
                    roll = first
                } else {
                    let weight = slot.nominalGrams ?? 1000
                    guard let created = store.createRolls(definitionID: product.id, count: 1, weight: weight,
                                                          remaining: slot.remainingWeightGrams,
                                                          price: product.pricePerRoll ?? store.lastPrice(definitionID: product.id)).first
                    else { continue }
                    roll = created
                }
                roll.tagUID = uid
                store.update(roll)
                store.assign(spoolID: roll.id, to: location)
                notices.append(settings.t("{0} ({1}) paired with {2}", roll.id, product.brand + " " + product.name, slotName))
            }
        }
        return (notices, offers)
    }

    /// Zakłada rolkę pod właśnie dodany produkt, zapisuje na niej tag i wkłada ją do slotu.
    ///
    /// Waga i stan biorą się z tagu, więc rolka od razu zna swoje gramy, a cena z produktu, jeśli
    /// użytkownik ją wpisał.
    @discardableResult
    static func accept(_ offer: Offer, product: Filament,
                       store: PhysicalSpoolStore = SpoolbaseShared.spools) -> PhysicalSpool? {
        guard var roll = store.createRolls(definitionID: product.id, count: 1,
                                           weight: offer.nominalGrams,
                                           remaining: offer.remainingGrams,
                                           price: product.pricePerRoll).first else { return nil }
        roll.tagUID = offer.tagUID
        store.update(roll)
        store.assign(spoolID: roll.id, to: offer.location)
        return roll
    }

    /// The Spoolbase product a tagged roll most likely is: same material, colour within reach, then
    /// Bambu Lab and a name that contains the tag's product name.
    static func bestProduct(for slot: FilamentSlot, among filaments: [Filament]) -> Filament? {
        guard let material = slot.material?.trimmingCharacters(in: .whitespaces), !material.isEmpty else { return nil }
        let wanted = (slot.productName ?? "").uppercased()
        let scored = filaments.compactMap { filament -> (Filament, Double)? in
            guard filament.type.caseInsensitiveCompare(material) == .orderedSame else { return nil }
            guard let distance = FarmRules.colorDistance(filament.colorHex, slot.colorHex ?? ""), distance <= 60 else { return nil }
            var score = distance
            if !filament.brand.localizedCaseInsensitiveContains("bambu") { score += 100 }
            if !wanted.isEmpty, !(filament.brand + " " + filament.name).uppercased().contains(wanted) { score += 40 }
            return (filament, score)
        }
        return scored.min { $0.1 < $1.1 }?.0
    }
}
