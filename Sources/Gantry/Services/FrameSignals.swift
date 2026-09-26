import CoreGraphics
import Foundation
import ImageIO

/// What one camera frame looks like in numbers, and how it differs from the one before it.
///
/// A printer camera never moves. That is worth more than any trained model: the same pixels look at
/// the same bed all print long, so a failure does not have to be recognised from what it *is*, only
/// from how the picture stops behaving. Normal printing changes a narrow band around the nozzle and
/// leaves the rest of the frame alone. Spaghetti changes the whole bed at once and keeps doing it.
///
/// Everything here is plain arithmetic on a small greyscale copy of the frame: no model, no training
/// data, no licence to honour, and small enough to run on five printers a minute without being felt.
enum FrameSignals {
    /// The working size. Large enough that a strand of filament survives the downscale, small enough
    /// that a whole frame is nine thousand numbers rather than two million.
    static let side = 96

    /// How much of the frame changed, and how widely that change is spread.
    struct Churn: Equatable {
        /// Fraction of pixels that moved more than camera noise.
        var amount: Float
        /// Fraction of the frame's tiles that hold real change. A print in progress works in one place,
        /// so this stays low however bright the change is; filament flying about does not.
        var spread: Float
    }

    // MARK: Reading a frame

    /// Turns a JPEG into a square greyscale buffer of values between 0 and 1.
    static func grey(from jpeg: Data, side: Int = side) -> [Float]? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return grey(from: image, side: side)
    }

    static func grey(from image: CGImage, side: Int = side) -> [Float]? {
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let space = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else {
            return nil
        }
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        // Squashing a 16:9 frame into a square distorts it, which costs nothing here: every frame from
        // this camera is distorted the same way, and only the comparison between them matters.
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels.map { Float($0) / 255 }
    }

    // MARK: Describing a frame

    /// The average brightness. Used to spot the chamber light going on or off, which changes every
    /// pixel at once and has nothing to do with the print.
    static func brightness(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        return frame.reduce(0, +) / Float(frame.count)
    }

    /// Poniżej tyle faktury w klatce nie ma już nic do oglądania.
    ///
    /// Zmierzone na prawdziwych klatkach: najciemniejsza używalna klatka z floty ma 0,0063, a klatka
    /// z komory bez światła 0,0001. Próg leży trzy razy poniżej pierwszej i dwadzieścia razy powyżej
    /// drugiej, więc nie odrzuca niczego, co da się obejrzeć.
    static let legibleTexture: Float = 0.002

    /// Czy w tej klatce w ogóle jest co oglądać.
    ///
    /// Kamera w komorze bez światła zwraca czarny prostokąt. Żaden model ani wzorzec nie powie o nim
    /// prawdy, a każdy powie coś: MINI oddała dziewięć takich klatek i wszystkie dostały etykietę
    /// spaghetti. Lepiej przyznać, że nie widać, niż zgadywać po ciemku.
    static func legible(_ frame: [Float], side: Int = side) -> Bool {
        texture(frame, side: side) >= legibleTexture
    }

    /// How much fine detail the frame holds: the average step between neighbouring pixels. A bare
    /// plate is smooth, a finished print has edges, a bed full of loose filament is nothing but edges.
    static func texture(_ frame: [Float], side: Int = side) -> Float {
        guard frame.count == side * side, side > 1 else { return 0 }
        var total: Float = 0
        for y in 0..<(side - 1) {
            let row = y * side
            for x in 0..<(side - 1) {
                let here = frame[row + x]
                total += abs(here - frame[row + x + 1]) + abs(here - frame[row + side + x])
            }
        }
        return total / Float(2 * (side - 1) * (side - 1))
    }

    // MARK: Comparing two frames

    /// What changed between two frames of the same camera.
    ///
    /// The second frame is shifted to the first one's average brightness first, so a cloud passing the
    /// window or the camera's own exposure drifting does not read as the print falling apart.
    static func churn(_ before: [Float], _ after: [Float], side: Int = side,
                      noise: Float = 0.09, tile: Int = 8) -> Churn {
        guard before.count == after.count, before.count == side * side else { return Churn(amount: 0, spread: 0) }
        let offset = brightness(before) - brightness(after)
        var changed = 0
        let tiles = max(1, side / tile)
        var perTile = [Int](repeating: 0, count: tiles * tiles)
        for y in 0..<side {
            let row = y * side
            let tileRow = min(tiles - 1, y / tile) * tiles
            for x in 0..<side {
                guard abs(before[row + x] - (after[row + x] + offset)) > noise else { continue }
                changed += 1
                perTile[tileRow + min(tiles - 1, x / tile)] += 1
            }
        }
        // A tile counts as changed once a twelfth of it moved: enough to ignore a noisy pixel or two,
        // little enough that a single strand crossing the tile still registers.
        let needed = max(1, (tile * tile) / 12)
        let busy = perTile.reduce(0) { $0 + ($1 >= needed ? 1 : 0) }
        return Churn(amount: Float(changed) / Float(before.count),
                     spread: Float(busy) / Float(perTile.count))
    }

    /// How far the picture slid sideways between two frames, in pixels of the working size.
    ///
    /// A layer shift is the one failure a single picture cannot show: the print still looks like a
    /// print, it is just in the wrong place. Between two frames it is obvious, because the whole
    /// object's vertical edges move together while the bed and the frame stay put.
    static func horizontalShift(_ before: [Float], _ after: [Float], side: Int = side,
                                maxShift: Int = 12) -> Int {
        guard before.count == after.count, before.count == side * side, side > 2 else { return 0 }
        let first = edgeColumns(before, side: side)
        let second = edgeColumns(after, side: side)
        var best = 0
        var bestScore = Float.greatestFiniteMagnitude
        for shift in -maxShift...maxShift {
            var score: Float = 0
            var counted = 0
            for x in 0..<side {
                let other = x + shift
                guard other >= 0, other < side else { continue }
                score += abs(first[x] - second[other])
                counted += 1
            }
            guard counted > side / 2 else { continue }
            score /= Float(counted)
            // Ties go to no movement: an ambiguous frame should not be read as a shift.
            if score < bestScore - 0.000_01 || (abs(shift) < abs(best) && score < bestScore + 0.000_01) {
                bestScore = score
                best = shift
            }
        }
        return best
    }

    /// How much vertical edge sits in each column: the object's outline, seen from above the noise.
    private static func edgeColumns(_ frame: [Float], side: Int) -> [Float] {
        var columns = [Float](repeating: 0, count: side)
        for y in 0..<side {
            let row = y * side
            for x in 0..<(side - 1) {
                columns[x] += abs(frame[row + x] - frame[row + x + 1])
            }
        }
        let peak = columns.max() ?? 0
        guard peak > 0 else { return columns }
        return columns.map { $0 / peak }
    }
}
