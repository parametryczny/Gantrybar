import Testing
@testable import Gantry

/// When a guess becomes a warning. This is the part that decides whether a shadow at three in the
/// morning gets somebody out of bed, so it is tested on its own, without a camera or a model.
@Suite struct DefectVerdictTests {
    @Test func oneSuspiciousFrameIsNotAVerdict() {
        var verdict = DefectVerdict(threshold: 0.7, hitsNeeded: 3)
        #expect(verdict.observe(label: "spaghetti", confidence: 0.9) == .quiet)
        #expect(verdict.observe(label: "spaghetti", confidence: 0.9) == .quiet)
        #expect(verdict.observe(label: "spaghetti", confidence: 0.9) == .failure(label: "spaghetti", confidence: 0.9))
    }

    @Test func aGuessBelowTheThresholdDoesNotCount() {
        var verdict = DefectVerdict(threshold: 0.7, hitsNeeded: 2)
        #expect(verdict.observe(label: "spaghetti", confidence: 0.4) == .quiet)
        #expect(verdict.observe(label: "spaghetti", confidence: 0.69) == .quiet)
        #expect(verdict.observe(label: "spaghetti", confidence: 0.71) == .quiet, "the low frames must not have counted")
    }

    @Test func aHealthyFrameIsNeverAFailureWhateverItIsCalled() {
        var verdict = DefectVerdict(threshold: 0.5, hitsNeeded: 1)
        for healthy in ["ok", "OK", "normal", "good", "Printing correctly", "none"] {
            #expect(verdict.observe(label: healthy, confidence: 0.99) == .quiet, "\(healthy) was taken for a failure")
        }
    }

    @Test func theSameFailureIsReportedOnceNotOnEveryFrame() {
        var verdict = DefectVerdict(threshold: 0.7, hitsNeeded: 2, calmNeeded: 2)
        _ = verdict.observe(label: "spaghetti", confidence: 0.8)
        #expect(verdict.observe(label: "spaghetti", confidence: 0.8) == .failure(label: "spaghetti", confidence: 0.8))
        for _ in 0..<5 {
            #expect(verdict.observe(label: "spaghetti", confidence: 0.95) == .quiet, "it nagged about the same failure")
        }
    }

    @Test func aPrintThatRecoversCanWarnAgainLater() {
        var verdict = DefectVerdict(threshold: 0.7, hitsNeeded: 2, calmNeeded: 2)
        _ = verdict.observe(label: "spaghetti", confidence: 0.8)
        _ = verdict.observe(label: "spaghetti", confidence: 0.8)
        // Back to normal for long enough to count as recovered.
        _ = verdict.observe(label: "ok", confidence: 0.9)
        _ = verdict.observe(label: "ok", confidence: 0.9)
        _ = verdict.observe(label: "spaghetti", confidence: 0.8)
        #expect(verdict.observe(label: "spaghetti", confidence: 0.8) == .failure(label: "spaghetti", confidence: 0.8))
    }

    @Test func oneCalmFrameDoesNotWipeOutARealFailure() {
        var verdict = DefectVerdict(threshold: 0.7, hitsNeeded: 3, calmNeeded: 3)
        _ = verdict.observe(label: "spaghetti", confidence: 0.8)
        _ = verdict.observe(label: "spaghetti", confidence: 0.8)
        _ = verdict.observe(label: "ok", confidence: 0.9)   // jedna spokojna klatka w środku
        #expect(verdict.observe(label: "spaghetti", confidence: 0.8) == .failure(label: "spaghetti", confidence: 0.8))
    }

    @Test func aDifferentFailureIsANewQuestion() {
        var verdict = DefectVerdict(threshold: 0.7, hitsNeeded: 2, calmNeeded: 3)
        _ = verdict.observe(label: "spaghetti", confidence: 0.8)
        #expect(verdict.observe(label: "spaghetti", confidence: 0.8) == .failure(label: "spaghetti", confidence: 0.8))
        _ = verdict.observe(label: "blob", confidence: 0.8)
        #expect(verdict.observe(label: "blob", confidence: 0.8) == .failure(label: "blob", confidence: 0.8))
    }
}
