import Foundation

/// Turning a stream of guesses into one decision worth waking somebody for.
///
/// A model looking at a camera is wrong now and then: a shadow, a hand reaching in, a frame caught
/// mid-move. Acting on a single frame means false alarms at three in the morning, and a user who
/// turns the whole thing off. So a verdict needs the same answer several times in a row before it
/// counts, and it is only ever given once per print until the picture goes back to normal.
///
/// Kept apart from the model and the camera on purpose: this is the part that decides, and it is the
/// part worth testing.
struct DefectVerdict {
    /// How sure the model must be before a frame counts as suspicious at all.
    var threshold: Double
    /// How many suspicious frames in a row make it a verdict.
    var hitsNeeded: Int
    /// How many calm frames in a row clear the count, so one calm frame does not reset a real failure
    /// that flickers, and a genuinely fixed print does stop nagging.
    var calmNeeded: Int

    init(threshold: Double = 0.7, hitsNeeded: Int = 3, calmNeeded: Int = 3) {
        self.threshold = threshold
        self.hitsNeeded = max(1, hitsNeeded)
        self.calmNeeded = max(1, calmNeeded)
    }

    private(set) var hits = 0
    private(set) var calm = 0
    /// True once a verdict has been given, so the same failure is reported once and not every frame.
    private(set) var reported = false
    private(set) var label: String?

    enum Outcome: Equatable {
        /// Nothing to say.
        case quiet
        /// This is the frame that makes it a verdict: report it.
        case failure(label: String, confidence: Double)
    }

    /// Feeds one frame's best guess in and gets back whether it changes anything.
    mutating func observe(label: String?, confidence: Double) -> Outcome {
        let suspicious = label != nil && !isHealthy(label!) && confidence >= threshold
        guard suspicious else {
            calm += 1
            if calm >= calmNeeded {
                // The print looks right again: forget the count and allow a future warning.
                hits = 0
                reported = false
                self.label = nil
            }
            return .quiet
        }
        calm = 0
        // A different kind of failure is a new question, not a continuation of the old one.
        if let previous = self.label, previous != label {
            hits = 0
            reported = false
        }
        self.label = label
        hits += 1
        guard hits >= hitsNeeded, !reported else { return .quiet }
        reported = true
        return .failure(label: label!, confidence: confidence)
    }

    /// A new print starts with a clean slate.
    mutating func reset() {
        hits = 0
        calm = 0
        reported = false
        label = nil
    }

    /// Labels that mean "this is fine". Models name the healthy class differently, so the check is on
    /// the word rather than on a fixed string from one particular model.
    static func isHealthy(_ label: String) -> Bool {
        let healthy = ["ok", "normal", "good", "healthy", "printing correctly", "no-failure", "none",
                       "no defect", "no_defect", "no_defected", "successful print", "success"]
        return healthy.contains(label.lowercased())
    }

    /// Blemishes, not disasters. A downloaded detector often knows several of these, and a print
    /// with stringing finishes and can be cleaned up with a knife; a print with spaghetti is over.
    /// Waking somebody at three in the morning to tell them about stringing is how a person learns
    /// to ignore the warnings that matter, so these are recognised and reported but never alarm.
    static func isCosmetic(_ label: String) -> Bool {
        let cosmetic = ["stringing", "zits", "blobs and zits", "z-banding", "vfa", "unsmooth surface",
                        "elephants foot", "over extrusion", "under extrusion", "overhang sagging"]
        return cosmetic.contains(label.lowercased())
    }

    /// Whether a label is worth interrupting somebody for at all.
    static func warrantsWarning(_ label: String) -> Bool { !isHealthy(label) && !isCosmetic(label) }

    private func isHealthy(_ label: String) -> Bool { !Self.warrantsWarning(label) }
}
