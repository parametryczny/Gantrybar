import CoreGraphics
import Testing
@testable import Gantry

/// Simulated desktops for the edge dock: which display it lands on and where. The same cases as the
/// Windows presentation tests and linux/tests/test_dock_placement.py.
@Suite struct EdgeDockPlacementTests {
    private func display(_ id: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                         primary: Bool = false) -> EdgeDockDisplay {
        let frame = CGRect(x: x, y: y, width: width, height: height)
        // 25 points of menu bar at the top, as on a Mac.
        return EdgeDockDisplay(id: id, name: id, pixelWidth: Int(width), pixelHeight: Int(height), frame: frame,
                               visibleFrame: CGRect(x: x, y: y, width: width, height: height - 25), isPrimary: primary)
    }

    @Test func noChoiceMeansTheMainDisplay() {
        let displays = [display("side", 1920, 0, 2560, 1440), display("main", 0, 0, 1920, 1080, primary: true)]
        let resolved = EdgeDockPlacement.resolve(displays: displays, savedID: "", savedFrame: nil)
        #expect(resolved?.display.id == "main")
        #expect(resolved?.matched == false)
        #expect(EdgeDockPlacement.resolve(displays: [], savedID: "", savedFrame: nil) == nil)
    }

    @Test func savedDisplayIsFoundByIdThenByFrameThenFallsBack() {
        let main = display("main", 0, 0, 1920, 1080, primary: true)
        let side = display("side", 1920, 0, 2560, 1440)
        let saved = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        #expect(EdgeDockPlacement.resolve(displays: [main, side], savedID: "side", savedFrame: saved)?.display.id == "side")
        // The system renumbered the display: its frame still finds it, a few points off included.
        let renamed = display("side-2", 1924, 0, 2560, 1440)
        let byFrame = EdgeDockPlacement.resolve(displays: [main, renamed], savedID: "side", savedFrame: saved)
        #expect(byFrame?.display.id == "side-2" && byFrame?.matched == true)
        // A new resolution on the same display keeps it.
        let resized = display("side", 1920, 0, 3840, 2160)
        #expect(EdgeDockPlacement.resolve(displays: [main, resized], savedID: "side", savedFrame: saved)?.display.id == "side")
        // Unplugged: the strip waits on the main display, and the choice is not reported as matched.
        let gone = EdgeDockPlacement.resolve(displays: [main], savedID: "side", savedFrame: saved)
        #expect(gone?.display.id == "main" && gone?.matched == false)
    }

    @Test func twinsWithTheSavedFrameResolveToTheMainDisplay() {
        let twinA = display("a", 0, 0, 1920, 1080)
        let twinB = display("b", 0, 0, 1920, 1080, primary: true)
        let resolved = EdgeDockPlacement.resolve(displays: [twinA, twinB], savedID: "gone",
                                                 savedFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(resolved?.display.id == "b")
    }

    @Test func rowsKeepClearOfCornersAndStayOnScreen() {
        let screen = display("main", 0, 0, 1000, 1025, primary: true)   // visible 0...1000
        let size = CGSize(width: 22, height: 100)
        let top = EdgeDockPlacement.origin(size: size, frame: screen.frame, visibleFrame: screen.visibleFrame, edge: .right, row: .top)
        #expect(top == CGPoint(x: 978, y: 700))            // strip top 200 below the visible top
        let middle = EdgeDockPlacement.origin(size: size, frame: screen.frame, visibleFrame: screen.visibleFrame, edge: .left, row: .middle)
        #expect(middle == CGPoint(x: 0, y: 450))
        let bottom = EdgeDockPlacement.origin(size: size, frame: screen.frame, visibleFrame: screen.visibleFrame, edge: .left, row: .bottom)
        #expect(bottom == CGPoint(x: 0, y: 200))
        // Unfolded taller than the room under the top anchor: it slides up rather than off the bottom.
        let tall = EdgeDockPlacement.origin(size: CGSize(width: 240, height: 900), frame: screen.frame,
                                            visibleFrame: screen.visibleFrame, edge: .right, row: .top)
        #expect(tall == CGPoint(x: 760, y: 0))
        let huge = EdgeDockPlacement.origin(size: CGSize(width: 240, height: 1200), frame: screen.frame,
                                            visibleFrame: screen.visibleFrame, edge: .right, row: .bottom)
        #expect(huge.y == -200)
    }

    @Test func innerEdgesAreTheOnesSharedWithAnotherDisplay() {
        let left = display("left", 0, 0, 1920, 1080, primary: true)
        let right = display("right", 1920, -200, 2560, 1440)
        let above = display("above", 0, 1080, 1920, 1080)
        let all = [left, right, above]
        #expect(EdgeDockPlacement.isInnerEdge(left, edge: .right, among: all))
        #expect(!EdgeDockPlacement.isInnerEdge(left, edge: .left, among: all))
        #expect(EdgeDockPlacement.isInnerEdge(right, edge: .left, among: all))
        #expect(!EdgeDockPlacement.isInnerEdge(right, edge: .right, among: all))
        // A display stacked above shares no side edge.
        #expect(!EdgeDockPlacement.isInnerEdge(above, edge: .right, among: [left, above]))
    }

    @Test func framesRoundTripAndChoicesKeepAnUnpluggedDisplay() {
        let frame = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        #expect(EdgeDockPlacement.parseFrame(EdgeDockPlacement.formatFrame(frame)) == frame)
        #expect(EdgeDockPlacement.parseFrame("1,2,0,4") == nil)
        #expect(EdgeDockPlacement.parseFrame("junk") == nil)
        let main = display("main", 0, 0, 1920, 1080, primary: true)
        let choices = EdgeDockPlacement.choices(displays: [main], savedID: "dell", savedName: "DELL U2723QE")
        #expect(choices.map(\.id) == ["", "main", "dell"])
        #expect(choices.filter(\.selected).map(\.id) == ["dell"])
        #expect(EdgeDockPlacement.choices(displays: [main], savedID: "", savedName: "").first?.selected == true)
    }
}
