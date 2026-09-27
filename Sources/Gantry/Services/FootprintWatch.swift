import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Which pixels of the working frame are bed, which are the objects being printed, and which are bed
/// with nothing meant to be on it.
///
/// Built from a `BedCalibration` and the objects' outlines in bed millimetres. An object is not a flat
/// outline for the camera: it rises from the bed towards the nozzle, and on a printer whose bed drops
/// the base moves down the picture as the print grows. So each object's region is the outline at the
/// bed's current height joined with the outline at nozzle height, widened by a margin that absorbs a
/// few millimetres of calibration error and the brim.
struct BedZones: Equatable {
    let side: Int
    let bed: [Bool]
    let objects: [Bool]

    var free: [Bool] { zip(bed, objects).map { $0 && !$1 } }
    var freeCount: Int { zip(bed, objects).reduce(0) { $0 + ($1.0 && !$1.1 ? 1 : 0) } }
    var objectCount: Int { objects.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// - Parameters:
    ///   - objects: each object's outline in bed millimetres.
    ///   - droppedBy: how far the bed has dropped since it was clicked (layer × layer height).
    static func make(calibration: BedCalibration, objects: [[BedCalibration.Point]], droppedBy z: Double,
                     side: Int = FrameSignals.side, margin: Double = 6) -> BedZones? {
        guard let base = calibration.homography(droppedBy: z), let top = calibration.homography(droppedBy: 0) else { return nil }
        let bedQuad = calibration.bedCorners.compactMap { base.apply($0) }
        guard bedQuad.count == 4 else { return nil }
        let regions: [[BedCalibration.Point]] = objects.compactMap { outline in
            guard let minX = outline.map(\.x).min(), let maxX = outline.map(\.x).max(),
                  let minY = outline.map(\.y).min(), let maxY = outline.map(\.y).max() else { return nil }
            let box = [BedCalibration.Point(x: minX - margin, y: minY - margin), BedCalibration.Point(x: maxX + margin, y: minY - margin),
                       BedCalibration.Point(x: maxX + margin, y: maxY + margin), BedCalibration.Point(x: minX - margin, y: maxY + margin)]
            let projected = box.compactMap { base.apply($0) } + box.compactMap { top.apply($0) }
            return convexHull(projected)
        }
        var bed = [Bool](repeating: false, count: side * side)
        var inside = [Bool](repeating: false, count: side * side)
        for row in 0..<side {
            // Row 0 of the working frame is the top of the picture; calibration points count from the bottom.
            let y = 1 - (Double(row) + 0.5) / Double(side)
            for column in 0..<side {
                let point = BedCalibration.Point(x: (Double(column) + 0.5) / Double(side), y: y)
                let index = row * side + column
                bed[index] = contains(bedQuad, point)
                inside[index] = regions.contains { contains($0, point) }
            }
        }
        return BedZones(side: side, bed: bed, objects: inside)
    }

    /// The part of the picture worth handing to the appearance model: the bed and everything standing
    /// on it, with a little room around it. Relative, origin bottom left.
    static func crop(calibration: BedCalibration, droppedBy z: Double, padding: Double = 0.04) -> CGRect? {
        guard let base = calibration.homography(droppedBy: z), let top = calibration.homography(droppedBy: 0) else { return nil }
        let points = calibration.bedCorners.compactMap { base.apply($0) } + calibration.bedCorners.compactMap { top.apply($0) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let rect = CGRect(x: minX - padding, y: minY - padding, width: maxX - minX + 2 * padding, height: maxY - minY + 2 * padding)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return rect.width > 0.1 && rect.height > 0.1 ? rect : nil
    }

    // MARK: Geometry

    static func contains(_ polygon: [BedCalibration.Point], _ p: BedCalibration.Point) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    static func convexHull(_ points: [BedCalibration.Point]) -> [BedCalibration.Point] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: BedCalibration.Point, _ a: BedCalibration.Point, _ b: BedCalibration.Point) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [BedCalibration.Point] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [BedCalibration.Point] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}

/// Failure detection that knows where the objects are.
///
/// The whole-frame check could not tell a toolhead sweeping past from an object moving, or filament
/// on the bed from a print that grew detailed. With the bed calibrated and the objects' outlines known,
/// both questions get a place to look:
///
/// - **Spaghetti** is something new on bed where nothing is meant to be. The bare bed around the
///   objects is compared with how it looked over the last minutes; a growing share of it changing,
///   on two looks running, is filament where it should not be.
/// - **An object coming off** leaves its own region: the detail inside the objects' outlines drops
///   well below what this print has been showing, and stays down.
///
/// Every judgement is against this print's own history, like `PrintBaseline`, so lighting and bed
/// colour need no tuning. The slow drift of a dropping bed is absorbed by a reference that follows
/// calm frames.
struct FootprintWatch {
    /// Bed drop per layer when the file does not say: the most common layer height.
    static let layerHeight = 0.2

