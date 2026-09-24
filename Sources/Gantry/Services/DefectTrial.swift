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
        /// The name of the Core ML file that answered, when one is chosen. The trial has to ask
        /// whatever the watcher would ask, or it tests something the user is not running.
        var modelName: String?
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
        return try judge(jpeg: jpeg, prototypes: prototypes, threshold: threshold)
    }

    /// The same question about a frame already in hand, such as the one a printer's camera is showing
    /// right now.
    static func judge(jpeg: Data,
                      prototypes: [DefectPrototypes.Prototype]? = nil,
                      threshold: Double? = nil) throws -> Verdict {
        let limit = threshold ?? AppSettings.shared.defectThreshold
        // Exactly what the watcher asks: the engine and the reference frames, both, every time.
        // Trying one thing and running another is worse than not offering the trial at all.
        let bank = prototypes ?? DefectPrototypes.build()
        let tally = DefectPrototypes.tally(bank)
        let fromFrames = DefectPrototypes.match(jpeg: jpeg, against: bank)

        var fromModel: DefectModel.Guess?
        var engine: String?
        if prototypes == nil,
           let path = DefectModel.effectivePath(chosen: AppSettings.shared.defectModelPath) {
            fromModel = try DefectModel.shared.guess(jpeg: jpeg, path: path)
            engine = DefectModel.shared.displayName(for: path)
        }
        guard fromModel != nil || !bank.isEmpty else { throw Failure.nothingToCompareWith }

        // The same rule the watcher uses: whichever of the two has a real reason to warn wins, and
        // failing that, whichever is surer. Anything else would have the trial answer a question the
        // watcher is not asking.
        let readings: [(label: String?, confidence: Double)] =
            [(fromModel?.label, fromModel?.confidence ?? 0), (fromFrames?.label, fromFrames?.confidence ?? 0)]
        let alarming = readings
            .filter { $0.confidence >= limit && ($0.label.map(DefectVerdict.warrantsWarning) ?? false) }
            .max { $0.confidence < $1.confidence }
        let best = alarming ?? readings.max { $0.confidence < $1.confidence }
        return Verdict(jpeg: jpeg, label: best?.label, confidence: best?.confidence ?? 0,
                       raisesAlarm: alarming != nil, threshold: limit,
                       comparedAgainst: bank.count, mine: tally.mine, modelName: engine)
    }

    /// Any picture macOS can open, as the JPEG the recogniser works on. A camera frame is a JPEG, so
    /// this puts a file from disk through the same door rather than a second, kinder one.
    static func jpeg(from url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    /// The picture as Gantry sees it, plus the verdict, as a sheet anything can show.
    ///
    /// Shared by Settings, which judges a file the user picked, and Details, which judges what a
    /// particular printer's camera is showing right now. One place, so the two can never start
    /// answering the same question differently.
    static func sheet(for verdict: Verdict, title: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title.map { "\($0): \(headline(verdict))" } ?? headline(verdict)
        alert.informativeText = detail(verdict)
        alert.alertStyle = verdict.raisesAlarm ? .critical : .informational
        if let image = NSImage(data: verdict.jpeg) {
            let width: CGFloat = 320
            let ratio = image.size.height > 0 ? image.size.width / image.size.height : 4.0 / 3
            let height = min(260, max(120, width / max(ratio, 0.2)))
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = 8
            view.layer?.masksToBounds = true
            alert.accessoryView = view
        }
        alert.addButton(withTitle: AppSettings.shared.t("Close"))
        return alert
    }

    /// The one-line answer, in the user's language.
    ///
    /// Four outcomes and four different sentences, each saying what Gantry would *do*, because that
    /// is the question somebody clicking this is actually asking.
    static func headline(_ verdict: Verdict) -> String {
        let settings = AppSettings.shared
        guard let label = verdict.label else { return settings.t("No opinion about this picture.") }
        if DefectVerdict.isHealthy(label) { return settings.t("Clear. The print looks fine.") }
        if DefectVerdict.isCosmetic(label) {
            return settings.t("{0}. A blemish, not a failure, so Gantry stays quiet.", settings.t(label))
        }
        return verdict.raisesAlarm
            ? settings.t("{0}. Gantry would warn you.", settings.t(label))
            : settings.t("Something like {0}, but too weak to warn about.", settings.t(label))
    }

    /// The line under it: the numbers behind the answer, then what this trial does and does not cover.
    static func detail(_ verdict: Verdict) -> String {
        let settings = AppSettings.shared
        let sure = Int((verdict.confidence * 100).rounded())
        let limit = Int((verdict.threshold * 100).rounded())
        var source = verdict.modelName ?? settings.t("your own frames")
        if verdict.modelName != nil, verdict.mine > 0 {
            source += settings.t(" + {0} of your frames", verdict.mine)
        }
        return settings.t("Certainty {0}% · warns from {1}% · engine {2}", sure, limit, source)
            + "\n" + settings.t("One frame judged. How a print changes over time, Gantry watches separately and live.")
    }
}
