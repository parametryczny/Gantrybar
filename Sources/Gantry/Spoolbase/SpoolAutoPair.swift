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
    /// Pairs every tagged, unpaired roll in these groups and returns one line per pairing, for the card.
    static func pair(serial: String, groups: [FilamentGroup]) -> [String] {
        let settings = AppSettings.shared
        guard settings.spoolbaseEnabled, settings.spoolAutoPair else { return [] }
        let store = SpoolbaseShared.spools
        let filaments = SpoolbaseShared.filaments.filaments
        var notices: [String] = []
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
                guard let product = bestProduct(for: slot, among: filaments) else { continue }
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
        return notices
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
