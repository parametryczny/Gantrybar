import Testing
import AppKit
@testable import Gantry

/// The pictures Gantry keeps for training: that they land under their label, carry what the print was
/// doing, and that the folder cannot quietly eat a disk.
@MainActor @Suite(.serialized) struct DefectDatasetTests {
    private func printer() -> SavedPrinter {
        SavedPrinter(serial: "TEST-1", name: "X1", host: "127.0.0.1")
    }

    /// A small valid JPEG, so the sizes in the test are real bytes and not a placeholder.
    private func frame(pixels: Int = 40) -> Data {
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        NSColor.orange.drawSwatch(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        image.unlockFocus()
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [:])!
    }

    private func clean() {
        try? FileManager.default.removeItem(at: DefectDataset.root)
    }

    @Test func aMarkedFrameLandsUnderItsLabelWithWhatThePrintWasDoing() throws {
        clean()
        defer { clean() }
        var telemetry = PrinterTelemetry()
        telemetry.jobName = "zatyczka"
        telemetry.progress = 42
        telemetry.currentLayer = 17
        let url = try DefectDataset.save(jpeg: frame(), label: .spaghetti, printer: printer(), telemetry: telemetry)

        #expect(url.deletingLastPathComponent().lastPathComponent == "spaghetti")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let index = try String(contentsOf: DefectDataset.indexFile, encoding: .utf8)
        #expect(index.contains("\"label\":\"spaghetti\""))
        #expect(index.contains("zatyczka"), "the index does not say what was printing")
        #expect(index.contains("\"layer\":17"))

        let stats = DefectDataset.stats()
        #expect(stats.frames == 1)
        #expect(stats.byLabel["spaghetti"] == 1)
        #expect(stats.bytes > 0)
    }

    /// The answer to a warning is what makes the next one better, so a false alarm has to end up
    /// filed as what it really was, and be visible in the index as the user's own word.
    @Test func aFalseAlarmIsRefiledUnderWhatItReallyWas() throws {
        clean()
        defer { clean() }
        let url = try DefectDataset.save(jpeg: frame(), label: .spaghetti, printer: printer(),
                                         telemetry: PrinterTelemetry())
        DefectDataset.refile(frame: url, as: .ok)

        #expect(FileManager.default.fileExists(atPath: url.path) == false, "the frame stayed under the wrong label")
        let stats = DefectDataset.stats()
        #expect(stats.byLabel["ok"] == 1)
        #expect(stats.byLabel["spaghetti"] == nil)
        let index = try String(contentsOf: DefectDataset.indexFile, encoding: .utf8)
        #expect(index.contains("\"confirmedBy\":\"user\""))
        #expect(index.contains("\"wasGuessed\":\"spaghetti\""), "the index does not say what was guessed")
    }

    @Test func confirmingAWarningLeavesTheFrameWhereItIs() throws {
        clean()
        defer { clean() }
        let url = try DefectDataset.save(jpeg: frame(), label: .spaghetti, printer: printer(),
                                         telemetry: PrinterTelemetry())
        DefectDataset.refile(frame: url, as: nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(DefectDataset.stats().byLabel["spaghetti"] == 1)
    }

    @Test func theFolderCannotOutgrowItsLimitAndGivesUpCorrectFramesFirst() throws {
        clean()
        defer { clean() }
        let jpeg = frame(pixels: 160)
        for _ in 0..<4 { _ = try DefectDataset.save(jpeg: jpeg, label: .ok, printer: printer(), telemetry: PrinterTelemetry()) }
        let failure = try DefectDataset.save(jpeg: jpeg, label: .spaghetti, printer: printer(), telemetry: PrinterTelemetry())

        // A limit that only two frames fit into: the correct ones must go, the failure must stay.
        DefectDataset.prune(to: Int64(jpeg.count * 2))
        let stats = DefectDataset.stats()
        #expect(stats.bytes <= Int64(jpeg.count * 2))
        #expect(FileManager.default.fileExists(atPath: failure.path), "a real failure was thrown away before an ordinary frame")
        #expect(stats.byLabel["spaghetti"] == 1)
    }
}
