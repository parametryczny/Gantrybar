import Testing
import AppKit
@testable import Gantry

/// Alerts must not end up behind Gantry's own windows. Reported 2026-09-22: the fleet window sat above
/// everything, so an alert opened underneath it and the user had to shuffle windows to find it.
@MainActor @Suite struct ModalHostTests {
    private func window(_ level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.level = level
        window.orderFront(nil)
        return window
    }

    @Test func raisedWindowsComeDownWhileAModalIsUpAndGoBackAfterwards() {
        let fleet = window(.floating)
        let dock = window(.statusBar)
        let ordinary = window(.normal)
        defer { [fleet, dock, ordinary].forEach { $0.orderOut(nil) } }

        var duringModal: [NSWindow.Level] = []
        ModalHost.run { duringModal = [fleet.level, dock.level, ordinary.level] }

        #expect(duringModal == [.normal, .normal, .normal], "something of Gantry's stayed above the alert")
        #expect(fleet.level == .floating, "the pinned fleet window was not put back")
        #expect(dock.level == .statusBar, "the edge dock was not put back")
        #expect(ordinary.level == .normal)
    }

    @Test func theModalsOwnResultIsPassedThrough() {
        #expect(ModalHost.run { 42 } == 42)
    }
}
