import AppKit

/// The PrismBar mark — a fan of blades — drawn from vector coordinates so it renders crisply at any
/// size. Used as the menu-bar status item image (as a template, so it adapts to light/dark menu bars).
enum PrismBarLogo {
    // Front-face polygons of the mark in a 400×400 design space (y grows downward, as in the SVG).
    private static let polygons: [[CGPoint]] = [
        [(197, 55), (119, 212), (188, 195)],
        [(203, 55), (193, 193), (263, 182)],
        [(115, 225), (268, 195), (303, 263), (92, 272)],
        [(81, 285), (51, 345), (175, 345)],
        [(100, 276), (303, 268), (282, 345), (182, 345)],
        [(315, 272), (288, 345), (345, 345)],
    ].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }

    // Tight bounds of the mark within the 400×400 space.
    private static let bounds = CGRect(x: 51, y: 55, width: 345 - 51, height: 345 - 55)

    /// A template image of the mark sized to the menu bar height (menu bar tints it for light/dark).
    static func statusItemImage(height: CGFloat = 18) -> NSImage {
        let image = drawImage(height: height) { NSColor.black.setFill() }
        image.isTemplate = true
        return image
    }

    /// A solid-colour image of the mark — used where the background is fixed (e.g. the dark panel
    /// header), so the mark shows in that colour rather than being tinted by the menu bar.
    static func filledImage(height: CGFloat, color: NSColor) -> NSImage {
        drawImage(height: height) { color.setFill() }
    }

    private static func drawImage(height: CGFloat, setFill: @escaping () -> Void) -> NSImage {
        let scale = height / bounds.height
        let size = NSSize(width: bounds.width * scale, height: height)
        return NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
            setFill()
            for polygon in polygons {
                let path = NSBezierPath()
                path.move(to: polygon[0])
                for point in polygon.dropFirst() { path.line(to: point) }
                path.close()
                path.fill()
            }
            return true
        }
    }
}
