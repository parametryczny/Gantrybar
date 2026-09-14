import Foundation
import Testing
@testable import Gantry

@MainActor @Suite struct SpoolTransactionTests {
    @Test func replayAfterRestartCannotChargeReplacementRoll() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rolls = dir.appendingPathComponent("spools.json"), usage = dir.appendingPathComponent("usage.json")
        let store = PhysicalSpoolStore(spoolsURL: rolls, usageURL: usage)
        let created = store.createRolls(definitionID: UUID(), count: 2, weight: 1000)
        #expect(store.consume(spoolID: created[0].id, grams: 10, printerSerial: "K", printJobID: "job"))
        let restored = PhysicalSpoolStore(spoolsURL: rolls, usageURL: usage)
        #expect(!restored.consume(spoolID: created[1].id, grams: 10, printerSerial: "K", printJobID: "job"))
        #expect(restored.spool(id: created[1].id)?.remainingWeightGrams == 1000)
        #expect(restored.usageEvents.count == 1)
    }
    @Test func failedAtomicReplacementDoesNotReportSuccessOrKeepDeduction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rolls = dir.appendingPathComponent("spools.json"), usage = dir.appendingPathComponent("usage.json")
        let store = PhysicalSpoolStore(spoolsURL: rolls, usageURL: usage)
        let roll = store.createRolls(definitionID: UUID(), count: 1, weight: 1000)[0]
        // Replace the destination with a nonempty directory: rename/write must fail even as admin.
        let state = rolls.deletingPathExtension().appendingPathExtension("state-v2.json")
        let saved = try Data(contentsOf: state)
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data([1]).write(to: state.appendingPathComponent("keep"))
        #expect(!store.consume(spoolID: roll.id, grams: 10, printerSerial: "K", printJobID: "job"))
        #expect(store.spool(id: roll.id)?.remainingWeightGrams == 1000)
        #expect(store.usageEvents.isEmpty)
        #expect(store.lastError != nil)
        try FileManager.default.removeItem(at: state); try saved.write(to: state)
        #expect(store.consume(spoolID: roll.id, grams: 10, printerSerial: "K", printJobID: "job"))
        let restored = PhysicalSpoolStore(spoolsURL: rolls, usageURL: usage)
        #expect(restored.spool(id: roll.id)?.remainingWeightGrams == 990)
        #expect(restored.usageEvents.count == 1)
    }
    @Test func disabledFinishStaysSkippedAndWarningsPersist() throws {
        var tracker = PrintJobSessions()
        _ = tracker.observe(serial: "K", previous: .idle, state: .printing, jobName: "cube", now: Date(timeIntervalSince1970: 100))
        #expect(tracker.observe(serial: "K", previous: .printing, state: .finished, jobName: "cube", now: Date(timeIntervalSince1970: 200), accountingEnabled: false) == nil)
        var restored = try JSONDecoder().decode(PrintJobSessions.self, from: JSONEncoder().encode(tracker))
        #expect(restored.observe(serial: "K", previous: .offline, state: .finished, jobName: "cube", now: Date(timeIntervalSince1970: 900)) == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rolls = dir.appendingPathComponent("spools.json"), usage = dir.appendingPathComponent("usage.json")
        let store = PhysicalSpoolStore(spoolsURL: rolls, usageURL: usage)
        store.warnAccounting(job: "K|job", name: "cube")
        let reopened = PhysicalSpoolStore(spoolsURL: rolls, usageURL: usage)
        #expect(reopened.accountingWarnings == ["K|job": "cube"])
        let roll = reopened.createRolls(definitionID: UUID(), count: 1, weight: 1000)[0]
        reopened.clearAccountingWarnings()
        #expect(!PhysicalSpoolStore(spoolsURL: rolls, usageURL: usage).consume(spoolID: roll.id, grams: 10, printerSerial: "K", printJobID: "K|job#1"))
        #expect(PhysicalSpoolStore(spoolsURL: rolls, usageURL: usage).accountingWarnings.isEmpty)
    }
}
