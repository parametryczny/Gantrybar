import AppKit

/// The Gantry brand marks as ready-made images, decoded from the base64 PNGs in `GantryAssets`
/// (rendered from the corrected SVGs). The "G" is a menu-bar template; the "GANTRY" wordmark is white
/// for the dark dashboard header.
enum GantryLogo {
    private static func image(_ base64: String) -> NSImage {
        guard let data = Data(base64Encoded: base64), let image = NSImage(data: data) else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        return image
    }

    private static func sized(_ image: NSImage, height: CGFloat) -> NSImage {
        let copy = image.copy() as! NSImage
        let aspect = image.size.width / max(1, image.size.height)
        copy.size = NSSize(width: height * aspect, height: height)
        return copy
    }

    private static let gImage = image(GantryAssets.gBlackPNG)
    private static let wordmarkImageBase = image(GantryAssets.wordmarkWhitePNG)

    /// The "G" as a menu-bar template image (the bar tints it for light/dark).
    ///
    /// A colour turns it into a plain image painted in that colour instead: the template has to be
    /// given up to keep one, because the bar paints a template black or white to match itself.
    /// Setting the button's `contentTintColor` looks like the easy way and is a trap: once set, even
    /// back to nil, the bar stops adapting the template and the mark goes near-black on a dark bar.
    static func statusItemImage(height: CGFloat = 18, tint: NSColor? = nil) -> NSImage {
        let image = sized(gImage, height: height)
        guard let tint else {
            image.isTemplate = true
            return image
        }
        let painted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        painted.isTemplate = false
        return painted
    }

    /// The white "GANTRY" wordmark, sized for the dark dashboard header.
    static func wordmarkImage(height: CGFloat, color: NSColor = .white) -> NSImage {
        sized(wordmarkImageBase, height: height)
    }
}
