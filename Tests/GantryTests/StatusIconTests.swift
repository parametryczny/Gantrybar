import Testing
import AppKit
@testable import Gantry

/// The menu-bar mark in its two states. Reported 2026-09-21: the "G" went near-black on a dark bar,
/// because tinting through the button's contentTintColor stops the bar from adapting the template.
@MainActor @Suite struct StatusIconTests {
    /// The strongest colour in the drawn mark, ignoring anything transparent.
    private func boldestPixel(of image: NSImage) -> NSColor? {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return nil }
        var best: NSColor?
        var bestAlpha: CGFloat = 0.5
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if colour.alphaComponent > bestAlpha {
                    bestAlpha = colour.alphaComponent
                    best = colour
                }
            }
        }
        return best
    }

    @Test func theRestingMarkStaysATemplateSoTheBarCanAdaptIt() {
        let resting = GantryLogo.statusItemImage(height: 14)
        #expect(resting.isTemplate, "a mark that is not a template is painted black on a dark menu bar")
    }

    @Test func theAwakeMarkIsReallyBlue() {
        let awake = GantryLogo.statusItemImage(height: 14, tint: .systemBlue)
        #expect(awake.isTemplate == false, "a template ignores its colour: the bar repaints it")
        guard let colour = boldestPixel(of: awake) else {
            Issue.record("the tinted mark drew nothing")
            return
        }
        #expect(colour.blueComponent > 0.5)
        #expect(colour.blueComponent > colour.redComponent + 0.2)
        #expect(colour.blueComponent > colour.greenComponent + 0.2)
    }
}
