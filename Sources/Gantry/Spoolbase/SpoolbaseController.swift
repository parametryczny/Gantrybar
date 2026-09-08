import AppKit

/// Hosts the embedded Spoolbase filament-stock UI inside Gantry — one app, no separate process.
/// Follows Gantry's presentation mode: embedded in its window or anchored to the menu-bar icon.
/// Its data lives in the same ~/Library/Application Support/Spoolbase store
/// the standalone app used, so existing stock carries over.
@MainActor
final class SpoolbaseController {
    private let store = SpoolbaseShared.filaments
    private let popover = NSPopover()
    private var built = false
    private var content: MinimalFilamentPopoverViewController?
    private var embeddedPanel: NSView?

    func show(in host: NSView) {
        build()
        popover.performClose(nil)
        dismissEmbedded()
        guard let content else { return }
        popover.contentViewController = nil
        embeddedPanel = EmbeddedPanelView.show(content.view, in: host,
            size: NSSize(width: 500, height: 640), fillsViewport: true) { [weak self] in self?.dismissEmbedded() }
    }

    func dismissEmbedded() {
        content?.dismissEmbeddedQuickStock()
        embeddedPanel?.removeFromSuperview()
        embeddedPanel = nil
    }

    /// Toggles the Spoolbase popover under the tray icon.
    func toggle(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        build()
        dismissEmbedded()
        popover.contentViewController = content
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
        content = MinimalFilamentPopoverViewController(
            store: store,
            onClose: { [weak self] in
                self?.dismissEmbedded()
                self?.popover.performClose(nil)
            },
            // Keep the popover open while one of Spoolbase's own sub-windows (catalog / editor /
            // limits) is on screen, then return to dismiss-on-click-away.
            onAuxiliaryState: { [weak self] isOpen in
                self?.popover.behavior = isOpen ? .applicationDefined : .transient
            }
        )
        popover.contentViewController = content
        _ = popover.contentViewController?.view   // warm the view up front
    }
}
