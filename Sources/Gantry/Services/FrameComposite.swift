import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A few frames of the same camera, a second apart, folded into one picture of what stayed put.
///
/// One frame is a gamble: every so often it catches the toolhead in the middle of the bed, a hand at
/// the door or a purge blob mid-flight, and each of those looks like something new. The print itself
/// barely moves in a few seconds; the toolhead moves all the time. Taking the median of every pixel
/// over the burst keeps what is in most of the frames (the bed and the part) and drops what is in only
/// one or two (the head sweeping past). That is the frame everything downstream should judge.
///
/// Plain arithmetic on a reduced copy, off the main thread; nothing is learned or stored.
enum FrameComposite {
    /// Working width of the composite. The model looks at 224 points and the behaviour check at 96, so
    /// this is comfortably above both and small enough to fold five frames in a few milliseconds.
    static let width = 640

    /// Folds JPEG frames into one median JPEG. Returns the single frame unchanged when there is only
    /// one, and nil when nothing could be decoded.
    nonisolated static func median(jpegs: [Data], width: Int = width) -> Data? {
        let images = jpegs.compactMap(decode)
        guard let first = images.first else { return nil }
        guard images.count > 1 else { return jpegs.first }
        let height = max(1, Int((Double(first.height) / Double(max(1, first.width)) * Double(width)).rounded()))
        let buffers = images.compactMap { rgba($0, width: width, height: height) }
        guard buffers.count > 1 else { return jpegs.first }
        let folded = median(buffers: buffers)
        return encode(folded, width: width, height: height)
    }

    /// The per-channel median of equally sized buffers. With an even count it takes the lower middle,
    /// which keeps it a value that was really seen rather than an average of two.
    nonisolated static func median(buffers: [[UInt8]]) -> [UInt8] {
        guard let first = buffers.first else { return [] }
        guard buffers.count > 1 else { return first }
        let count = first.count
        let middle = (buffers.count - 1) / 2
        var out = [UInt8](repeating: 0, count: count)
        var column = [UInt8](repeating: 0, count: buffers.count)
        for i in 0..<count {
            for (j, buffer) in buffers.enumerated() { column[j] = i < buffer.count ? buffer[i] : 0 }
            column.sort()
            out[i] = column[middle]
        }
        return out
    }

    // MARK: Pixels

    nonisolated static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    nonisolated static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    nonisolated static func encode(_ pixels: [UInt8], width: Int, height: Int) -> Data? {
        guard pixels.count == width * height * 4, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let image: CGImage? = pixels.withUnsafeBytes { raw in
            guard let provider = CGDataProvider(data: Data(raw) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let image else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
