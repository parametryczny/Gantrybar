import Testing
import AppKit
@testable import Gantry

/// Learning from marked frames without training anything: the part that has to work before any of it
/// is worth showing. Built on pictures that differ the way camera frames differ, not on noise.
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

    @Test func threeMarkedFramesOfAKindAreEnoughToRecogniseTheNextOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-proto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try dataset(root: root,
                    ok: [tidy(0), tidy(4), tidy(-4), tidy(8)],
                    spaghetti: [mess(1), mess(2), mess(3), mess(4)])

        let prototypes = DefectPrototypes.build(from: root)
        #expect(prototypes.count == 2, "both classes should have a prototype")

        // A frame of each kind that was not in the training folder.
        let onMess = DefectPrototypes.match(jpeg: mess(9), against: prototypes)
        let onTidy = DefectPrototypes.match(jpeg: tidy(2), against: prototypes)
        #expect(onMess?.label == "spaghetti", "a messy frame was not recognised: \(onMess?.label ?? "nil")")
        #expect(onTidy?.label == "ok", "a tidy frame was not recognised: \(onTidy?.label ?? "nil")")
    }

    @Test func aClassWithTooFewFramesIsNotPretendedToBeLearned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-proto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try dataset(root: root, ok: [tidy(0), tidy(3), tidy(6)], spaghetti: [mess(1), mess(2)])

        let prototypes = DefectPrototypes.build(from: root)
        #expect(prototypes.map(\.label) == ["ok"], "two frames were treated as a learned class")
    }

    @Test func nothingMarkedMeansNoOpinion() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-proto-\(UUID().uuidString)")
        #expect(DefectPrototypes.build(from: root).isEmpty)
        #expect(DefectPrototypes.match(jpeg: tidy(0), against: []) == nil)
    }
}
