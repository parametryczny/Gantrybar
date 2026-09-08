// Photographic art direction with source-rendered UI. No generated app pixels.
import AppKit

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let ivory = NSColor(calibratedRed: 0.933, green: 0.918, blue: 0.887, alpha: 1)
let black = NSColor(calibratedWhite: 0.035, alpha: 1)
let gray = NSColor(calibratedWhite: 0.64, alpha: 1)
let orange = NSColor(calibratedRed: 0.95, green: 0.36, blue: 0.17, alpha: 1)
var canvasH: CGFloat = 2100
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: canvasH-y-h, width: w, height: h)
}
func fill(_ rect: NSRect, _ color: NSColor) { color.setFill(); rect.fill() }
func label(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
           _ color: NSColor = .white, _ weight: NSFont.Weight = .regular) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    (s as NSString).draw(at: NSPoint(x: x, y: canvasH-y-font.ascender),
        withAttributes: [.font: font, .foregroundColor: color])
}
func bitmap(_ w: Int, _ h: Int, draw: () -> Void) -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    memset(rep.bitmapData!, 0, rep.bytesPerRow*h)
    let oldH = canvasH; canvasH = CGFloat(h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState(); canvasH = oldH
    let img = NSImage(size: NSSize(width: w, height: h)); img.addRepresentation(rep); return img
}
func save(_ image: NSImage, _ url: URL) throws {
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}
func load(_ path: String) -> NSImage { NSImage(contentsOf: base.appendingPathComponent(path))! }
func cinematic(_ img: NSImage) -> NSImage {
    // A uniform photographic black-level/exposure curve, not a UI recoloring or reconstruction.
    let normalized = bitmap(Int(img.size.width),Int(img.size.height)) {
        img.draw(in:r(0,0,img.size.width,img.size.height))
    }
    let rep = normalized.representations[0] as! NSBitmapImageRep
    let p = rep.bitmapData!
    let stops:[Double] = [0,0.10,0.35,0.69,0.98]
    let lut:[UInt8] = (0...255).map { value in
        let pos = Double(value)/255*4
        let i = min(3,Int(pos)); let f = pos-Double(i)
        return UInt8(max(0,min(255,(stops[i]*(1-f)+stops[i+1]*f)*255)))
    }
    for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
        let index = y*rep.bytesPerRow+x*4
        for c in 0..<3 {p[index+c] = lut[Int(p[index+c])]}
    }}
    return normalized
}
@discardableResult func fit(_ image: NSImage, _ rect: NSRect) -> NSRect {
    let s = min(rect.width/image.size.width, rect.height/image.size.height)
    let dest = NSRect(x: rect.midX-image.size.width*s/2, y: rect.midY-image.size.height*s/2,
        width: image.size.width*s, height: image.size.height*s)
    image.draw(in: dest); return dest
}
func cover(_ image: NSImage, _ rect: NSRect, source: NSRect? = nil) {
    let src = source ?? NSRect(origin: .zero, size: image.size)
    let s = max(rect.width/src.width, rect.height/src.height)
    let crop = NSRect(x: src.midX-rect.width/s/2, y: src.midY-rect.height/s/2,
        width: rect.width/s, height: rect.height/s)
    image.draw(in: rect, from: crop, operation: .sourceOver, fraction: 1)
}
let window = cinematic(load("native-source/macos-window.png"))
let popover = cinematic(load("native-source/macos-popover-content.png"))
let icon = load("native-source/gantry-menu-icon.png")
let plate = load("gantry-photo-plate-v5.png")
plate.size = NSSize(width: 1536, height: 1024)
let planeWindow = bitmap(1200, 800) {
    fill(r(0,0,1200,800), NSColor(calibratedWhite: 0.067, alpha: 1))
    fit(window, r(54,34,1092,732))
}
let planePopover = bitmap(1200, 800) {
    NSGradient(starting: NSColor(calibratedWhite: 0.055, alpha: 1),
        ending: NSColor(calibratedRed: 0.10, green: 0.115, blue: 0.135, alpha: 1))!
        .draw(in: r(0,0,1200,800), angle: 25)
    // Show the exact app icon and content, not a fabricated OS menu or taskbar.
    fit(icon, r(1020,25,35,28))
    fit(popover, r(213,65,876,692))
}
func photograph(_ plane: NSImage) -> NSImage {
    // Four active-display corners measured on the blank generated photographic plate.
    // CPU homography keeps this reproducible without a WindowServer or GPU context.
    let pairs:[(Double,Double,Double,Double)] = [(167,128,0,0),(1395,72,1200,0),
        (1425,852,1200,800),(205,953,0,800)]
    var matrix:[[Double]] = []
    for (x,y,u,v) in pairs {
        matrix.append([x,y,1,0,0,0,-u*x,-u*y,u])
        matrix.append([0,0,0,x,y,1,-v*x,-v*y,v])
    }
    for column in 0..<8 {
        let pivot = (column..<8).max {abs(matrix[$0][column]) < abs(matrix[$1][column])}!
        matrix.swapAt(column,pivot)
        let divisor = matrix[column][column]
        for j in column...8 {matrix[column][j] /= divisor}
        for row in 0..<8 where row != column {
            let m = matrix[row][column]
            for j in column...8 {matrix[row][j] -= m*matrix[column][j]}
        }
    }
    let h = matrix.map {$0[8]}
    let result = bitmap(1536,1024) {plate.draw(in:r(0,0,1536,1024))}
    let dst = result.representations[0] as! NSBitmapImageRep
    let src = plane.representations[0] as! NSBitmapImageRep
    let dp = dst.bitmapData!, sp = src.bitmapData!
    for y in 60..<960 {for x in 160..<1430 {
        let xx = Double(x), yy = Double(y)
        let z = h[6]*xx+h[7]*yy+1
        let u = (h[0]*xx+h[1]*yy+h[2])/z, v = (h[3]*xx+h[4]*yy+h[5])/z
        guard u >= 0, v >= 0, u < 1199, v < 799 else {continue}
        let ix = Int(u), iy = Int(v), fx = u-Double(ix), fy = v-Double(iy)
        let at = iy*src.bytesPerRow+ix*4, to = y*dst.bytesPerRow+x*4
        for c in 0..<3 {
            let a = Double(sp[at+c])*(1-fx)+Double(sp[at+4+c])*fx
            let b = Double(sp[at+src.bytesPerRow+c])*(1-fx)+Double(sp[at+src.bytesPerRow+4+c])*fx
            let value = (a*(1-fy)+b*fy)*0.96+Double(dp[to+c])*0.04
            dp[to+c] = UInt8(max(0,min(255,value)))
        }
        dp[to+3] = 255
    }}
    return result
}
let windowShot = photograph(planeWindow)
let popoverShot = photograph(planePopover)
try save(windowShot, base.appendingPathComponent("gantry-window-photo-v5.png"))
try save(popoverShot, base.appendingPathComponent("gantry-popover-photo-v5.png"))

