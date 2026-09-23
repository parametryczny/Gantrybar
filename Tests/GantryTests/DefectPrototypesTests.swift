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

    @Test func theShippedBankIsThereAndHoldsBothKinds() throws {
        let bank = DefectPrototypes.decode(try Data(contentsOf: try shippedBankFile()))
        #expect(bank.prototypes.count > 50, "a bank this small could not stand for a class")
        #expect(Set(bank.prototypes.map(\.label)) == ["ok", "spaghetti"])
        #expect(bank.prototypes.allSatisfy { !$0.mine }, "shipped frames must not be counted as the user's")
        #expect(bank.scale > 0, "without a scale a distance cannot become a confidence")
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

    /// The shipped bank, asked about its own frames with each one taken out of the bank first.
    ///
    /// This is not the accuracy figure, and it is deliberately a low bar. The bank keeps the most
    /// spread-out frames of each class on purpose, so every one of them is the least typical picture
    /// available and this is the worst question that can be asked of it. What the test catches is a
    /// file that shipped scrambled, with its labels off by one or its floats read the wrong way
    /// round: two balanced classes would then land at chance, and a bank that loads, decodes and
    /// answers confidently while meaning nothing is exactly the thing worth failing the build over.
    /// The real figure was measured while building the file, on photographs from sources that
    /// contributed nothing to it, and is written down in `docs/defect-starter-attribution.md`.
    @Test func theShippedBankAgreesWithItself() throws {
        let bank = DefectPrototypes.decode(try Data(contentsOf: try shippedBankFile()))
        var right = 0
        for (index, prototype) in bank.prototypes.enumerated() {
            var rest = bank.prototypes
            rest.remove(at: index)
            let guess = DefectPrototypes.classify(vector: DefectPrototypes.vector(of: prototype),
                                                  against: rest, scale: bank.scale)
            if guess?.label == prototype.label { right += 1 }
        }
        let share = Double(right) / Double(bank.prototypes.count)
        #expect(share > 0.65, "the shipped bank is no better than chance about itself: \(Int(share * 100))% of the time (\(right)/\(bank.prototypes.count))")
    }
}
