import Foundation

/// Watching one print go wrong, with nothing to go on but the print itself.
///
/// This is the part that works on the first day, on a printer nobody has ever photographed, with no
/// model file and no marked frames. It learns what *this* print looks like while it is going well
/// (a few minutes is plenty) and then reports the moment the picture stops behaving that way.
///
/// Two things can be said from a fixed camera without knowing what a printer is:
///
/// - **Spaghetti** covers the bed in filament. The change stops being confined to the nozzle and
///   spreads over the whole frame, and the frame gets much busier than it has been all print.
/// - **The object coming off the bed** is one violent frame followed by a much emptier picture: what
///   was there is gone, so the detail drops well under what the print had settled at, and stays
///   there.
///
/// A layer shift was here too and has been taken out. It looked for the whole picture sliding
/// sideways, measured by lining up the columns of vertical edges, and on a real fleet it was wrong
/// almost every time it spoke: ten false alarms in half an hour across five printers that were all
/// printing perfectly. Measured afterwards on those very frames, a camera that had not moved at all
/// reported slides of seven pixels one way and eight the other. A global column correlation cannot
/// tell an object that moved from a toolhead that swept past, and a failure that only announces
/// itself when nothing is wrong is worse than no detector. Catching it properly means following the
/// object rather than the whole frame, which is a different piece of work and is not pretended here.
///
/// Every judgement is made against this print's own recent history rather than a fixed number, so a
/// dark chamber, a busy background or a camera that sees half the gantry does not have to be tuned
/// for. That also means the first few minutes are spent learning and say nothing.
///
/// The numbers below are measured, not guessed. On frames from five printers that were all printing
/// correctly, the spread of change between consecutive looks ran from 0.14 to 0.51, so a trigger of
/// 0.30 (which is what shipped first) sat in the middle of ordinary behaviour and fired constantly.
struct PrintBaseline {
    /// What one frame was worth saying about it, in the same shape a model would answer in.
    struct Reading: Equatable {
        var label: String?
        var confidence: Double
    }

    /// How many frames to watch before judging anything. Below this there is no history to be unusual
    /// against, and an early print is jumpy anyway.
    var warmUp: Int
    /// How much of the frame has to change at once before spread counts as bed-wide. Ordinary
    /// printing was measured up to 0.51, so this sits well clear of it rather than inside it.
    var spreadFloor: Float
    /// A brightness step this large means the light changed, not the print; that frame is skipped.
    var lightStep: Float

    init(warmUp: Int = 6, spreadFloor: Float = 0.70, lightStep: Float = 0.06) {
        self.warmUp = max(2, warmUp)
        self.spreadFloor = spreadFloor
        self.lightStep = lightStep
    }

    private var previous: [Float]?
    private var textures: [Float] = []
    private var spreads: [Float] = []
    /// Czy poprzednia klatka też wyglądała na pusty stół.
    private var wasEmptied = false
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
        let history = (textures: textures, spreads: spreads)
        remember(texture: texture, spread: churn.spread)
        guard history.textures.count >= warmUp else { return Reading(label: nil, confidence: 0) }

        let usualTexture = Self.median(history.textures)
        let usualSpread = Self.median(history.spreads)

        // Gone: a good part of the frame changed in one step and what is left is far plainer than
        // this print has ever been. A picture losing its detail is the one thing that does not
        // happen while something is being built, and it has to still be true on the next look: a
        // single bare frame is the toolhead parked in front of the lens.
        let bare = usualTexture > 0 && texture < usualTexture * 0.6
        // The frame it happens on is violent; the frame after is quiet, because what was moving has
        // gone. So the evidence is a collapse followed by a bed that stays bare, not two violent
        // frames in a row.
        let stillEmpty = bare && wasEmptied
        wasEmptied = bare && churn.amount > 0.10
        if stillEmpty {
            return Reading(label: DefectDataset.Label.detached.rawValue,
                           confidence: sureness(usualTexture / max(texture, 0.000_1), over: 1 / 0.6))
        }

        // Spaghetti: the change is everywhere instead of at the nozzle, and the frame is busier than
        // it has been. Both have to hold, because a camera that watches the gantry sweep sees wide
        // change on its own, and a print that simply grew detailed is not a failure.
        let spreadTrigger = min(0.95, max(spreadFloor, usualSpread * 2.2))
        if churn.spread >= spreadTrigger, usualTexture > 0, texture > usualTexture * 1.4 {
            // Spread cannot exceed 1, so the ratio used elsewhere would squeeze every possible
            // answer into the narrow band between the trigger and 0.71 and make the top half of the
            // sensitivity slider unreachable. What is left of the frame is the honest scale here.
            return Reading(label: DefectDataset.Label.spaghetti.rawValue,
                           confidence: sureness(churn.spread, between: spreadTrigger, and: 1))
        }

        return Reading(label: nil, confidence: 0)
    }

    /// A new print, or one that has been interrupted, starts with nothing learned.
    mutating func reset() {
        previous = nil
        textures.removeAll()
        spreads.removeAll()
        wasEmptied = false
    }

    /// Drops the history but keeps watching: for a frame that cannot be compared with the last one,
    /// such as the chamber light changing.
    private mutating func forget() {
        textures.removeAll()
        spreads.removeAll()
        wasEmptied = false
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
    /// The same idea for a value that cannot grow without bound: sitting on the trigger is a coin
    /// toss, reaching the ceiling is certain, and everything between is spread evenly.
    private func sureness(_ value: Float, between trigger: Float, and ceiling: Float) -> Double {
        guard ceiling > trigger else { return 0.5 }
        return Double(min(1, max(0, 0.5 + 0.5 * (value - trigger) / (ceiling - trigger))))
    }

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
