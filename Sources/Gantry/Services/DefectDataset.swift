import AppKit

/// The pictures Gantry learns from, and the only place they are kept.
///
/// A frame is saved because the user looked at the camera and said what they saw. That is worth more
/// than a folder full of frames somebody has to sort out later: every file here already carries its
/// label, the printer it came from, and what the print was doing at that second.
///
/// It cannot grow without bound. The folder has a size limit, and when a save would cross it the
/// oldest frames go first, `ok` before a defect, because ordinary printing is easy to photograph again
/// and a real failure is not.
@MainActor
enum DefectDataset {
    /// What the user can mark. Three of these a single frame can honestly show; a layer shift is a
    /// difference between frames, so it is collected here but will need its own detector later.
    enum Label: String, CaseIterable {
        case ok
        case spaghetti
        case detached
        case blob
        case layerShift = "layer-shift"
        case other

        /// The English source string; the catalogue turns it into the user's language.
        var title: String {
            switch self {
            case .ok: "Printing correctly"
            case .spaghetti: "Spaghetti"
            case .detached: "Object came off the bed"
            case .blob: "Blob on the nozzle"
            case .layerShift: "Layer shift"
            case .other: "Something else"
            }
        }
    }

    struct Stats: Equatable {
        var frames = 0
        var bytes: Int64 = 0
        var byLabel: [String: Int] = [:]
    }

    /// The default ceiling. A camera frame runs 150 to 300 kB, so this is a few thousand pictures:
    /// far more than hand-marking produces, and small enough to never be the reason a disk fills up.
    static let defaultLimitBytes: Int64 = 500 * 1024 * 1024

    /// Dokąd naprawdę trafiają klatki. Nadpisywane wyłącznie przez testy.
    ///
    /// Bez tego testy tego katalogu kasowały prawdziwy katalog użytkownika, bo `save`, `prune` i
    /// sprzątanie po teście wszystkie pytały o tę jedną ścieżkę. Jedno uruchomienie zestawu testów
    /// zabrało komuś sto szesnaście zebranych klatek. Ścieżka, której nie da się podmienić, to nie
    /// jest bezpieczna stała, tylko mina.
    nonisolated(unsafe) static var rootOverride: URL?

