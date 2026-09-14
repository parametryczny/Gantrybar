import Testing
import Foundation
@testable import Gantry

@Suite struct FTPFileCacheTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func expiredFilesLeaveEvenWhenNobodyAsksForThemAgain() {
        var cache = FTPFileCache()
        cache.store(Data(count: 10), for: "printer|a.3mf", now: start)
        cache.store(Data(count: 10), for: "printer|b.3mf", now: start.addingTimeInterval(FTPFileCache.freshness + 1))
        #expect(cache.count == 1)
        #expect(cache.value(for: "printer|b.3mf", now: start.addingTimeInterval(FTPFileCache.freshness + 2)) != nil)
    }

    @Test func theTotalStaysUnderTheLimitOldestOutFirst() {
        var cache = FTPFileCache(byteLimit: 25)
        for index in 0..<5 {
            cache.store(Data(count: 10), for: "printer|\(index).3mf", now: start.addingTimeInterval(Double(index)))
        }
        #expect(cache.totalBytes <= 25)
        #expect(cache.value(for: "printer|4.3mf", now: start.addingTimeInterval(5)) != nil)
        #expect(cache.value(for: "printer|0.3mf", now: start.addingTimeInterval(5)) == nil)
    }
}

@MainActor @Suite struct ScriptRunnerTests {
    @Test func aReplacedRunsExitDoesNotUnregisterTheRunThatReplacedIt() async throws {
        let runner = ScriptRunner.shared
        let id = UUID()
        #expect(runner.run(id, script: "exit 0"))
        #expect(runner.run(id, script: "sleep 5"))
        try await Task.sleep(for: .milliseconds(800))
        #expect(runner.isRunning(id))
        runner.stop(id)
        #expect(!runner.isRunning(id))
    }
}
