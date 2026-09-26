import AppKit

/// Where every alert in Gantry goes, so none of them can end up behind one of Gantry's own windows.
///
/// Reported 2026-09-22: an alert opened underneath the fleet window and the user had to shuffle
/// windows to find out that anything had been asked at all. The cause is window levels. macOS stacks
/// windows by level before anything else, and Gantry deliberately raises two of them: the fleet window
/// when the user pins it on top, and the edge dock, which is a strip on a screen edge and belongs above
/// ordinary windows the way the Dock does. An alert is an ordinary window, so a raised window covers it,
/// however modal the alert is.
///
/// So for as long as an alert is on screen, every Gantry window that sits above the ordinary level comes
/// down to it, and goes back up afterwards. Nothing else about them changes: the dock stays where it is,
/// the pin stays on, and the user is not left hunting for a dialog.
@MainActor
enum ModalHost {
    /// Runs an alert with nothing of Gantry's in front of it. Use this instead of a bare runModal().
    @discardableResult
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let restore = lowerRaisedWindows()
        defer { restore() }
        // A menu-bar app can be running with no window in front; without this the alert can open
        // behind the app the user is actually looking at.
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    /// Runs any other app-modal window (an open panel, a sheetless dialog) under the same promise.
    @discardableResult
    static func run<T>(_ body: () -> T) -> T {
        let restore = lowerRaisedWindows()
        defer { restore() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        return body()
    }

    /// Brings every window above the ordinary level down to it and hands back the undo.
    private static func lowerRaisedWindows() -> () -> Void {
        let ordinary = NSWindow.Level.normal
        // NSApplication.shared, not NSApp: the global is nil until something touches the shared
        // instance, and a check that runs before the app is up must not bring the process down.
        let raised = NSApplication.shared.windows.filter { $0.isVisible && $0.level.rawValue > ordinary.rawValue }
        let previous = raised.map { ($0, $0.level) }
        for window in raised { window.level = ordinary }
        return {
            for (window, level) in previous where window.isVisible || window.level != level {
                window.level = level
            }
        }
    }
}
