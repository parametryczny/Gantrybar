import Testing
import AppKit
import Foundation
@testable import Gantry

/// Trying the recogniser on a picture from disk, which is the only way to find out whether any of
/// this works without waiting for a print to fail.
@MainActor @Suite(.serialized) struct DefectTrialTests {
    private func picture(_ draw: (NSRect) -> Void) -> Data {
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: 200, height: 200)
        NSColor.darkGray.setFill()
        rect.fill()
        draw(rect)
        image.unlockFocus()
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [:])!
    }

    private func tidy(_ offset: CGFloat) -> Data {
        picture { rect in
            NSColor.systemGreen.setFill()
            NSRect(x: rect.midX - 40 + offset, y: rect.midY - 40, width: 80, height: 80).fill()
        }
    }

    private func mess(_ seed: Int) -> Data {
        picture { rect in
            NSColor.systemOrange.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 3
            for step in 0..<40 {
                let x = CGFloat((step * 37 + seed * 11) % Int(rect.width))
                let y = CGFloat((step * 61 + seed * 7) % Int(rect.height))
                path.move(to: NSPoint(x: x, y: y))
                path.line(to: NSPoint(x: rect.width - x, y: rect.height - y))
            }
            path.stroke()
        }
    }

    /// A folder of marked frames plus the file to be judged.
    private func bench(ok: [Data], spaghetti: [Data]) throws -> (root: URL, prototypes: [DefectPrototypes.Prototype]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-trial-\(UUID().uuidString)")
        for (label, frames) in [("ok", ok), ("spaghetti", spaghetti)] {
            let folder = root.appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, frame) in frames.enumerated() {
                try frame.write(to: folder.appendingPathComponent("frame-\(index).jpg"))
            }
        }
        return (root, DefectPrototypes.build(from: root, starter: []))
    }

    private func onDisk(_ jpeg: Data, name: String = "trial.jpg") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gantry-trial-\(UUID().uuidString)-\(name)")
        try jpeg.write(to: url)
        return url
    }

    @Test func aPictureOfAMessWouldRaiseAWarning() throws {
        let (root, prototypes) = try bench(ok: [tidy(0), tidy(4), tidy(-4)], spaghetti: [mess(1), mess(2), mess(3)])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try onDisk(mess(9))
        defer { try? FileManager.default.removeItem(at: file) }

        let verdict = try DefectTrial.judge(imageAt: file, prototypes: prototypes, threshold: 0.6)
        #expect(verdict.label == "spaghetti")
        #expect(verdict.raisesAlarm, "a clear mess should be reported as something that would warn")
        #expect(verdict.comparedAgainst == 6)
        #expect(verdict.mine == 6, "frames from the user's folder must be counted as theirs")
        #expect(!verdict.jpeg.isEmpty, "the sheet shows the picture that was judged")
    }

    @Test func aTidyPrintIsNotReportedAsAFailure() throws {
        let (root, prototypes) = try bench(ok: [tidy(0), tidy(4), tidy(-4)], spaghetti: [mess(1), mess(2), mess(3)])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try onDisk(tidy(2))
        defer { try? FileManager.default.removeItem(at: file) }

        let verdict = try DefectTrial.judge(imageAt: file, prototypes: prototypes, threshold: 0.6)
        #expect(verdict.label == "ok")
        #expect(verdict.raisesAlarm == false)
    }

    @Test func aGuessBelowTheSensitivityIsShownButDoesNotCountAsAWarning() throws {
        let (root, prototypes) = try bench(ok: [tidy(0), tidy(4), tidy(-4)], spaghetti: [mess(1), mess(2), mess(3)])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try onDisk(mess(9))
        defer { try? FileManager.default.removeItem(at: file) }

        // Sensitivity wound up past anything reachable: the label still comes back, so the sheet can
        // say "it saw it but was not sure enough", which is the most useful thing it can tell anyone
        // wondering where to put the slider.
        let verdict = try DefectTrial.judge(imageAt: file, prototypes: prototypes, threshold: 1.1)
        #expect(verdict.label == "spaghetti")
        #expect(verdict.raisesAlarm == false)
        #expect(verdict.threshold == 1.1, "the sheet reports the sensitivity it judged against")
    }

    @Test func aFileThatIsNotAPictureIsRefusedWithAReason() throws {
        let file = try onDisk(Data("to nie jest obraz".utf8), name: "notes.txt")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: DefectTrial.Failure.self) {
            try DefectTrial.judge(imageAt: file, prototypes: [], threshold: 0.7)
        }
    }

    @Test func nothingToCompareAgainstIsSaidPlainlyRatherThanGuessed() throws {
        let file = try onDisk(mess(1))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: DefectTrial.Failure.self) {
            try DefectTrial.judge(imageAt: file, prototypes: [], threshold: 0.7)
        }
    }

    @Test func theHeadlineSaysWhichOfTheThreeThingsHappened() {
        let base = DefectTrial.Verdict(jpeg: Data([0xFF]), label: nil, confidence: 0, raisesAlarm: false,
                                       threshold: 0.7, comparedAgainst: 10, mine: 0, modelName: nil)
        var healthy = base; healthy.label = "ok"; healthy.confidence = 0.9
        var warning = base; warning.label = "spaghetti"; warning.confidence = 0.9; warning.raisesAlarm = true
        var unsure = base; unsure.label = "spaghetti"; unsure.confidence = 0.55
        // Three different answers, three different sentences: an empty one would read as "fine".
        let lines = [base, healthy, warning, unsure].map(DefectTrial.headline)
        #expect(Set(lines).count == 4)
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(DefectTrial.detail(warning).contains("90"), "the certainty belongs in the detail line")
        #expect(DefectTrial.detail(warning).contains("\n"), "the caveat sits on its own line")
    }

    // MARK: The same answer wherever it is asked

    @Test func aFrameInHandIsJudgedTheSameAsTheSameFrameOnDisk() throws {
        let (root, prototypes) = try bench(ok: [tidy(0), tidy(4), tidy(-4)], spaghetti: [mess(1), mess(2), mess(3)])
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = mess(9)
        let file = try onDisk(frame)
        defer { try? FileManager.default.removeItem(at: file) }

        // Settings judges a file the user picked; Details judges what the camera is showing right
        // now. Two places must never start answering the same question differently.
        let fromDisk = try DefectTrial.judge(imageAt: file, prototypes: prototypes, threshold: 0.6)
        let inHand = try DefectTrial.judge(jpeg: frame, prototypes: prototypes, threshold: 0.6)
        #expect(fromDisk.label == inHand.label)
        #expect(fromDisk.raisesAlarm == inHand.raisesAlarm)
    }

    @Test func theSheetSaysWhichPrinterItIsAbout() throws {
        let (root, prototypes) = try bench(ok: [tidy(0), tidy(4), tidy(-4)], spaghetti: [mess(1), mess(2), mess(3)])
        defer { try? FileManager.default.removeItem(at: root) }
        let verdict = try DefectTrial.judge(jpeg: mess(9), prototypes: prototypes, threshold: 0.6)
        let sheet = DefectTrial.sheet(for: verdict, title: "X1")
        #expect(sheet.messageText.hasPrefix("X1"), "asked about one printer, the answer must name it")
        #expect(sheet.accessoryView != nil, "the sheet shows the frame that was judged")
        #expect(DefectTrial.sheet(for: verdict).messageText.hasPrefix("X1") == false)
    }


    // MARK: Gantry Vision, the engine that ships

    @Test func gantryVisionIsThereAndAnswersWithoutAnybodyChoosingAFile() throws {
        let path = try #require(DefectModel.bundledPath,
                                "Resources/GantryVisionPrintFailure.mlpackage is missing")
        // Nothing chosen means Gantry Vision: the whole point of shipping it.
        #expect(DefectModel.effectivePath(chosen: "") == path)
        #expect(DefectModel.effectivePath(chosen: "/tmp/mine.mlpackage") == "/tmp/mine.mlpackage")

        let verdict = try DefectTrial.judge(jpeg: tidy(0), threshold: 0.7)
        #expect(verdict.label != nil, "the shipped engine has to answer")
        #expect(verdict.modelName == "Gantry Vision", "the sheet shows the model's own name")
        #expect(verdict.comparedAgainst == 0, "a model does not compare against reference frames")
    }
}