let art = bitmap(3000,2100) {
    fill(r(0,0,3000,2100), ivory)
    // Editorial contact sheet: macro photography, cream copy panels and full product views.
    cover(windowShot, r(0,0,1240,970), source: NSRect(x: 85,y: 310,width: 935,height: 700))
    fill(r(1254,0,816,970), ivory)
    label("GANTRY",1305,54,35,black,.black)
    label("ONE FLEET.",1305,154,81,black,.semibold)
    label("TWO MODES.",1305,248,81,black,.semibold)
    label("POPOVER + DESKTOP WINDOW",1305,367,24,black,.medium)
    label("LOCAL. FAST. PRIVATE.",1305,412,22,black)
    // The exact exported widgets also provide a small straight-on product reference.
    fit(popover, r(1308,506,272,256))
    label("↔",1601,597,38,black)
    fit(window, r(1662,506,346,256))
    label("POPOVER",1351,793,22,black,.medium)
    label("WINDOW",1785,793,22,black,.medium)
    label("macOS · Windows · Linux",1305,895,28,black,.medium)
    cover(popoverShot,r(2084,0,916,970),source:NSRect(x:510,y:95,width:1000,height:865))
    label("FROM THE MENU BAR.",2140,54,30,.white,.semibold)

    // Wide photographic AMS macro: actual segmented progress and filament slots, never redrawn.
    cover(windowShot,r(0,984,940,614),source:NSRect(x:175,y:395,width:610,height:410))
    fill(r(954,984,1254,614),ivory)
    label("ONE CLICK TO SWITCH.",1010,1037,49,black,.semibold)
    label("Popover ↔ Window",1010,1111,30,black)
    // Crop native header from the real window. The annotation is measured from the real view.
    let screenshot = load("native-source/macos-window.png")
    screenshot.size = NSSize(width:730,height:520)
    let crop = NSRect(x:508,y:450,width:212,height:36)
    let headerImage = bitmap(1060,180) { screenshot.draw(in:r(0,0,1060,180),from:crop,
        operation:.sourceOver,fraction:1) }
    cinematic(headerImage).draw(in:r(1010,1234,1120,190.19))
    let meta = try! JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent("native-source/window-toggle.json"))) as! [String:Double]
    let scale:CGFloat = 1120/212
    let cx:CGFloat = 1010 + (meta["x"]! - 498)*scale
    let cy:CGFloat = 1234 + (36-meta["y"]!)*scale
    orange.setStroke()
    let ring = NSBezierPath(ovalIn:r(cx-67,cy-67,134,134));ring.lineWidth=4;ring.stroke()
    let guide = NSBezierPath();guide.move(to:NSPoint(x:cx,y:2100-cy-69))
    guide.line(to:NSPoint(x:cx,y:2100-1490));guide.line(to:NSPoint(x:1940,y:2100-1490))
    guide.lineWidth=2;guide.stroke()
    label("Switch modes in the header.",1010,1530,25,black)
    cover(plate,r(2222,984,778,614),source:NSRect(x:98,y:305,width:188,height:580))

    fill(r(0,1612,1540,488),black)
    cover(windowShot,r(0,1612,1540,488),source:NSRect(x:115,y:690,width:1320,height:420))
    fill(r(1554,1612,1446,488),ivory)
    label("YOUR PRINTERS.",1610,1672,75,black,.semibold)
    label("YOUR DESKTOP.",1610,1753,75,black,.semibold)
    label("macOS",1614,1885,37,black,.medium)
    label("Windows",1935,1885,37,black,.medium)
    label("Linux",2295,1885,37,black,.medium)
    label("Native macOS views · Demonstration data",1614,2010,21,black)
}
try save(art,output)
print(output.path)
