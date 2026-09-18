import Foundation

/// Which loaded rolls are running low, from the two sources Gantry can trust: a roll assigned in
/// Spoolbase, whose grams Gantry counts down itself, and otherwise a Bambu roll with an RFID/NFC tag,
/// whose percentage comes from the printer. A chipless roll without a Spoolbase assignment has no
/// reliable level and is never reported (issue #27). The same rules on Windows and Linux.
@MainActor enum LowFilament {
    /// A tagged roll at or below this share of its weight is low.
    static let percentThreshold = 15
    /// A Spoolbase roll at or below this many grams is low.
    static let gramsThreshold: Double = 100
    /// Bambu print stage 6: paused because the filament ran out.
    static let runoutStage = 6

    struct Slot: Equatable {
        /// Stable within one printer: unit index and slot index.
        let key: String
        let label: String
        let material: String
        /// "12%" for a tagged roll, "85 g" for a Spoolbase roll.
        let amount: String
    }

    static func lowSlots(serial: String, groups: [FilamentGroup],
                         assignedSpool: (SpoolLocation) -> PhysicalSpool?) -> [Slot] {
        var result: [Slot] = []
        for (groupIndex, group) in groups.enumerated() {
            for (slotIndex, slot) in group.slots.enumerated() {
                let key = "\(groupIndex)-\(slotIndex)"
                let location = FilamentConsumption.slotLocation(serial: serial, groups: groups,
                                                                group: groupIndex, slot: slotIndex)
                // Spoolbase first: an assignment is the user's own record of the roll and outranks the tag.
                if let spool = assignedSpool(location) {
                    guard spool.remainingWeightGrams <= gramsThreshold else { continue }
                    result.append(Slot(key: key, label: slot.label,
                                       material: slot.isPresent ? (slot.material ?? spool.id) : spool.id,
                                       amount: "\(Int(spool.remainingWeightGrams.rounded())) g"))
                    continue
                }
                guard slot.isPresent, slot.remainingWeightGrams != nil,
                      let percent = slot.remainingPercent, percent <= percentThreshold else { continue }
                result.append(Slot(key: key, label: slot.label, material: slot.material ?? "",
                                   amount: "\(percent)%"))
            }
        }
        return result
    }

    /// The roll that was feeding when the printer stopped: the active slot of the last report that had
    /// one, because the report that carries the pause may already have cleared it.
    static func feedingSlot(previous: [FilamentGroup]?, current: [FilamentGroup]) -> FilamentSlot? {
        let active = { (groups: [FilamentGroup]) in groups.lazy.flatMap(\.slots).first(where: \.isActive) }
        return active(current) ?? previous.flatMap(active)
    }
}
