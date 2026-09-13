import AppKit

/// Hosts the Spoolbase filament-stock UI inside Gantry — one app, no separate process.
/// Its data lives in the same ~/Library/Application Support/Spoolbase store
/// the standalone app used, so existing stock carries over.
///
/// It used to follow Gantry's presentation mode: an overlay inside the floating window, or its own
/// popover hanging off the menu-bar icon. Both were the wrong shape for a stock list you work in for
/// minutes at a time, so it is a window now, like every other panel.
@MainActor
final class SpoolbaseController {
    private let store = SpoolbaseShared.filaments
    private var content: MinimalFilamentPopoverViewController?
    private var panel: PanelWindowController?

    func show() {
        if let panel, panel.window?.isVisible == true {
            panel.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        build()
        guard let content else { return }
        panel = PanelWindowController.present(content.view,
            title: AppSettings.shared.t("Spoolbase — filament stock"),
            size: NSSize(width: 500, height: 640),
            onDismiss: { [weak self] in self?.dismiss() })
    }

    func dismiss() {
        content?.dismissEmbeddedQuickStock()
        let panel = self.panel
        self.panel = nil
        panel?.dismiss()
    }

    private func build() {
        guard content == nil else { return }
        content = MinimalFilamentPopoverViewController(
            store: store,
            onClose: { [weak self] in self?.dismiss() },
            // Spoolbase's own sub-windows (catalog / editor / limits) are ordinary windows over an
            // ordinary window now, so nothing has to be held open while one of them is up.
            onAuxiliaryState: { _ in }
        )
        _ = content?.view   // warm the view up front
    }
}
