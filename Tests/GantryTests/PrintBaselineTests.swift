import Testing
@testable import Gantry

/// The detector that needs no model and no marked frames: it watches how a print changes and calls
/// out the moment it stops changing the way prints do.
///
/// Everything here is a made-up camera, because the point is exactly what a real camera cannot give
/// on demand: a print that goes well for twenty minutes and then collapses, twice, the same way. The
/// frames are built the way the signals see them, so a test that passes says the arithmetic separates
/// "growing normally" from "covered in filament", which is the whole claim.
@Suite struct PrintBaselineTests {
    private let side = FrameSignals.side

    // MARK: A made-up printer

    /// Deterministic noise, so a failing run can be repeated exactly.
    private func speckle(_ x: Int, _ y: Int, _ seed: Int) -> Float {
        var value = UInt64(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663 ^ seed &* 83_492_791)
        value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float((value >> 33) % 1000) / 1000
    }

    /// A print going well: a bare plate, and an object that grows upward a row at a time. Only the
    /// newest rows differ from the frame before, which is what normal printing looks like from a
    /// fixed camera.
    private func printing(step: Int) -> [Float] {
        var frame = [Float](repeating: 0, count: side * side)
        let top = max(0, side - 20 - step)
        for y in 0..<side {
            for x in 0..<side {
                // A plate with a gentle gradient, so the background is not perfectly flat.
                var value: Float = 0.30 + Float(y) / Float(side) * 0.05
                // The object: a solid block with its own fixed pattern, unchanged once printed.
                if y >= top, x >= 30, x < 66 {
                    value = 0.62 + speckle(x, y, 7) * 0.05
                }
                frame[y * side + x] = value
            }
        }
        return frame
    }

    /// The same print, but the filament is no longer going where it should: loose strands over the
    /// whole plate, in a different place every frame.
    private func spaghetti(step: Int) -> [Float] {
        var frame = printing(step: 20)
        for y in 10..<side {
            for x in 0..<side where speckle(x, y, step) > 0.55 {
                frame[y * side + x] = speckle(x &+ 1, y, step &* 31)
            }
        }
        return frame
    }