    var warmUp = 5
    var noise: Float = 0.10
    private var reference: [Float]?
    private var changedHistory: [Float] = []
    private var objectTextures: [Float] = []
    private var previousChanged: Float = 0
    private var previousBare = false
    private var looks = 0
    private let memory = 24

    init(warmUp: Int = 5) { self.warmUp = max(2, warmUp) }

    mutating func reset() {
        reference = nil
        changedHistory.removeAll()
        objectTextures.removeAll()
        previousChanged = 0
        previousBare = false
        looks = 0
    }

    mutating func observe(frame: [Float], zones: BedZones, progress: Double) -> PrintBaseline.Reading {
        let quiet = PrintBaseline.Reading(label: nil, confidence: 0)
        guard frame.count == zones.side * zones.side, progress >= 0.03 else {
            if progress < 0.03 { reset() }
            return quiet
        }
        let free = zones.free
        let freeCount = zones.freeCount
        guard freeCount >= 30 else { return quiet }
        guard let reference else {
            self.reference = frame
            return quiet
        }
        // The light changing moves every pixel; start the reference again rather than read it as filament.
        if abs(Self.mean(frame, where: zones.bed) - Self.mean(reference, where: zones.bed)) > 0.06 {
            self.reference = frame
            previousChanged = 0
            return quiet
        }
        var changed = 0
        for i in frame.indices where free[i] && abs(frame[i] - reference[i]) > noise { changed += 1 }
        let changedShare = Float(changed) / Float(freeCount)
        let objectTexture = Self.texture(frame, where: zones.objects, side: zones.side)
        looks += 1

        guard looks > warmUp, !changedHistory.isEmpty else {
            learn(frame: frame, changed: changedShare, objectTexture: objectTexture, zones: zones)
            return quiet
        }

        let usualChanged = Self.median(changedHistory)
        let trigger = max(0.04, usualChanged * 3 + 0.01)
        defer { previousChanged = changedShare }

        // Spaghetti: new material on bare bed, on two looks running.
        if changedShare >= trigger, previousChanged >= trigger * 0.8 {
            return PrintBaseline.Reading(label: DefectDataset.Label.spaghetti.rawValue,
                                         confidence: Self.sureness(changedShare, between: trigger, and: max(trigger * 4, 0.3)))
        }

        // Gone: the objects' own region lost most of its detail, and still has on the next look.
        let usualObject = Self.median(objectTextures)
        let bare = zones.objectCount >= 12 && usualObject > 0.004 && objectTexture < usualObject * 0.55
        defer { previousBare = bare }
        if bare, previousBare {
            return PrintBaseline.Reading(label: DefectDataset.Label.detached.rawValue,
                                         confidence: Self.sureness(usualObject / max(objectTexture, 0.000_1), between: 1 / 0.55, and: 4))
        }

        // A frame that looks suspicious but is not a verdict yet is not learned from: the reference
        // would drift towards the very thing it should be noticing.
        if changedShare < trigger, !bare {
            learn(frame: frame, changed: changedShare, objectTexture: objectTexture, zones: zones)
        }
        return quiet
    }

    /// A calm frame: the reference follows it a little (so a bed dropping away is absorbed), and its
    /// numbers join the history everything is compared against.
    private mutating func learn(frame: [Float], changed: Float, objectTexture: Float, zones: BedZones) {
        if var reference {
            for i in reference.indices { reference[i] += (frame[i] - reference[i]) * 0.2 }
            self.reference = reference
        }
        changedHistory.append(changed)
        if changedHistory.count > memory { changedHistory.removeFirst() }
        if zones.objectCount >= 12 {
            objectTextures.append(objectTexture)
            if objectTextures.count > memory { objectTextures.removeFirst() }
        }
    }

    // MARK: Numbers

    static func mean(_ frame: [Float], where mask: [Bool]) -> Float {
        var total: Float = 0, count = 0
        for i in frame.indices where i < mask.count && mask[i] { total += frame[i]; count += 1 }
        return count == 0 ? 0 : total / Float(count)
    }

