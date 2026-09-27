import Foundation

/// Every print, as the failure watcher saw it, kept so the watcher can be measured.
///
/// Without this the only way to tell whether a change to detection helped was to wait for a print to
/// fail, and "it caught 22 of 22" rested on 62 photographs. Each print the watcher looks at is now a
/// session on disk: the frames it judged (the composites, toolhead folded away), what each part of the
/// watcher said about them, the warnings it raised, what you answered, and how the print ended. That
/// labels itself: a print that finished and that you never confirmed a failure on is a clean print,
/// so any warning on it is a false alarm; a warning you confirmed is a real failure with a time on it.
///
/// Sessions live beside the marked frames, under their own size limit, oldest removed first.
/// `DefectEvaluation` replays them with the watcher's current settings.
struct DefectSession: Codable, Equatable {
    struct Frame: Codable, Equatable {
        var file: String
        var at: Date
        var progress: Int
        var layer: Int?
        /// What the behaviour check and the appearance check said, live, when the frame was taken.
        var behaviour: String?
        var behaviourConfidence: Double
        var appearance: String?
        var appearanceConfidence: Double
    }

    struct Alarm: Codable, Equatable {
        var at: Date
        var label: String
        var confidence: Double
        /// nil until answered; true when you said the warning was right.
        var confirmed: Bool?
    }

    enum Outcome: String, Codable { case finished, failed, stopped, unknown }

    var serial: String
    var printer: String
    var kind: String
    var job: String
    var startedAt: Date
    var endedAt: Date?
    var outcome: Outcome?
    var frames: [Frame] = []
    var alarms: [Alarm] = []
    /// The bed calibration and object outlines in force, so a replay can place the objects too.
    var calibration: BedCalibration?
    var outlines: [[BedCalibration.Point]]?

    var hours: Double { ((endedAt ?? frames.last?.at ?? startedAt).timeIntervalSince(startedAt)) / 3600 }
    /// A print known to be good: it finished and no warning on it was confirmed.
    var isClean: Bool { outcome == .finished && !alarms.contains { $0.confirmed == true } }
    /// When you confirmed a failure on it, if you did.
    var confirmedFailureAt: Date? { alarms.first { $0.confirmed == true }?.at }
}

@MainActor
final class DefectRecorder {
    static let shared = DefectRecorder()

    nonisolated(unsafe) static var rootOverride: URL?
    nonisolated static var root: URL {
        if let rootOverride { return rootOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Gantry/DefectRecordings", isDirectory: true)
    }

    private var active: [String: (folder: URL, session: DefectSession)] = [:]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()


    /// Adds one judged frame to this printer's session, starting a session when the job changes.
    func record(jpeg: Data, printer: SavedPrinter, telemetry: PrinterTelemetry,
                behaviour: PrintBaseline.Reading, appearance: PrintBaseline.Reading?, limitBytes: Int64) {
        let job = telemetry.jobName ?? ""
        if let current = active[printer.serial], current.session.job != job {
            close(serial: printer.serial, outcome: .unknown)
        }
        if active[printer.serial] == nil {
            let started = Date()
            let stamp = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "-")
            let safeSerial = printer.serial.replacingOccurrences(of: "/", with: "-")
            let folder = Self.root.appendingPathComponent("\(safeSerial)-\(stamp)-\(UUID().uuidString.prefix(6))", isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
            active[printer.serial] = (folder, DefectSession(serial: printer.serial, printer: printer.name,
                                                          kind: printer.kind.rawValue, job: job, startedAt: started))
            Self.prune(to: limitBytes)
        }
        guard var entry = active[printer.serial] else { return }
        let name = String(format: "%05d.jpg", entry.session.frames.count)
        guard (try? jpeg.write(to: entry.folder.appendingPathComponent(name), options: .atomic)) != nil else { return }
        entry.session.frames.append(DefectSession.Frame(
            file: name, at: Date(), progress: telemetry.progress, layer: telemetry.currentLayer,
            behaviour: behaviour.label, behaviourConfidence: behaviour.confidence,
            appearance: appearance?.label, appearanceConfidence: appearance?.confidence ?? 0))
        active[printer.serial] = entry
        write(entry)
    }

    /// Keeps the calibration and outlines the live watcher used, once they are known or change.
    func describe(serial: String, calibration: BedCalibration, outlines: [[BedCalibration.Point]]) {
        guard var entry = active[serial] else { return }
        let keptOutlines = outlines.isEmpty ? entry.session.outlines : outlines
        guard entry.session.calibration != calibration || entry.session.outlines != keptOutlines else { return }
        entry.session.calibration = calibration
        entry.session.outlines = keptOutlines
        active[serial] = entry
        write(entry)
    }

    func noteAlarm(serial: String, label: String, confidence: Double) {
        guard var entry = active[serial] else { return }
        entry.session.alarms.append(DefectSession.Alarm(at: Date(), label: label, confidence: confidence))
        active[serial] = entry
        write(entry)
    }

    /// Your answer to the latest warning, on the open session or, if the print already ended, on the
    /// newest session of that printer.
    func noteAnswer(serial: String, confirmed: Bool) {
        if var entry = active[serial], let index = entry.session.alarms.indices.last {
            entry.session.alarms[index].confirmed = confirmed
            active[serial] = entry
            write(entry)
            return
        }
        guard let found = Self.sessions().filter({ $0.session.serial == serial }).last,
              let index = found.session.alarms.indices.last else { return }
        var session = found.session
        session.alarms[index].confirmed = confirmed
        write((found.folder, session))
    }

    var openSerials: [String] { Array(active.keys) }

    func close(serial: String, outcome: DefectSession.Outcome) {
        guard var entry = active.removeValue(forKey: serial) else { return }
        entry.session.endedAt = Date()
        entry.session.outcome = outcome
        write(entry)
    }

    /// How a print ended, read from the state the printer went to when it stopped printing.
    nonisolated static func outcome(after state: PrinterState) -> DefectSession.Outcome {
        switch state {
        case .finished: .finished
        case .error: .failed
        case .idle: .stopped
        default: .unknown
        }
    }

    private func write(_ entry: (folder: URL, session: DefectSession)) {
        guard let data = try? encoder.encode(entry.session) else { return }
        try? data.write(to: entry.folder.appendingPathComponent("session.json"), options: .atomic)
    }

    // MARK: Reading back

    nonisolated static func sessions(in root: URL = root) -> [(folder: URL, session: DefectSession)] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder -> (URL, DefectSession)? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                  let session = try? JSONDecoder().decode(DefectSession.self, from: data) else { return nil }
            return (folder, session)
        }.sorted { $0.1.startedAt < $1.1.startedAt }
    }

    /// Removes whole sessions, oldest first, until the recordings fit the limit.
    nonisolated static func prune(to limitBytes: Int64, in root: URL = root) {
        var list = sessions(in: root).map { ($0.folder, size(of: $0.folder)) }
        var total = list.reduce(Int64(0)) { $0 + $1.1 }
        while total > limitBytes, list.count > 1 {
            let (folder, bytes) = list.removeFirst()
            try? FileManager.default.removeItem(at: folder)
            total -= bytes
        }
    }

    nonisolated static func size(of folder: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
