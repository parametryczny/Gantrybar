import Testing
import Foundation
@testable import Gantry

@Suite struct BambuPathFixtureTests {
    private struct Case: Decodable {
        let file: String
        let paths: [String]
    }

    /// The same fixture holds Windows and Linux to the paths macOS tries.
    @Test func candidatePathsMatchTheSharedFixture() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("design/fixtures/bambu-3mf-candidates.json"))
        let cases = try JSONDecoder().decode([Case].self, from: data)
        #expect(!cases.isEmpty)
        for item in cases {
            #expect(BambuFileClient.candidatePaths(fileName: item.file) == item.paths, "\(item.file)")
        }
    }
}

@MainActor @Suite struct BambuColourMatchingTests {
    private func slot(_ id: String, material: String, color: String) -> FilamentSlot {
        FilamentSlot(id: id, label: id, material: material, colorHex: color, remainingPercent: nil, isActive: false)
    }

    private func group(_ slots: [FilamentSlot]) -> FilamentGroup {
        FilamentGroup(id: UUID().uuidString, sourceType: .ams, displayName: "AMS", declaredCapacity: slots.count,
                      humidityPercent: nil, temperatureCelsius: nil, isExternal: false, slots: slots)
    }

    @Test func twoRollsOfOneColourAreToldApartByMaterial() {
        let groups = [group([slot("A1", material: "PLA", color: "000000FF"), slot("A2", material: "PETG", color: "000000FF")])]
        let pla = FilamentConsumption.slotLocation(serial: "X1", groups: groups, group: 0, slot: 0)
        let petg = FilamentConsumption.slotLocation(serial: "X1", groups: groups, group: 0, slot: 1)
        let charges = FilamentConsumption.bambuCharges(
            serial: "X1", groups: groups,
            filaments: [SlicedFilament(id: 1, usedGrams: 4, usedMeters: 1, type: "PETG", colorHex: "000000"),
                        SlicedFilament(id: 2, usedGrams: 2, usedMeters: 1, type: "PLA", colorHex: "000000")],
            assigned: [pla: "SP-PLA", petg: "SP-PETG"])
        #expect(charges.map(\.spoolID) == ["SP-PETG", "SP-PLA"])
    }

    @Test func twoIdenticalRollsAreNotChargedAsOne() {
        let groups = [group([slot("A1", material: "PLA", color: "000000FF"), slot("A2", material: "PLA", color: "000000FF")])]
        let first = FilamentConsumption.slotLocation(serial: "X1", groups: groups, group: 0, slot: 0)
        let second = FilamentConsumption.slotLocation(serial: "X1", groups: groups, group: 0, slot: 1)
        let charges = FilamentConsumption.bambuCharges(
            serial: "X1", groups: groups,
            filaments: [SlicedFilament(id: 1, usedGrams: 4, usedMeters: 1, type: "PLA", colorHex: "000000"),
                        SlicedFilament(id: 2, usedGrams: 3, usedMeters: 1, type: "PLA", colorHex: "FFFFFF")],
            assigned: [first: "SP-1", second: "SP-2"])
        #expect(charges.isEmpty)
    }
}
