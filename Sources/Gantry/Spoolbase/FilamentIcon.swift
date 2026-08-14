import AppKit

enum FilamentIcon {
    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width, y: rect.height)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(0.075)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            // Zewnętrzna nitka ze swobodnym końcem — znak nawiązujący do załączonego wzoru.
            context.beginPath()
            context.move(to: CGPoint(x: 0.71, y: 0.07))
            context.addCurve(to: CGPoint(x: 0.19, y: 0.47), control1: CGPoint(x: 0.39, y: 0.10), control2: CGPoint(x: 0.17, y: 0.24))
            context.addCurve(to: CGPoint(x: 0.51, y: 0.88), control1: CGPoint(x: 0.20, y: 0.74), control2: CGPoint(x: 0.32, y: 0.88))
            context.addCurve(to: CGPoint(x: 0.83, y: 0.57), control1: CGPoint(x: 0.73, y: 0.89), control2: CGPoint(x: 0.85, y: 0.76))
            context.addCurve(to: CGPoint(x: 0.60, y: 0.28), control1: CGPoint(x: 0.81, y: 0.39), control2: CGPoint(x: 0.70, y: 0.29))
            context.strokePath()

            // Wewnętrzne zwoje szpuli.
            context.beginPath()
            context.addEllipse(in: CGRect(x: 0.30, y: 0.31, width: 0.47, height: 0.47))
            context.strokePath()
            context.beginPath()
            context.addEllipse(in: CGRect(x: 0.37, y: 0.38, width: 0.33, height: 0.33))
            context.strokePath()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }
}
