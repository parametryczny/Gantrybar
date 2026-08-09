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
    static func statusItemImage(height: CGFloat = 18) -> NSImage {
        let img = sized(gImage, height: height)
        img.isTemplate = true
        return img
    }

    /// The white "GANTRY" wordmark, sized for the dark dashboard header.
    static func wordmarkImage(height: CGFloat, color: NSColor = .white) -> NSImage {
        sized(wordmarkImageBase, height: height)
    }
}