    static func texture(_ frame: [Float], where mask: [Bool], side: Int) -> Float {
        guard frame.count == side * side, mask.count == frame.count, side > 1 else { return 0 }
        var total: Float = 0, count = 0
        for y in 0..<(side - 1) {
            for x in 0..<(side - 1) {
                let i = y * side + x
                guard mask[i] else { continue }
                total += abs(frame[i] - frame[i + 1]) + abs(frame[i] - frame[i + side])
                count += 1
            }
        }
        return count == 0 ? 0 : total / Float(2 * count)
    }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Same scale as `PrintBaseline`: on the trigger is a coin toss, at the ceiling it is certain.
    static func sureness(_ value: Float, between trigger: Float, and ceiling: Float) -> Double {
        guard ceiling > trigger else { return 0.5 }
        return Double(min(1, max(0, 0.5 + 0.5 * (value - trigger) / (ceiling - trigger))))
    }
}

/// Cuts a frame down to a relative rectangle (origin bottom left), so the appearance model spends its
/// 224 points on the bed instead of the chamber walls.
enum FrameCrop {
    nonisolated static func crop(jpeg: Data, to rect: CGRect) -> Data? {
        guard let image = FrameComposite.decode(jpeg) else { return nil }
        let width = Double(image.width), height = Double(image.height)
        let pixels = CGRect(x: rect.minX * width, y: (1 - rect.maxY) * height,
                            width: rect.width * width, height: rect.height * height).integral
        guard let cropped = image.cropping(to: pixels) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cropped, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// The calibrated part of one look, shared by the live watcher and the replay so both judge a frame
/// the same way.
enum FootprintAnalysis {
    struct Result {
        /// The frame for the whole-picture behaviour check, with everything off the bed greyed out.
        var behaviourFrame: [Float]
        /// The picture for the appearance model, cut down to the bed.
        var modelJPEG: Data
        /// What the object-aware check said, when the objects' outlines are known.
        var zones: PrintBaseline.Reading?
    }

    static func apply(frame: [Float], jpeg: Data, calibration: BedCalibration?, outlines: [[BedCalibration.Point]],
                      layer: Int?, progress: Double, watch: inout FootprintWatch) -> Result {
        let untouched = Result(behaviourFrame: frame, modelJPEG: jpeg, zones: nil)
        guard let calibration, calibration.usableForObjects else { return untouched }
        // A camera now sending a differently shaped picture was not what was clicked.
        if calibration.aspect > 0, let image = FrameComposite.decode(jpeg), image.height > 0,
           abs(Double(image.width) / Double(image.height) / calibration.aspect - 1) > 0.02 {
            return untouched
        }
        let drop = Double(layer ?? 0) * FootprintWatch.layerHeight
        var behaviour = frame
        var reading: PrintBaseline.Reading?
        if let zones = BedZones.make(calibration: calibration, objects: outlines, droppedBy: drop) {
            for i in behaviour.indices where i < zones.bed.count && !zones.bed[i] { behaviour[i] = 0.5 }
            // Without outlines the print itself would count as "something on bare bed".
            if !outlines.isEmpty { reading = watch.observe(frame: frame, zones: zones, progress: progress) }
        }
        var model = jpeg
        if let rect = BedZones.crop(calibration: calibration, droppedBy: drop),
           let cropped = FrameCrop.crop(jpeg: jpeg, to: rect) { model = cropped }
        return Result(behaviourFrame: behaviour, modelJPEG: model, zones: reading)
    }

    /// Object outlines from a loaded layout, in bed millimetres. A layout read from Bambu's pick image
    /// is in that image's pixels (top down, origin top left); one from the plate's JSON or Klipper is
    /// already in millimetres.
    static func outlines(from layout: PrintObjectLayout, calibration: BedCalibration) -> [[BedCalibration.Point]] {
        let bounds = layout.bedBounds
        let fromImage = layout.previewPNG != nil && bounds.count >= 4
        let width = fromImage ? bounds[2] - bounds[0] : 0
        let height = fromImage ? bounds[3] - bounds[1] : 0
        return layout.objects.map { object in
            object.polygon.map { p in
                guard fromImage, width > 0, height > 0 else { return BedCalibration.Point(x: p.x, y: p.y) }
                return BedCalibration.Point(x: (p.x - bounds[0]) / width * calibration.bedWidth,
                                            y: (1 - (p.y - bounds[1]) / height) * calibration.bedDepth)
            }
        }.filter { $0.count >= 3 }
    }
}
