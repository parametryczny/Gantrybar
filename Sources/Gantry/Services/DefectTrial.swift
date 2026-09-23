import AppKit

/// Trying the recogniser on a picture you already have, instead of waiting for a print to fail.
///
/// Everything else about this feature is invisible until something goes wrong at three in the
/// morning, which is a poor way to find out it was never going to work. Point it at a photograph of
/// a failure, or at an ordinary print, and it says what it would have said.
///
/// It exercises one half of the watcher: recognition by appearance, which is the half a single
/// picture can test. The other half watches how a print changes from minute to minute, and no one
/// photograph can stand in for that.
@MainActor
enum DefectTrial {
    struct Verdict {
        /// The picture as Gantry saw it, so the sheet shows exactly what was judged.
        var jpeg: Data
        var label: String?
        var confidence: Double
        /// Whether this would actually have raised a warning at the current sensitivity. A guess
        /// below the threshold is still reported, because "it saw it but was not sure enough" is the
        /// most useful thing the trial can tell somebody about where to put the slider.
        var raisesAlarm: Bool
        var threshold: Double
        /// How many reference frames it compared against, and how many of those are the user's own.
        var comparedAgainst: Int
        var mine: Int
    }

    /// The message is carried rather than looked up, because `errorDescription` is not isolated to
    /// the main actor and the catalogue is.
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }

        @MainActor static var unreadable: Failure {
            Failure(message: AppSettings.shared.t("That file is not a picture Gantry can read."))
        }
        @MainActor static var nothingToCompareWith: Failure {
            Failure(message: AppSettings.shared.t("There are no reference frames to compare against."))
        }
    }

    static func judge(imageAt url: URL,
                      prototypes: [DefectPrototypes.Prototype]? = nil,
                      threshold: Double? = nil) throws -> Verdict {
        guard let jpeg = jpeg(from: url) else { throw Failure.unreadable }
        let bank = prototypes ?? DefectPrototypes.build()
        guard !bank.isEmpty else { throw Failure.nothingToCompareWith }
        let limit = threshold ?? AppSettings.shared.defectThreshold
        let match = DefectPrototypes.match(jpeg: jpeg, against: bank)
        let tally = DefectPrototypes.tally(bank)
        let alarming = match.map { !DefectVerdict.isHealthy($0.label) && $0.confidence >= limit } ?? false
        return Verdict(jpeg: jpeg, label: match?.label, confidence: match?.confidence ?? 0,
                       raisesAlarm: alarming, threshold: limit,
                       comparedAgainst: bank.count, mine: tally.mine)
    }

    /// Any picture macOS can open, as the JPEG the recogniser works on. A camera frame is a JPEG, so
    /// this puts a file from disk through the same door rather than a second, kinder one.
    static func jpeg(from url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    /// The one-line answer, in the user's language.
    static func headline(_ verdict: Verdict) -> String {
        let settings = AppSettings.shared
        guard let label = verdict.label else { return settings.t("No opinion about this picture.") }
        if DefectVerdict.isHealthy(label) { return settings.t("Looks like a print going well.") }
        return verdict.raisesAlarm
            ? settings.t("This would raise a warning: {0}.", settings.t(label))
            : settings.t("Closest to {0}, but not sure enough to warn.", settings.t(label))
    }

    /// The line under it: the numbers behind the answer.
    static func detail(_ verdict: Verdict) -> String {
        let settings = AppSettings.shared
        let sure = Int((verdict.confidence * 100).rounded())
        let limit = Int((verdict.threshold * 100).rounded())
        return settings.t("Sureness {0}%, warns from {1}%. Compared against {2} reference frames, {3} of them yours. This checks what the picture looks like; watching how a print changes over time cannot be tried on one photograph.",
                          sure, limit, verdict.comparedAgainst, verdict.mine)
    }
}
