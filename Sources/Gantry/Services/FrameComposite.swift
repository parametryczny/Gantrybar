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
        let decoded = images.indices.compactMap { index in rgba(images[index], width: width, height: height).map { (index, $0) } }
        guard decoded.count > 1 else { return jpegs.first }
        let buffers = decoded.map(\.1)
        // On a bed-slinger (A1, A1 mini, Prusa MK, Ender) the bed itself travels between frames, so
        // the scene is not still and a per-pixel median would smear the part. There the best that can
        // be done is the one frame most like the others.
        if let medoid = medoidIfSceneMoves(buffers) { return jpegs[decoded[medoid].0] }
        let folded = median(buffers: buffers)
        return encode(folded, width: width, height: height)
    }

    /// Share of pixels that differ between two frames by more than camera noise. A toolhead passing
    /// changes a small part of the picture; a moving bed changes most of it.
    nonisolated static func difference(_ a: [UInt8], _ b: [UInt8], stride step: Int = 16) -> Double {
        let count = min(a.count, b.count)
        guard count >= 4 else { return 0 }
        var changed = 0, total = 0
        var i = 0
        while i + 2 < count {
            let delta = (abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))) / 3
            if delta > 18 { changed += 1 }
            total += 1
            i += step * 4
        }
        return total == 0 ? 0 : Double(changed) / Double(total)
    }

    /// Index of the frame closest to all the others, when the frames disagree so widely that the scene
    /// must be moving; nil when a median is safe.
    nonisolated static func medoidIfSceneMoves(_ buffers: [[UInt8]], movingShare: Double = 0.35) -> Int? {
        guard buffers.count > 1 else { return nil }
        var distances = [[Double]](repeating: [Double](repeating: 0, count: buffers.count), count: buffers.count)
        var pairs: [Double] = []
        for i in buffers.indices {
            for j in buffers.indices where j > i {
                let d = difference(buffers[i], buffers[j])
                distances[i][j] = d
                distances[j][i] = d
                pairs.append(d)
            }
        }
        let typical = pairs.sorted()[pairs.count / 2]
        guard typical > movingShare else { return nil }
        return buffers.indices.min { distances[$0].reduce(0, +) < distances[$1].reduce(0, +) }
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
