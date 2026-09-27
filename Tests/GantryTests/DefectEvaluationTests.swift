import CoreGraphics
import Foundation
import Testing
@testable import Gantry

@Suite struct FrameCompositeTests {
    /// A grey bed with a dark "toolhead" square at a different place in each frame.
    private func frame(headAt x: Int, width: Int = 64, height: Int = 36) -> [UInt8] {
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        for row in 10..<20 {
            for column in x..<min(width, x + 10) {
                let i = (row * width + column) * 4
                pixels[i] = 10; pixels[i + 1] = 10; pixels[i + 2] = 10
            }
        }
        return pixels
    }

    @Test func theMedianDropsWhatMovesAndKeepsWhatStays() {
        let folded = FrameComposite.median(buffers: [frame(headAt: 0), frame(headAt: 20), frame(headAt: 40)])
        // Where the head was in only one frame, the bed shows through.
        #expect(folded[(15 * 64 + 5) * 4] == 128)
        #expect(folded[(15 * 64 + 45) * 4] == 128)
    }

    @Test func somethingInMostFramesStays() {
        let folded = FrameComposite.median(buffers: [frame(headAt: 20), frame(headAt: 20), frame(headAt: 40)])
        #expect(folded[(15 * 64 + 25) * 4] == 10)
    }

    @Test func aMovingBedIsNotSmearedIntoOneFrame() {
        // The whole picture shifts between frames, as on a bed-slinger: no median, pick one frame.
        func shifted(_ offset: Int) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: 64 * 36 * 4)
            for i in 0..<(64 * 36) { let v = UInt8(((i % 64) + offset) % 64 * 4); pixels[i * 4] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v }
            return pixels
        }
        #expect(FrameComposite.medoidIfSceneMoves([shifted(0), shifted(20), shifted(40)]) != nil)
        #expect(FrameComposite.medoidIfSceneMoves([frame(headAt: 0), frame(headAt: 20), frame(headAt: 40)]) == nil)
    }

    @Test func oneFrameIsReturnedAsItIs() {
        let jpeg = FrameComposite.encode(frame(headAt: 0), width: 64, height: 36)
        #expect(jpeg != nil)
        #expect(FrameComposite.median(jpegs: [jpeg!]) == jpeg)
    }

    @Test func jpegFramesFoldIntoOneReadablePicture() throws {
        let jpegs = [0, 20, 40].compactMap { FrameComposite.encode(frame(headAt: $0), width: 64, height: 36) }
        let folded = try #require(FrameComposite.median(jpegs: jpegs, width: 64))
        let image = try #require(FrameComposite.decode(folded))
        #expect(image.width == 64)
    }
}