    /// Komora bez światła: czarny prostokąt z odrobiną szumu matrycy i jedną diodą w rogu.
    private func unlit() -> [Float] {
        var frame = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side { frame[y * side + x] = speckle(x, y, 3) * 0.0008 }
        }
        frame[5 * side + 5] = 0.9
        return frame
    }

    /// Klatka, na której nic nie widać, musi być rozpoznana jako nieczytelna, zanim ktokolwiek
    /// zacznie o niej cokolwiek twierdzić. Na prawdziwej flocie MINI oddała dziewięć takich i
    /// wszystkie zostały zapisane jako spaghetti.
    @Test func anUnlitChamberIsNotSomethingToHaveAnOpinionAbout() {
        #expect(!FrameSignals.legible(unlit()))
        #expect(FrameSignals.legible(printing(step: 10)))
        #expect(FrameSignals.legible(spaghetti(step: 10)))
        // Zmierzone na flocie: najciemniejsza używalna klatka ma fakturę 0,0063, czarna 0,0001,
        // więc próg stoi między nimi, nie przy żadnej z nich.
        #expect(FrameSignals.texture(spaghetti(step: 10)) > FrameSignals.legibleTexture * 10)
    }

    /// The print with everything on it slid sideways, as a layer shift leaves it.
    private func slid(_ frame: [Float], by offset: Int) -> [Float] {
        var moved = [Float](repeating: 0.30, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let from = x - offset
                guard from >= 0, from < side else { continue }
                moved[y * side + x] = frame[y * side + from]
            }
        }
        return moved
    }

    /// The object gone: nothing but the plate.
    private func emptyPlate() -> [Float] {
        var frame = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side { frame[y * side + x] = 0.30 + Float(y) / Float(side) * 0.05 }
        }
        return frame
    }

    /// Feeds a normal print in until the detector has something to compare against.
    private func settled(_ baseline: inout PrintBaseline, frames: Int = 14) {
        for step in 0..<frames {
            _ = baseline.observe(frame: printing(step: step), progress: 0.2 + Double(step) * 0.01)
        }
    }

    // MARK: What must not happen

    @Test func aPrintGoingWellIsNeverCalledAFailure() {
        var baseline = PrintBaseline()
        for step in 0..<40 {
            let reading = baseline.observe(frame: printing(step: step), progress: 0.05 + Double(step) * 0.02)
            #expect(reading.label == nil, "frame \(step) was called \(reading.label ?? "")")
        }
    }

    @Test func theFirstMinutesSayNothingBecauseThereIsNothingToCompareWith() {
        var baseline = PrintBaseline(warmUp: 6)
        // Even handed spaghetti straight away, it has no idea what normal looks like yet.
        for step in 0..<4 {
            #expect(baseline.observe(frame: spaghetti(step: step), progress: 0.2).label == nil)
        }
    }

    @Test func nothingIsJudgedBeforeThereIsAnythingOnThePlate() {
        var baseline = PrintBaseline()
        for step in 0..<20 {
            #expect(baseline.observe(frame: spaghetti(step: step), progress: 0.01).label == nil,
                    "a print that has barely started must not be judged")
        }
    }

    @Test func theChamberLightGoingOutIsNotAFailure() {
        var baseline = PrintBaseline()
        settled(&baseline)
        let dark = printing(step: 14).map { $0 * 0.4 }
        #expect(baseline.observe(frame: dark, progress: 0.35).label == nil)
    }

    // MARK: What must happen

    @Test func spaghettiIsCaughtWithNoModelAndNoMarkedFrames() {
        var baseline = PrintBaseline()
        settled(&baseline)
        var caught: PrintBaseline.Reading?
        for step in 0..<4 {
            let reading = baseline.observe(frame: spaghetti(step: step), progress: 0.4)
            if reading.label == DefectDataset.Label.spaghetti.rawValue { caught = reading; break }
        }
        #expect(caught != nil, "the bed filled with filament and nothing was said")
        #expect((caught?.confidence ?? 0) >= 0.7, "too unsure to clear the default sensitivity")
    }

    @Test func theObjectComingOffTheBedIsCaught() {
        var baseline = PrintBaseline()
        settled(&baseline)
        // One bare frame is the toolhead parked in front of the lens, so it says nothing yet.
        let first = baseline.observe(frame: emptyPlate(), progress: 0.5)
        #expect(first.label == nil, "a single empty frame must not be a verdict")
        let second = baseline.observe(frame: emptyPlate(), progress: 0.51)
        #expect(second.label == DefectDataset.Label.detached.rawValue)
        #expect(second.confidence >= 0.7)
    }

    /// Layer shift detection was withdrawn: on a real fleet it was wrong almost every time it
    /// spoke, and a camera that had not moved reported slides of seven pixels one way and eight the
    /// other. This test keeps it withdrawn rather than letting it quietly return.
    @Test func aPictureThatSlidSidewaysIsNoLongerCalledALayerShift() {
        var baseline = PrintBaseline()
        settled(&baseline)
        let first = baseline.observe(frame: slid(printing(step: 14), by: 8), progress: 0.5)
        let second = baseline.observe(frame: slid(printing(step: 15), by: 16), progress: 0.51)
        for reading in [first, second] {
            #expect(reading.label != DefectDataset.Label.layerShift.rawValue,
                    "layer shift came back without being made to work first")
        }
    }

    @Test func aNewPrintStartsWithNothingLearned() {
        var baseline = PrintBaseline()
        settled(&baseline)
        baseline.reset()
        // Straight after a reset there is no history, so even a wrecked bed waits for the warm-up.
        #expect(baseline.observe(frame: spaghetti(step: 0), progress: 0.4).label == nil)
    }
}

/// The arithmetic underneath: what one frame is worth and how two of them differ.
@Suite struct FrameSignalsTests {
    private let side = 32

    private func flat(_ value: Float) -> [Float] { [Float](repeating: value, count: side * side) }

    private func stripes(offset: Int) -> [Float] {
        var frame = [Float](repeating: 0.2, count: side * side)
        for y in 0..<side {
            for x in 0..<side where (x + offset) % 6 < 2 { frame[y * side + x] = 0.9 }
        }
        return frame
    }

    @Test func aBlankFrameHasNoTextureAndAStripedOneHasPlenty() {
        #expect(FrameSignals.texture(flat(0.5), side: side) == 0)
        #expect(FrameSignals.texture(stripes(offset: 0), side: side) > 0.1)
    }

    @Test func changingTheExposureIsNotChangingThePicture() {
        let before = stripes(offset: 0)
        let after = before.map { min(1, $0 + 0.12) }
        let churn = FrameSignals.churn(before, after, side: side)
        #expect(churn.spread == 0, "a brighter copy of the same frame must read as no change")
    }

    @Test func changeInOnePlaceIsNotChangeEverywhere() {
        var after = flat(0.3)
        for y in 8..<16 {
            for x in 8..<16 { after[y * side + x] = 0.9 }
        }
        let churn = FrameSignals.churn(flat(0.3), after, side: side, tile: 8)
        #expect(churn.amount > 0, "the change was missed altogether")
        #expect(churn.spread <= 0.3, "a patch in one corner must not read as the whole bed moving")
    }

    @Test func aFrameThatSlidSidewaysIsMeasuredAsHavingSlid() {
        let shift = FrameSignals.horizontalShift(stripes(offset: 0), stripes(offset: 3), side: side)
        // Stripes repeat every six columns, so both -3 and 3 describe the same picture.
        #expect(abs(shift) == 3)
    }

    @Test func aFrameThatDidNotMoveIsMeasuredAsNotHavingMoved() {
        #expect(FrameSignals.horizontalShift(stripes(offset: 0), stripes(offset: 0), side: side) == 0)
    }
}
