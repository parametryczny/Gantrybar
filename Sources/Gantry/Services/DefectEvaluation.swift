import Foundation

/// How well the failure watcher does on prints it has already seen, with today's settings.
///
/// Replays every recorded session (`DefectRecorder`) through the same behaviour check, appearance
/// model and verdict the watcher uses live, and scores it per print, not per frame, because a print
/// is what a person loses: a false alarm is a clean print that got a warning, a catch is a failure
/// you confirmed that the replay warned about too. The reference frames are left out on purpose: they
/// include frames taken from these very prints, so they would be marking their own homework.
enum DefectEvaluation {
    struct PrintResult: Equatable {
        var startedAt: Date
        var hours: Double
        var outcome: DefectSession.Outcome?
        var clean: Bool
        var confirmedFailureAt: Date?
        /// The first warning the replay raised, if any.
        var firstAlarmAt: Date?
        var firstAlarmLabel: String?
    }

    struct Report: Equatable {
        var prints = 0
        var hours: Double = 0
        var cleanPrints = 0
        var cleanHours: Double = 0
        /// Clean prints that got a warning anyway.
        var falseAlarmPrints = 0
        var confirmedFailures = 0
        var caught = 0
        /// Minutes between the replay's warning and the warning you confirmed; positive means earlier.
        var leadMinutes: [Double] = []
        /// Prints that stopped or failed without a confirmed warning: nobody said what went wrong.
        var unlabelled = 0
        var unlabelledWarned = 0

        var falseAlarmsPer100Hours: Double { cleanHours > 0 ? Double(falseAlarmPrints) / cleanHours * 100 : 0 }
        var medianLeadMinutes: Double? {
            guard !leadMinutes.isEmpty else { return nil }
            let sorted = leadMinutes.sorted()
            return sorted[sorted.count / 2]
        }
    }

    /// A replayed warning counts as the same failure when it comes no later than this after the one
    /// you confirmed; the live watcher and the replay can land a frame apart.
    static let catchTolerance: TimeInterval = 120

    static func report(_ results: [PrintResult]) -> Report {
        var report = Report()
        for result in results {
            report.prints += 1
            report.hours += result.hours
            if let confirmed = result.confirmedFailureAt {
                report.confirmedFailures += 1
                if let alarm = result.firstAlarmAt, alarm.timeIntervalSince(confirmed) <= catchTolerance {
                    report.caught += 1
                    report.leadMinutes.append(confirmed.timeIntervalSince(alarm) / 60)
                }
            } else if result.clean {
                report.cleanPrints += 1
                report.cleanHours += result.hours
                if result.firstAlarmAt != nil { report.falseAlarmPrints += 1 }
            } else if result.outcome == .failed || result.outcome == .stopped {
                report.unlabelled += 1
                if result.firstAlarmAt != nil { report.unlabelledWarned += 1 }
            }
        }
        return report
    }

    /// Replays the finished sessions. Runs on the main actor because the model does; it yields
    /// between frames so the app stays responsive while a few thousand frames go through.
    @MainActor
    static func replay(_ sessions: [(folder: URL, session: DefectSession)], modelPath: String?,
                       threshold: Double, hitsNeeded: Int) async -> [PrintResult] {
        var results: [PrintResult] = []
        for (folder, session) in sessions where session.outcome != nil && !session.frames.isEmpty {
            let mask = DefectMask.load(serial: session.serial)
            var baseline = PrintBaseline()
            var verdict = DefectVerdict(threshold: threshold, hitsNeeded: hitsNeeded)
            var first: (at: Date, label: String)?
            for frame in session.frames {
                await Task.yield()
                guard let raw = try? Data(contentsOf: folder.appendingPathComponent(frame.file)),
                      let jpeg = try? mask.applying(to: raw),
                      let grey = FrameSignals.grey(from: jpeg), FrameSignals.legible(grey) else {
                    baseline.reset()
                    verdict.reset()
                    continue
                }
                let behaviour = baseline.observe(frame: grey, progress: Double(frame.progress) / 100)
                var readings = [behaviour]
                if let modelPath, let guess = try? DefectModel.shared.guess(jpeg: jpeg, path: modelPath),
                   let appearance = DefectAppearance.select(model: (guess.label, guess.confidence),
                                                            reference: nil, threshold: threshold) {
                    readings.append(PrintBaseline.Reading(label: appearance.label, confidence: appearance.confidence))
                }
                let best = strongest(readings, threshold: threshold)
                if case .failure(let label, _) = verdict.observe(label: best.label, confidence: best.confidence), first == nil {
                    first = (frame.at, label)
                }
            }
            results.append(PrintResult(startedAt: session.startedAt, hours: session.hours, outcome: session.outcome,
                                       clean: session.isClean, confirmedFailureAt: session.confirmedFailureAt,
                                       firstAlarmAt: first?.at, firstAlarmLabel: first?.label))
        }
        return results
    }

    /// The watcher's own rule: the strongest reading that crosses the threshold with a failure label,
    /// otherwise the strongest reading at all.
    static func strongest(_ readings: [PrintBaseline.Reading], threshold: Double) -> PrintBaseline.Reading {
        let alarming = readings
            .filter { $0.confidence >= threshold && ($0.label.map(DefectVerdict.warrantsWarning) ?? false) }
            .max { $0.confidence < $1.confidence }
        return alarming ?? readings.max { $0.confidence < $1.confidence } ?? PrintBaseline.Reading(label: nil, confidence: 0)
    }

    /// The report in words, for the Settings sheet.
    @MainActor
    static func summary(_ report: Report) -> String {
        let s = AppSettings.shared
        guard report.prints > 0 else {
            return s.t("No finished prints recorded yet. Gantry records every print it watches; come back after a few.")
        }
        var lines = [s.t("Prints replayed: {0} ({1} h)", report.prints, String(format: "%.1f", report.hours))]
        lines.append(s.t("Clean prints with a false alarm: {0} of {1} ({2} per 100 print hours)",
                         report.falseAlarmPrints, report.cleanPrints, String(format: "%.1f", report.falseAlarmsPer100Hours)))
        if report.confirmedFailures > 0 {
            var caught = s.t("Confirmed failures caught: {0} of {1}", report.caught, report.confirmedFailures)
            if let lead = report.medianLeadMinutes {
                caught += " · " + s.t("median {0} min before the warning you confirmed", String(format: "%.0f", lead))
            }
            lines.append(caught)
        } else {
            lines.append(s.t("No confirmed failures yet: answer the warnings so Gantry can count its catches."))
        }
        if report.unlabelled > 0 {
            lines.append(s.t("Stopped or failed without a confirmed warning: {0} (warned on {1})",
                             report.unlabelled, report.unlabelledWarned))
        }
        return lines.joined(separator: "\n")
    }
}