@Suite struct DefectEvaluationTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func result(clean: Bool, outcome: DefectSession.Outcome = .finished, hours: Double = 2,
                        confirmedAfter: TimeInterval? = nil, alarmAfter: TimeInterval? = nil) -> DefectEvaluation.PrintResult {
        DefectEvaluation.PrintResult(startedAt: start, hours: hours, outcome: outcome, clean: clean,
                                     confirmedFailureAt: confirmedAfter.map { start.addingTimeInterval($0) },
                                     firstAlarmAt: alarmAfter.map { start.addingTimeInterval($0) },
                                     firstAlarmLabel: alarmAfter == nil ? nil : "spaghetti")
    }

    @Test func aWarningOnACleanPrintIsAFalseAlarm() {
        let report = DefectEvaluation.report([result(clean: true, alarmAfter: 600), result(clean: true), result(clean: true)])
        #expect(report.cleanPrints == 3)
        #expect(report.falseAlarmPrints == 1)
        #expect(abs(report.falseAlarmsPer100Hours - 100.0 / 6) < 0.001)
    }

    @Test func aConfirmedFailureIsCaughtWhenTheReplayWarnsInTime() {
        let report = DefectEvaluation.report([
            result(clean: false, outcome: .failed, confirmedAfter: 3600, alarmAfter: 3000),
            result(clean: false, outcome: .failed, confirmedAfter: 3600, alarmAfter: 4000),
            result(clean: false, outcome: .failed, confirmedAfter: 3600)
        ])
        #expect(report.confirmedFailures == 3)
        #expect(report.caught == 1)
        #expect(report.medianLeadMinutes == 10)
    }

    @Test func aStoppedPrintNobodyExplainedIsCountedApart() {
        let report = DefectEvaluation.report([result(clean: false, outcome: .stopped, alarmAfter: 100)])
        #expect(report.unlabelled == 1)
        #expect(report.unlabelledWarned == 1)
        #expect(report.falseAlarmPrints == 0)
    }

    @Test func aFinishedPrintWithAConfirmedWarningIsNotClean() {
        var session = DefectSession(serial: "s", printer: "P", kind: "bambu", job: "j", startedAt: start)
        session.outcome = .finished
        session.alarms = [DefectSession.Alarm(at: start, label: "spaghetti", confidence: 0.9, confirmed: true)]
        #expect(!session.isClean)
        #expect(session.confirmedFailureAt == start)
    }

    @Test func theWatchersRulePicksAnAlarmingReadingOverAQuietOne() {
        let best = DefectEvaluation.strongest([
            PrintBaseline.Reading(label: nil, confidence: 0.95),
            PrintBaseline.Reading(label: "spaghetti", confidence: 0.8)
        ], threshold: 0.7)
        #expect(best.label == "spaghetti")
    }

    @Test func howAPrintEndedLabelsTheRecording() {
        #expect(DefectRecorder.outcome(after: .finished) == .finished)
        #expect(DefectRecorder.outcome(after: .error) == .failed)
        #expect(DefectRecorder.outcome(after: .idle) == .stopped)
    }
}

@MainActor @Suite(.serialized) struct DefectRecorderTests {
    @Test func aSessionIsWrittenAndReadBackAndPrunedOldestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-recordings-\(UUID().uuidString)")
        DefectRecorder.rootOverride = root
        defer { DefectRecorder.rootOverride = nil; try? FileManager.default.removeItem(at: root) }
        let recorder = DefectRecorder()
        let printer = SavedPrinter(serial: "rec-1", name: "Rec", host: "10.0.0.1")
        var telemetry = PrinterTelemetry()
        telemetry.state = .printing
        telemetry.jobName = "benchy"
        telemetry.progress = 40
        let jpeg = Data(repeating: 1, count: 2048)
        recorder.record(jpeg: jpeg, printer: printer, telemetry: telemetry,
                        behaviour: PrintBaseline.Reading(label: nil, confidence: 0),
                        appearance: PrintBaseline.Reading(label: "spaghetti", confidence: 0.4), limitBytes: 1 << 30)
        recorder.noteAlarm(serial: "rec-1", label: "spaghetti", confidence: 0.9)
        recorder.noteAnswer(serial: "rec-1", confirmed: false)
        recorder.close(serial: "rec-1", outcome: .finished)

        let sessions = DefectRecorder.sessions(in: root)
        let session = try #require(sessions.first?.session)
        #expect(session.frames.count == 1)
        #expect(session.frames[0].appearance == "spaghetti")
        #expect(session.alarms.first?.confirmed == false)
        #expect(session.outcome == .finished)
        #expect(session.isClean)

        telemetry.jobName = "second"
        recorder.record(jpeg: jpeg, printer: printer, telemetry: telemetry,
                        behaviour: PrintBaseline.Reading(label: nil, confidence: 0), appearance: nil, limitBytes: 1 << 30)
        recorder.close(serial: "rec-1", outcome: .stopped)
        #expect(DefectRecorder.sessions(in: root).count == 2)
        DefectRecorder.prune(to: 1, in: root)
        let left = DefectRecorder.sessions(in: root)
        #expect(left.count == 1)
        #expect(left.first?.session.job == "second")
    }
}
