import Testing
import Foundation
@testable import Gantry

/// Which rolls count as running low (reported 2026-09-18: no low-filament alerts at all with rolls
/// that are not Bambu's tagged ones). Same cases as linux/tests/test_low_filament.py.
@MainActor @Suite struct LowFilamentTests {
    private func slot(_ label: String, material: String? = "PLA", percent: Int? = nil, tagGrams: Double? = nil,
                      active: Bool = false) -> FilamentSlot {
        FilamentSlot(id: label, label: label, material: material, colorHex: "FFFFFF", remainingPercent: percent,
                     isActive: active, remainingWeightGrams: tagGrams)
    }

    private func group(_ slots: [FilamentSlot], external: Bool = false) -> FilamentGroup {
        FilamentGroup(id: UUID().uuidString, sourceType: external ? .external : .ams, displayName: "AMS",
                      declaredCapacity: slots.count, humidityPercent: nil, temperatureCelsius: nil,
                      isExternal: external, slots: slots)
    }

    private func roll(grams: Double) -> PhysicalSpool {
        PhysicalSpool(id: "SP-00007", filamentDefinitionID: UUID(), nominalWeightGrams: 1000, remainingWeightGrams: grams)
    }

    @Test func aTaggedRollAtFifteenPercentIsLowAndAtSixteenIsNot() {
        let groups = [group([slot("A1", percent: 15, tagGrams: 150), slot("A2", percent: 16, tagGrams: 160)])]
        let low = LowFilament.lowSlots(serial: "X1", groups: groups) { _ in nil }
        #expect(low == [LowFilament.Slot(key: "0-0", label: "A1", material: "PLA", amount: "15%")])
    }

    @Test func aChiplessRollWithoutSpoolbaseIsNeverLow() {
        let groups = [group([slot("A1", percent: 0)])]
        #expect(LowFilament.lowSlots(serial: "X1", groups: groups) { _ in nil }.isEmpty)
    }

    @Test func aSpoolbaseRollWarnsByItsGramsEvenWithoutATag() {
        let groups = [group([slot("A1", percent: 0), slot("A2", percent: 0)])]
        let low = LowFilament.lowSlots(serial: "X1", groups: groups) { location in
            location.slot == 0 ? roll(grams: 85.4) : roll(grams: 101)
        }
        #expect(low == [LowFilament.Slot(key: "0-0", label: "A1", material: "PLA", amount: "85 g")])
    }

    @Test func spoolbaseOutranksAFullLookingTag() {
        let groups = [group([slot("A1", percent: 90, tagGrams: 900)])]
        let low = LowFilament.lowSlots(serial: "X1", groups: groups) { _ in roll(grams: 40) }
        #expect(low.map(\.amount) == ["40 g"])
    }

    @Test func theSlotThatWasFeedingIsNamedEvenAfterThePauseClearedIt() {
        let before = [group([slot("A1"), slot("A3", active: true)])]
        let after = [group([slot("A1"), slot("A3")])]
        #expect(LowFilament.feedingSlot(previous: before, current: after)?.label == "A3")
        #expect(LowFilament.feedingSlot(previous: nil, current: after) == nil)
    }
}
