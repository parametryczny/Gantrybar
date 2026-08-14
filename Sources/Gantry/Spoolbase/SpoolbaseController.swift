import AppKit

/// Hosts the embedded Spoolbase filament-stock UI inside Gantry — one app, no separate process.
/// Opened from the tray menu ("Spoolbase — magazyn filamentów"); its data lives in the same
/// ~/Library/Application Support/Spoolbase store the standalone app used, so existing stock carries over.
@MainActor
final class SpoolbaseController {
    private let store = FilamentStore()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = MinimalFilamentPopoverViewController(
            store: store,
            onClose: { [weak self] in self?.window?.performClose(nil) },
            onAuxiliaryState: { _ in }   // no popover to keep open — the window stays put on its own
        )

        let window = NSWindow(contentViewController: controller)
        window.title = "Spoolbase"
        window.titleVisibility = .hidden   // the content has its own "Spoolbase" heading; don't overlap it
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 500, height: 640))
        window.center()
        window.appearance = AppSettings.shared.appearance
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