    nonisolated static var root: URL {
        if let rootOverride { return rootOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Gantry/dataset", isDirectory: true)
    }

    nonisolated static var indexFile: URL { root.appendingPathComponent("index.jsonl") }

    /// Saves one frame under its label, with everything a trainer would want to know about it.
    @discardableResult
    static func save(jpeg: Data, label: Label, printer: SavedPrinter, telemetry: PrinterTelemetry,
                     limitBytes: Int64 = defaultLimitBytes, automatic: Bool = false, prediction: Bool = false) throws -> URL {
        let folder = root.appendingPathComponent(label.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("\(printer.serial)-\(stamp).jpg")
        try jpeg.write(to: file, options: .atomic)
        appendIndex([
            "file": "\(label.rawValue)/\(file.lastPathComponent)",
            "label": label.rawValue,
            "serial": printer.serial,
            "printer": printer.name,
            "kind": printer.kind.rawValue,
            "job": telemetry.jobName ?? "",
            "state": telemetry.state.rawValue,
            "progress": telemetry.progress,
            "layer": telemetry.currentLayer as Any,
            "totalLayers": telemetry.totalLayers as Any,
            "nozzle": telemetry.nozzleTemperature as Any,
            "bed": telemetry.bedTemperature as Any,
            "bytes": jpeg.count,
            // Frames Gantry kept by itself are marked, so a trainer can tell them from the ones a
            // person looked at and named. A human's label is worth more and should stay countable.
            "automatic": automatic,
            "labelSource": prediction ? "prediction" : (automatic ? "automatic" : "user"),
            "at": ISO8601DateFormatter().string(from: Date())
        ])
        prune(to: limitBytes)
        return file
    }

    /// Moves a frame to the label the user says it really was, and writes that down.
    ///
    /// A warning the user calls a false alarm is the most useful picture there is: it is exactly what
    /// the recogniser got wrong, filed as what it should have said. Passing nil means "it was right",
    /// and then only the confirmation is recorded.
    static func refile(frame: URL, as label: Label?) {
        let was = frame.deletingLastPathComponent().lastPathComponent
        guard FileManager.default.fileExists(atPath: frame.path) else { return }
        var moved = frame
        if let label, label.rawValue != was {
            let folder = root.appendingPathComponent(label.rawValue, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(frame.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: frame, to: destination)
                moved = destination
            } catch {
                return
            }
        }
        appendIndex([
            "file": "\(moved.deletingLastPathComponent().lastPathComponent)/\(moved.lastPathComponent)",
            "label": label?.rawValue ?? was,
            "confirmedBy": "user",
            "wasGuessed": was,
            "at": ISO8601DateFormatter().string(from: Date())
        ])
    }

    /// Klatki, na których wolno oprzeć rozpoznawanie.
    ///
    /// Nazwa katalogu nie jest dowodem. Stare zapisy sprzed pola `labelSource` też nie: ostrzeżenia
    /// zapisywały wtedy swoją własną zgadywankę tym samym znacznikiem co ręczne oznaczenie, więc nie
    /// da się ich odróżnić i żadne z nich nie wchodzi do banku. Widać po czym: na tej flocie dziewięć
    /// takich „spaghetti" to czarne klatki z MINI, na które ostrzeżenie samo się nabrało.
    ///
    /// Wchodzą dwie rzeczy: to, co człowiek nazwał lub potwierdził, i to, co Gantry zebrało samo jako
    /// „idzie dobrze" (`automatic`). To drugie nie jest zgadywaniem o wpadce, tylko cichą obserwacją
    /// spokojnego wydruku, a bez niego bank nie ma się z czym porównywać i nie potrafi nikogo oskarżyć.
    /// Przez jakiś czas było wykluczone razem z resztą i wtedy ze stu szesnastu klatek użytkownika do
    /// banku nie trafiała ani jedna.
    static func trustedFiles(from root: URL) -> Set<String> {
        guard let data = try? String(contentsOf: root.appendingPathComponent("index.jsonl"), encoding: .utf8) else { return [] }
        var reviewed = Set<String>()
        for line in data.split(separator: "\n") {
            guard let bytes = String(line).data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  let file = row["file"] as? String else { continue }
            let source = row["labelSource"] as? String
            if row["confirmedBy"] as? String == "user" || source == "user" || source == "automatic" {
                reviewed.insert(file)
            } else {
                reviewed.remove(file)
            }
        }
        return reviewed
    }

    static func stats() -> Stats {
        var stats = Stats()
        for (url, size, _) in frames() {
            stats.frames += 1
            stats.bytes += size
            let label = url.deletingLastPathComponent().lastPathComponent
            stats.byLabel[label, default: 0] += 1
        }
        return stats
    }

    /// Frees room by dropping the oldest frames, correct prints before failures.
    static func prune(to limitBytes: Int64) {
        var all = frames()
        var total = all.reduce(Int64(0)) { $0 + $1.1 }
        guard total > limitBytes else { return }
        all.sort { left, right in
            let leftOK = left.0.deletingLastPathComponent().lastPathComponent == Label.ok.rawValue
            let rightOK = right.0.deletingLastPathComponent().lastPathComponent == Label.ok.rawValue
            if leftOK != rightOK { return leftOK }
            return left.2 < right.2
        }
        for (url, size, _) in all {
            guard total > limitBytes else { break }
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    /// Every saved frame with its size and age.
    private static func frames() -> [(URL, Int64, Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return []
        }
        var found: [(URL, Int64, Date)] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "jpg" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            found.append((url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast))
        }
        return found
    }

    /// One line of JSON per frame: a format a trainer can read line by line without loading the lot.
    private static func appendIndex(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry.compactMapValues { value in
            value is NSNull ? nil : value
        }) else { return }
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: indexFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: indexFile, options: .atomic)
        }
    }
}
