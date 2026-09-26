import AppKit
import ImageIO
import Testing
@testable import Gantry

@MainActor @Suite struct DefectMaskTests {
    private func rectangle(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [DefectMask.Point] {
        [.init(x: x, y: y), .init(x: x+w, y: y), .init(x: x+w, y: y+h), .init(x: x, y: y+h)]
    }
    private func picture(width: Int = 100, height: Int = 100) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
    @Test func disabledIsExactPassthrough() throws {
        var mask = DefectMask(); mask.region = rectangle(0, 0, 0.5, 1)
        let original = try picture()
        #expect(try mask.applying(to: original) == original)
    }
    @Test func regionAndOverlappingExclusionsKeepDimensions() throws {
        var mask = DefectMask(); mask.enabled = true; mask.aspect = 1
        mask.region = rectangle(0, 0, 0.5, 1)
        mask.excluded = [rectangle(0.1, 0.1, 0.3, 0.8), rectangle(0.2, 0.2, 0.2, 0.6)]
        let data = try mask.applying(to: picture())
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let output = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(output.width == 100 && output.height == 100)
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(output, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func red(_ x: Int) -> Double { Double(pixels[50 * 400 + x * 4]) / 255 }
        #expect(red(5) > 0.95)
        let excludedRed = red(25), outsideRed = red(75)
        #expect(abs(excludedRed - 0.5) < 0.03)
        #expect(abs(outsideRed - 0.5) < 0.03)
    }
    @Test func changedAspectAndInvalidPolygonsAreRejected() throws {
        var mask = DefectMask(); mask.enabled = true; mask.aspect = 1; mask.region = rectangle(0, 0, 0.5, 1)
        #expect(throws: DefectMask.Failure.self) { try mask.applying(to: picture(width: 200)) }
        mask.region = [.init(x: 0, y: 0), .init(x: 1, y: 1)]
        #expect(throws: DefectMask.Failure.self) { try mask.applying(to: picture()) }
        #expect(!DefectMask.valid([.init(x: .nan, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1)]))
    }
    @Test func savedSeparatelyForEachPrinter() throws {
        let name = "GantryMaskTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var mask = DefectMask(); mask.enabled = true; mask.region = rectangle(0.1, 0.2, 0.6, 0.7)
        try mask.save(serial: "printer-A", defaults: defaults)
        #expect(DefectMask.load(serial: "printer-A", defaults: defaults) == mask)
        #expect(!DefectMask.load(serial: "printer-B", defaults: defaults).isActive)
    }
}
