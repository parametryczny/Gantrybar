import Foundation

/// Watching one print go wrong, with nothing to go on but the print itself.
///
/// This is the part that works on the first day, on a printer nobody has ever photographed, with no
/// model file and no marked frames. It learns what *this* print looks like while it is going well
/// (a few minutes is plenty) and then reports the moment the picture stops behaving that way.
///
/// Three things can be said from a fixed camera without knowing what a printer is:
///
/// - **Spaghetti** covers the bed in filament. The change stops being confined to the nozzle and
///   spreads over the whole frame, and the frame gets much busier than it has been all print.
/// - **The object coming off the bed** is one violent frame followed by a much emptier picture: what
///   was there is gone, so the detail drops well under what the print had settled at.
/// - **A layer shift** slides the whole object sideways between two frames while the bed stays put.
///
/// Every judgement is made against this print's own recent history rather than a fixed number, so a
/// dark chamber, a busy background or a camera that sees half the gantry does not have to be tuned
/// for. That also means the first few minutes are spent learning and say nothing.
struct PrintBaseline {
    /// What one frame was worth saying about it, in the same shape a model would answer in.
    struct Reading: Equatable {
        var label: String?
        var confidence: Double
    }

    /// How many frames to watch before judging anything. Below this there is no history to be unusual
    /// against, and an early print is jumpy anyway.
    var warmUp: Int
    /// How much of the frame has to change at once before spread counts as bed-wide.
    var spreadFloor: Float
    /// How far sideways the picture may slide between frames before it is a shift, in working pixels.
    var shiftFloor: Int
    /// A brightness step this large means the light changed, not the print; that frame is skipped.
    var lightStep: Float

    init(warmUp: Int = 6, spreadFloor: Float = 0.30, shiftFloor: Int = 4, lightStep: Float = 0.06) {
        self.warmUp = max(2, warmUp)
        self.spreadFloor = spreadFloor
        self.shiftFloor = max(2, shiftFloor)
        self.lightStep = lightStep
    }

    private var previous: [Float]?
    private var textures: [Float] = []
    private var spreads: [Float] = []
    private var pendingShift = 0
    /// Only the recent past counts: a print an hour in should be compared with the last few minutes,
    /// not with the empty plate it started from.
    private let memory = 24

    /// Feeds one frame in and gets back what, if anything, it says.
    ///
    /// - Parameters:
    ///   - frame: the greyscale buffer from `FrameSignals.grey`.
    ///   - progress: 0 to 1. The first few percent are skipped: there is nothing on the plate to go
    ///     wrong yet, and the first layers are the jumpiest picture of the whole print.
    mutating func observe(frame: [Float], progress: Double, side: Int = FrameSignals.side) -> Reading {
        defer { previous = frame }
        guard progress >= 0.03 else {
            reset()
            return Reading(label: nil, confidence: 0)
        }
        guard let previous else { return Reading(label: nil, confidence: 0) }

        let texture = FrameSignals.texture(frame, side: side)
        // The light going on or off changes every pixel at once. Nothing can be read from that frame,
        // and the history it would poison is the only thing this detector has.
        guard abs(FrameSignals.brightness(frame) - FrameSignals.brightness(previous)) <= lightStep else {
            forget()
            return Reading(label: nil, confidence: 0)
        }

        let churn = FrameSignals.churn(previous, frame, side: side)
        let shift = FrameSignals.horizontalShift(previous, frame, side: side)
        let history = (textures: textures, spreads: spreads)
        remember(texture: texture, spread: churn.spread)
        guard history.textures.count >= warmUp else { return Reading(label: nil, confidence: 0) }

        let usualTexture = Self.median(history.textures)
        let usualSpread = Self.median(history.spreads)

        // A shift has to still be there on the next frame. One frame of sideways movement is the
        // toolhead crossing the lens or somebody's hand in the chamber; two is the object.
        let shifted = abs(shift) >= shiftFloor
        let confirmed = shifted && pendingShift != 0 && (pendingShift > 0) == (shift > 0)
        pendingShift = shifted ? shift : 0
        if confirmed {
            return Reading(label: DefectDataset.Label.layerShift.rawValue,
                           confidence: sureness(Float(abs(shift)), over: Float(shiftFloor)))
        }

        // Gone: a good part of the frame changed in one step and what is left is far plainer than
        // this print has ever been. The second half is what makes it specific, because a picture
        // losing its detail is the one thing that does not happen while something is being built.
        if churn.amount > 0.10, usualTexture > 0, texture < usualTexture * 0.6 {
            return Reading(label: DefectDataset.Label.detached.rawValue,
                           confidence: sureness(usualTexture / max(texture, 0.000_1), over: 1 / 0.6))
        }

        // Spaghetti: the change is everywhere instead of at the nozzle, and the frame is busier than
        // it has been. Both have to hold, because a camera that watches the gantry sweep sees wide
        // change on its own, and a print that simply grew detailed is not a failure.
        let spreadTrigger = max(spreadFloor, usualSpread * 2.2)
        if churn.spread >= spreadTrigger, usualTexture > 0, texture > usualTexture * 1.25 {
            return Reading(label: DefectDataset.Label.spaghetti.rawValue,
                           confidence: sureness(churn.spread, over: spreadTrigger))
        }

        return Reading(label: nil, confidence: 0)
    }

    /// A new print, or one that has been interrupted, starts with nothing learned.
    mutating func reset() {
        previous = nil
        textures.removeAll()
        spreads.removeAll()
        pendingShift = 0
    }

    /// Drops the history but keeps watching: for a frame that cannot be compared with the last one,
    /// such as the chamber light changing.
    private mutating func forget() {
        textures.removeAll()
        spreads.removeAll()
        pendingShift = 0
    }

    private mutating func remember(texture: Float, spread: Float) {
        textures.append(texture)
        spreads.append(spread)
        if textures.count > memory { textures.removeFirst() }
        if spreads.count > memory { spreads.removeFirst() }
    }

    /// How sure to be about a value that has passed its trigger. Sitting exactly on the trigger is a
    /// coin toss; twice the trigger is certain. This maps onto the same sensitivity slider the model
    /// path uses, so "70%" means the same strength of evidence whichever is doing the looking.
    private func sureness(_ value: Float, over trigger: Float) -> Double {
        guard trigger > 0 else { return 0 }
        return Double(min(1, max(0, 0.5 + 0.5 * (value / trigger - 1))))
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
