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

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Gantry/dataset", isDirectory: true)
    }

    nonisolated static var indexFile: URL { root.appendingPathComponent("index.jsonl") }

    /// Saves one frame under its label, with everything a trainer would want to know about it.
    @discardableResult
    static func save(jpeg: Data, label: Label, printer: SavedPrinter, telemetry: PrinterTelemetry,
                     limitBytes: Int64 = defaultLimitBytes) throws -> URL {
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
            "at": ISO8601DateFormatter().string(from: Date())
        ])
        prune(to: limitBytes)
        return file
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
