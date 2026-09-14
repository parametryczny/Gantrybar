import Testing
import Foundation
@testable import Gantry

@Suite struct PrintJobSessionTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    @Test func twoPrintsOfOneFileWithinAnHourAreTwoJobs() {
        var sessions = PrintJobSessions()
        _ = sessions.observe(serial: "X1", previous: .idle, state: .printing, jobName: "cube", now: at(0))
        let first = sessions.observe(serial: "X1", previous: .printing, state: .finished, jobName: "cube", now: at(10))
        _ = sessions.observe(serial: "X1", previous: .finished, state: .printing, jobName: "cube", now: at(15))
        let second = sessions.observe(serial: "X1", previous: .printing, state: .finished, jobName: "cube", now: at(25))
        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
    }

    @Test func aFinishSeenAgainAfterARestartDaysLaterKeepsItsID() throws {
        var sessions = PrintJobSessions()
        _ = sessions.observe(serial: "X1", previous: .idle, state: .printing, jobName: "cube", now: at(0))
        let first = sessions.observe(serial: "X1", previous: .printing, state: .finished, jobName: "cube", now: at(10))
        var restored = try JSONDecoder().decode(PrintJobSessions.self, from: JSONEncoder().encode(sessions))
        let again = restored.observe(serial: "X1", previous: .offline, state: .finished, jobName: "cube", now: at(3 * 24 * 60))
        #expect(again == first)
    }

    @Test func pausesReconnectsAndRepeatedPacketsKeepOneSession() {
        var sessions = PrintJobSessions()
        _ = sessions.observe(serial: "X1", previous: .idle, state: .printing, jobName: "cube", now: at(0))
        _ = sessions.observe(serial: "X1", previous: .printing, state: .paused, jobName: "cube", now: at(5))
        _ = sessions.observe(serial: "X1", previous: .paused, state: .offline, jobName: "cube", now: at(6))
        _ = sessions.observe(serial: "X1", previous: .offline, state: .printing, jobName: "cube", now: at(7))
        let id = sessions.observe(serial: "X1", previous: .printing, state: .finished, jobName: "cube", now: at(30))
        #expect(id == "X1|cube|\(Int(at(0).timeIntervalSince1970))")
        #expect(sessions.observe(serial: "X1", previous: .finished, state: .finished, jobName: "cube", now: at(31)) == nil)
    }
}

@MainActor @Suite struct SpoolSlotChoiceTests {
    private func slot(_ id: String, material: String? = "PLA", color: String? = "FFFFFF", active: Bool = false) -> FilamentSlot {
        FilamentSlot(id: id, label: id, material: material, colorHex: color, remainingPercent: nil, isActive: active)
    }

    private func group(_ slots: [FilamentSlot]) -> FilamentGroup {
        FilamentGroup(id: UUID().uuidString, sourceType: .ams, displayName: "AMS", declaredCapacity: slots.count,
                      humidityPercent: nil, temperatureCelsius: nil, isExternal: false, slots: slots)
    }

    @Test func theActiveSlotWinsEvenInASecondUnit() {
        let groups = [group([slot("A1")]), group([slot("B1", active: true)])]
        let chosen = FilamentConsumption.loadedSlot(serial: "K1", groups: groups, hasSpool: { _ in true })
        #expect(chosen?.location.amsIndex == 1)
        #expect(chosen?.location.slot == 0)
    }

    @Test func twoLoadedRollsWithNothingActiveAreNotGuessed() {
        let groups = [group([slot("A1"), slot("A2")])]
        #expect(FilamentConsumption.loadedSlot(serial: "K1", groups: groups, hasSpool: { _ in true }) == nil)
    }

    @Test func aLoneLoadedRollIsUsed() {
        let groups = [group([slot("A1"), slot("A2", material: nil)])]
        #expect(FilamentConsumption.loadedSlot(serial: "K1", groups: groups, hasSpool: { _ in true })?.location.slot == 0)
    }

    @Test func bambuChargesTheRollThatWasAssignedWhenThePrintFinished() {
        let groups = [group([slot("A1", color: "E89CC6FF"), slot("A2", color: "111111FF")])]
        let pink = FilamentConsumption.slotLocation(serial: "X1", groups: groups, group: 0, slot: 0)
        let charges = FilamentConsumption.bambuCharges(
            serial: "X1", groups: groups,
            filaments: [SlicedFilament(id: 1, usedGrams: 9.8, usedMeters: 3.2, type: "PLA", colorHex: "E89CC6")],
            assigned: [pink: "SP-OLD"])
        #expect(charges == [FilamentConsumption.SpoolCharge(spoolID: "SP-OLD", grams: 9.8, filamentID: 1)])
    }
}
