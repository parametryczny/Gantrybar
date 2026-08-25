import AppKit

/// Hosts the embedded Spoolbase filament-stock UI inside Gantry — one app, no separate process.
/// Shown as a popover anchored to the menu-bar (tray) icon, just like the Gantry dashboard, rather
/// than a floating window. Its data lives in the same ~/Library/Application Support/Spoolbase store
/// the standalone app used, so existing stock carries over.
@MainActor
final class SpoolbaseController {
    private let store = SpoolbaseShared.filaments
    private let popover = NSPopover()
    private var built = false

    /// Toggles the Spoolbase popover under the tray icon.
    func toggle(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        build()
        popover.appearance = AppSettings.shared.appearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func build() {
        guard !built else { return }
        built = true
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 500, height: 640)
        popover.contentViewController = MinimalFilamentPopoverViewController(
            store: store,
            onClose: { [weak self] in self?.popover.performClose(nil) },
            // Keep the popover open while one of Spoolbase's own sub-windows (catalog / editor /
            // limits) is on screen, then return to dismiss-on-click-away.
            onAuxiliaryState: { [weak self] isOpen in
                self?.popover.behavior = isOpen ? .applicationDefined : .transient
            }
        )
        _ = popover.contentViewController?.view   // warm the view up front
    }
}
