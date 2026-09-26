import AppKit
import ImageIO

/// Coordinates are relative to the camera image, with the origin at its bottom left.
struct DefectMask: Codable, Equatable {
    struct Point: Codable, Equatable { var x: Double; var y: Double }
    var enabled = false
    var region: [Point] = [] // Empty means the entire image.
    var excluded: [[Point]] = []
    var aspect: Double = 0
    var isActive: Bool { enabled && (!region.isEmpty || !excluded.isEmpty) }

    static func load(serial: String, defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "defect-mask-" + serial),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(serial: String, defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: "defect-mask-" + serial)
    }
    static func valid(_ points: [Point]) -> Bool {
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        let area = points.indices.reduce(0.0) { sum, i in
            let next = points[(i + 1) % points.count]
            return sum + points[i].x * next.y - next.x * points[i].y
        }
        return abs(area) > 0.0002
    }
    static func path(_ points: [Point], in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        for (i, p) in points.enumerated() {
            let point = CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
    enum Failure: LocalizedError {
        case invalid, image, framing
        var errorDescription: String? {
            switch self {
            case .invalid: return Localization.t("Mark a valid area: at least three points.")
            case .image: return Localization.t("Could not prepare the image for analysis.")
            case .framing: return Localization.t("The camera image proportions changed. Adjust the detection area for this printer.")
            }
        }
    }
    func applying(to data: Data) throws -> Data {
        guard isActive else { return data }
        guard (region.isEmpty || Self.valid(region)), excluded.allSatisfy(Self.valid) else { throw Failure.invalid }
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure.image }
        let ratio = Double(image.width) / Double(image.height)
        guard aspect <= 0 || abs(ratio / aspect - 1) < 0.02 else { throw Failure.framing }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.image }
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0.5, 0.5, 0.5, 1])!); ctx.fill(rect)
        ctx.saveGState()
        if !region.isEmpty { ctx.addPath(Self.path(region, in: rect)); ctx.clip() }
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        for polygon in excluded {
            ctx.addPath(Self.path(polygon, in: rect)); ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0.5, 0.5, 0.5, 1])!); ctx.fillPath()
        }
        let output = NSMutableData()
        guard let result = ctx.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw Failure.image }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.image }
        return output as Data
    }
}
