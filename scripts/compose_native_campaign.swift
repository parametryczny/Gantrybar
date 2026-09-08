// Editorial composition only: application pixels are unmodified exports from render_native_campaign.swift.
import AppKit

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let target = URL(fileURLWithPath: CommandLine.arguments[2])
let width = 2800, height = 1950
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let ink = NSColor(calibratedWhite: 0.045, alpha: 1)
let cream = NSColor(calibratedRed: 0.93, green: 0.914, blue: 0.874, alpha: 1)
let muted = NSColor(calibratedWhite: 0.62, alpha: 1)
let orange = NSColor(calibratedRed: 0.96, green: 0.36, blue: 0.17, alpha: 1)
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: CGFloat(height) - y - h, width: w, height: h)
}
func fill(_ r: NSRect, _ color: NSColor) { color.setFill(); r.fill() }
func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
          _ color: NSColor = .white, _ weight: NSFont.Weight = .regular) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    (string as NSString).draw(at: NSPoint(x: x, y: CGFloat(height) - y - font.ascender),
        withAttributes: [.font: font, .foregroundColor: color])
}
@discardableResult func asset(_ name: String, _ box: NSRect, shadow: Bool = false) -> NSRect {
    let img = NSImage(contentsOf: base.appendingPathComponent(name))!
    let factor = min(box.width / img.size.width, box.height / img.size.height)
    let size = NSSize(width: img.size.width * factor, height: img.size.height * factor)
    let dest = NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                      width: size.width, height: size.height)
    NSGraphicsContext.saveGraphicsState()
    if shadow {
        let shade = NSShadow(); shade.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shade.shadowOffset = NSSize(width: 0, height: -14); shade.shadowBlurRadius = 30; shade.set()
    }
    img.draw(in: dest)
    NSGraphicsContext.restoreGraphicsState()
    return dest
}
fill(rect(0, 0, 2800, 1950), ink)
text("GANTRY", 82, 57, 39, .white, .black)
text("ONE FLEET. TWO MODES.", 78, 125, 100, .white, .semibold)
text("macOS  ·  Windows  ·  Linux", 1930, 72, 32, cream, .medium)
text("Your printers. In a popover or a desktop window.", 82, 255, 32, muted)
fill(rect(0, 333, 2800, 8), cream)
fill(rect(1396, 341, 8, 1060), cream)
NSGradient(starting: NSColor(calibratedWhite: 0.085, alpha: 1), ending: ink)!
    .draw(in: rect(0, 341, 1396, 1060), angle: -70)
NSGradient(starting: ink, ending: NSColor(calibratedRed: 0.09, green: 0.065, blue: 0.05, alpha: 1))!
    .draw(in: rect(1404, 341, 1396, 1060), angle: -30)
text("01 / POPOVER", 82, 386, 31, cream, .semibold)
text("02 / DESKTOP WINDOW", 1482, 386, 31, cream, .semibold)
// The system glass frame cannot be captured faithfully by AppKit's offscreen cache on macOS 27.
// Use the exact content export instead of fabricating a replacement OS frame.
let pop = asset("macos-popover-content.png", rect(82, 513, 1230, 811), shadow: true)
// This is the app's actual status-button export, not a fabricated OS menu bar or tray.
let iconY = CGFloat(height) - pop.maxY - 56
asset("gantry-menu-icon.png", rect(pop.minX + 10, iconY, 52, 42))
text("Gantry menu-bar icon", pop.minX + 81, iconY + 3, 25, muted)
asset("macos-window.png", rect(1476, 507, 1250, 824), shadow: true)
text("Popover content · opened from the menu-bar icon.", 82, 1336, 27, muted)
text("Native controls. Freely resizable.", 1482, 1336, 27, muted)
fill(rect(0, 1401, 2800, 8), cream)
fill(rect(0, 1409, 1800, 471), cream)
text("ONE CLICK TO SWITCH.", 82, 1452, 56, ink, .semibold)
text("The real control from the window header.", 82, 1530, 28, ink)
let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("window-toggle.json"))) as! [String: Double]
let toolbar = NSImage(contentsOf: base.appendingPathComponent("macos-window.png"))!
toolbar.size = NSSize(width: 730, height: 520)
let src = NSRect(x: max(0, meta["width"]! - 212), y: 0, width: 212, height: meta["height"]!)
let dst = rect(82, 1600, 1272, 216)
fill(dst, NSColor(calibratedWhite: 0.16, alpha: 1))
// Crop the actual host screenshot so the real header backing is preserved as well as its controls.
toolbar.draw(in: dst, from: NSRect(x: src.minX + 10, y: 520 - 34 - 36,
    width: src.width, height: src.height), operation: .sourceOver, fraction: 1)
let center = NSPoint(x: dst.minX + (meta["x"]! - src.minX) * 6,
                     y: dst.minY + meta["y"]! * 6)
orange.setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 75, y: center.y - 75, width: 150, height: 150))
ring.lineWidth = 4; ring.stroke()
let line = NSBezierPath(); line.move(to: NSPoint(x: center.x + 77, y: center.y - 55))
line.line(to: NSPoint(x: 1380, y: center.y - 55)); line.line(to: NSPoint(x: 1380, y: center.y + 12))
line.lineWidth = 2; line.stroke()
text("Popover", 1410, 1623, 35, ink, .medium)
text("↕", 1459, 1668, 36, ink)
text("Window", 1410, 1713, 35, ink, .medium)
text("SAME APP.", 1882, 1477, 61, .white, .semibold)
text("YOUR WAY.", 1882, 1550, 61, .white, .semibold)
text("Actual interface, rendered from source.", 1882, 1660, 29, muted)
text("No AI-generated application UI.", 1882, 1706, 29, muted)
text("LOCAL. FAST. PRIVATE.", 1882, 1790, 27, cream, .medium)
text("Native macOS interface shown · Demonstration printer data", 82, 1904, 24, muted)
text("GANTRY / 2026", 2490, 1904, 23, muted)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: target)
print(target.path)
