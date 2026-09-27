import Foundation
import Testing
@testable import Gantry

@Suite struct BedCalibrationTests {
    /// A camera looking down at the bed with some perspective: the back edge appears narrower.
    private var calibration: BedCalibration {
        var value = BedCalibration()
        value.bedWidth = 200
        value.bedDepth = 200
        value.top = [.init(x: 0.3, y: 0.8), .init(x: 0.7, y: 0.8), .init(x: 0.9, y: 0.2), .init(x: 0.1, y: 0.2)]
        return value
    }

    @Test func cornersMapExactlyOntoTheClickedPoints() throws {
        let h = try #require(calibration.homography())
        for (bed, image) in zip(calibration.bedCorners, calibration.top) {
            let p = try #require(h.apply(bed))
            #expect(abs(p.x - image.x) < 1e-9)
            #expect(abs(p.y - image.y) < 1e-9)
        }
    }

    @Test func theBedCentreLandsInsideTheQuad() throws {
        let h = try #require(calibration.homography())
        let centre = try #require(h.apply(.init(x: 100, y: 100)))
        #expect(BedZones.contains(calibration.top, centre))
        // Perspective: the centre of the bed sits above the middle of the picture's quad height.
        #expect(centre.y > 0.5 - 0.1)
    }

    @Test func aLoweredBedIsInterpolated() {
        var value = calibration
        value.low = value.top.map { .init(x: $0.x, y: $0.y - 0.2) }
        value.lowered = 100
        #expect(abs(value.corners(droppedBy: 50)[0].y - 0.7) < 1e-9)
        #expect(value.corners(droppedBy: 0) == value.top)
    }

    @Test func aSlidingBedIsNotUsedForObjects() {
        var value = calibration
        value.movingBed = true
        #expect(value.isComplete)
        #expect(!value.usableForObjects)
    }

    @Test func knownPrintersGetTheirBedSize() {
        let mini = BedCalibration.defaults(for: SavedPrinter(serial: "a", name: "A1 mini", model: "N1", host: "h"))
        #expect(mini.bedWidth == 180)
        #expect(mini.movingBed)
        let x1 = BedCalibration.defaults(for: SavedPrinter(serial: "b", name: "X1C", model: "BL-P001", host: "h"))
        #expect(x1.bedWidth == 256)
        #expect(!x1.movingBed)
    }
}

@Suite struct BedZonesTests {
    private var calibration: BedCalibration {
        var value = BedCalibration()
        value.bedWidth = 200
        value.bedDepth = 200
        // Straight down: the bed fills the middle of the picture.
        value.top = [.init(x: 0.1, y: 0.9), .init(x: 0.9, y: 0.9), .init(x: 0.9, y: 0.1), .init(x: 0.1, y: 0.1)]
        return value
    }

    @Test func objectsAreCarvedOutOfTheBed() throws {
        let object: [BedCalibration.Point] = [.init(x: 80, y: 80), .init(x: 120, y: 80), .init(x: 120, y: 120), .init(x: 80, y: 120)]
        let zones = try #require(BedZones.make(calibration: calibration, objects: [object], droppedBy: 0, side: 50, margin: 0))
        let centre = 25 * 50 + 25
        #expect(zones.bed[centre])
        #expect(zones.objects[centre])
        #expect(!zones.free[centre])
        #expect(!zones.bed[0])
        #expect(zones.freeCount > zones.objectCount)
    }

    @Test func theCropCoversTheBed() throws {
        let rect = try #require(BedZones.crop(calibration: calibration, droppedBy: 0))
        #expect(rect.minX < 0.1 && rect.maxX > 0.9)
    }
}

@Suite struct FootprintWatchTests {
    private let side = 40

    private func zones() -> BedZones {
        var bed = [Bool](repeating: false, count: 40 * 40)
        var objects = [Bool](repeating: false, count: 40 * 40)
        for row in 5..<35 { for column in 5..<35 { bed[row * 40 + column] = true } }
        for row in 15..<25 { for column in 15..<25 { objects[row * 40 + column] = true } }
        return BedZones(side: 40, bed: bed, objects: objects)
    }

    /// A plain bed with a textured object in the middle.
    private func frame(object: Bool = true, strands: Int = 0) -> [Float] {
        var pixels = [Float](repeating: 0.4, count: 40 * 40)
        if object {
            for row in 15..<25 { for column in 15..<25 { pixels[row * 40 + column] = (row + column) % 2 == 0 ? 0.9 : 0.2 } }
        }
        for strand in 0..<strands {
            let row = 6 + (strand * 3) % 28
            for column in 6..<14 { pixels[row * 40 + column] = 0.95 }
        }
        return pixels
    }

    @Test func aCalmPrintSaysNothing() {
        var watch = FootprintWatch()
        for _ in 0..<20 { #expect(watch.observe(frame: frame(), zones: zones(), progress: 0.5).label == nil) }
    }

    @Test func filamentOnBareBedIsSpaghetti() {
        var watch = FootprintWatch()
        for _ in 0..<8 { _ = watch.observe(frame: frame(), zones: zones(), progress: 0.5) }
        _ = watch.observe(frame: frame(strands: 8), zones: zones(), progress: 0.5)
        let second = watch.observe(frame: frame(strands: 9), zones: zones(), progress: 0.5)
        #expect(second.label == DefectDataset.Label.spaghetti.rawValue)
        #expect(second.confidence >= 0.5)
    }

    @Test func anObjectThatVanishesIsDetached() {
        var watch = FootprintWatch()
        for _ in 0..<8 { _ = watch.observe(frame: frame(), zones: zones(), progress: 0.5) }
        _ = watch.observe(frame: frame(object: false), zones: zones(), progress: 0.5)
        let second = watch.observe(frame: frame(object: false), zones: zones(), progress: 0.5)
        #expect(second.label == DefectDataset.Label.detached.rawValue)
    }

    @Test func oneOddFrameIsNotEnough() {
        var watch = FootprintWatch()
        for _ in 0..<8 { _ = watch.observe(frame: frame(), zones: zones(), progress: 0.5) }
        #expect(watch.observe(frame: frame(strands: 8), zones: zones(), progress: 0.5).label == nil)
        #expect(watch.observe(frame: frame(), zones: zones(), progress: 0.5).label == nil)
    }
}
