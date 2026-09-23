import Testing
import AppKit
import Foundation
@testable import Gantry

/// Recognising a failure by comparison: the part that has to work before any of it is worth showing.
/// Built on pictures that differ the way camera frames differ, not on noise.
@MainActor @Suite(.serialized) struct DefectPrototypesTests {
    private func picture(_ draw: (NSRect) -> Void, size: CGFloat = 200) -> Data {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.darkGray.setFill()
        rect.fill()
        draw(rect)
        image.unlockFocus()
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [:])!
    }

    /// A tidy print: one solid block in the middle, jittered a little between frames.
    private func tidy(_ offset: CGFloat) -> Data {
        picture { rect in
            NSColor.systemGreen.setFill()
            NSRect(x: rect.midX - 40 + offset, y: rect.midY - 40, width: 80, height: 80).fill()
        }
    }

    /// A mess: thin strands all over the frame.
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

    private func dataset(root: URL, ok: [Data], spaghetti: [Data]) throws {
        for (label, frames) in [("ok", ok), ("spaghetti", spaghetti)] {
            let folder = root.appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, frame) in frames.enumerated() {
                try frame.write(to: folder.appendingPathComponent("frame-\(index).jpg"))
            }
        }
    }

    // MARK: Comparing

    @Test func markedFramesRecogniseTheNextOneOfTheirKind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-proto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try dataset(root: root,
                    ok: [tidy(0), tidy(4), tidy(-4), tidy(8)],
                    spaghetti: [mess(1), mess(2), mess(3), mess(4)])

        // The shipped bank is left out on purpose: this is about the user's own frames.
        let prototypes = DefectPrototypes.build(from: root, starter: [])
        #expect(prototypes.count == 8, "every marked frame counts, not one average per class")
        #expect(DefectPrototypes.tally(prototypes) == (labels: 2, mine: 8))

        let onMess = DefectPrototypes.match(jpeg: mess(9), against: prototypes)
        let onTidy = DefectPrototypes.match(jpeg: tidy(2), against: prototypes)
        #expect(onMess?.label == "spaghetti", "a messy frame was not recognised: \(onMess?.label ?? "nil")")
        #expect(onTidy?.label == "ok", "a tidy frame was not recognised: \(onTidy?.label ?? "nil")")
        #expect((onMess?.confidence ?? 0) > 0.5, "a correct call should read as more than a coin toss")
    }

    @Test func oneClassOnHandMeansNoOpinion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-proto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try dataset(root: root, ok: [], spaghetti: [mess(1), mess(2), mess(3)])
        let prototypes = DefectPrototypes.build(from: root, starter: [])
        // With nothing to be closer *than*, "closest to spaghetti" says nothing at all, and calling
        // every frame spaghetti is exactly the failure mode worth refusing.
        #expect(DefectPrototypes.match(jpeg: tidy(0), against: prototypes) == nil)
    }

    @Test func nothingMarkedAndNothingShippedMeansNoOpinion() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-proto-\(UUID().uuidString)")
        #expect(DefectPrototypes.build(from: root, starter: []).isEmpty)
        #expect(DefectPrototypes.match(jpeg: tidy(0), against: []) == nil)
    }

    // MARK: The shipped bank

    /// Whichever of the two shipped banks this Mac's Vision revision can actually use.
    private func shippedBankFile() throws -> URL {
        try #require(DefectPrototypes.starterFile(),
                     "no defect-starter bank found; run scripts/build_defect_starter.py")
    }

    @Test func theShippedBankHoldsFailuresOnly() throws {
        let bank = DefectPrototypes.decode(try Data(contentsOf: try shippedBankFile()))
        #expect(bank.prototypes.count > 30, "a bank this small could not stand for a class")
        // Spaghetti only, on purpose. See `theShippedBankAloneNeverAccusesAnything`.
        #expect(Set(bank.prototypes.map(\.label)) == ["spaghetti"])
        #expect(bank.prototypes.allSatisfy { !$0.mine }, "shipped frames must not be counted as the user's")
        #expect(bank.scale > 0, "without a scale a distance cannot become a confidence")
    }

    /// The property that matters most in this whole feature, and the one whose absence shipped a bug.
    ///
    /// Gantry used to ship a "this is fine" class too, built from openly licensed photographs of
    /// printers. They were daylight pictures of whole machines on desks, while the spaghetti frames
    /// were close-ups from inside a chamber, so the two classes were really "outdoors" and "inside a
    /// printer" and any real camera frame landed on the wrong one. A perfectly good print came back
    /// as spaghetti at full confidence.
    ///
    /// Nothing can stand for "normal on this printer" except this printer, so the shipped bank now
    /// holds one class and one class cannot accuse anybody: with nothing to be closer *than*, there
    /// is no opinion to give. The second class arrives from the user's own camera.
    @Test func theShippedBankAloneNeverAccusesAnything() throws {
        let bank = DefectPrototypes.decode(try Data(contentsOf: try shippedBankFile()))
        for frame in [tidy(0), tidy(6), mess(3), mess(11)] {
            let guess = DefectPrototypes.match(jpeg: frame, against: bank.prototypes, scale: bank.scale)
            #expect(guess == nil, "the shipped bank on its own must not judge: it said \(guess?.label ?? "")")
        }
    }

    @Test func theUsersOwnFramesAreWhatTurnTheShippedBankOn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-proto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try dataset(root: root, ok: [tidy(0), tidy(4), tidy(-4)], spaghetti: [])

        let bank = DefectPrototypes.decode(try Data(contentsOf: try shippedBankFile()))
        let together = DefectPrototypes.build(from: root, starter: bank.prototypes)
        #expect(Set(together.map(\.label)) == ["ok", "spaghetti"], "two classes only once the user has one")
        // And now a frame from the same camera as those "fine" frames is recognised as fine, which is
        // the whole point of taking the negatives from the user's own printer.
        let guess = DefectPrototypes.match(jpeg: tidy(2), against: together, scale: bank.scale)
        #expect(guess?.label == "ok", "a frame like the user's own good frames was called \(guess?.label ?? "nil")")
    }

    @Test func aDamagedBankIsIgnoredRatherThanTrusted() throws {
        let good = try Data(contentsOf: try shippedBankFile())
        #expect(DefectPrototypes.decode(Data()).prototypes.isEmpty)
        #expect(DefectPrototypes.decode(Data("not a bank at all, just some bytes".utf8)).prototypes.isEmpty)
        // Cut off mid-prototype: what was read stays, the rest is not invented.
        let truncated = DefectPrototypes.decode(good.prefix(good.count / 2)).prototypes
        #expect(truncated.count < DefectPrototypes.decode(good).prototypes.count)
        // A file claiming another feature print revision holds numbers that are not comparable with
        // anything this Mac computes, so it must be refused rather than half-believed.
        var wrongRevision = Data(good)
        wrongRevision.replaceSubrange(12..<16, with: withUnsafeBytes(of: UInt32(99)) { Data($0) })
        #expect(DefectPrototypes.decode(wrongRevision).prototypes.isEmpty)
    }

}
