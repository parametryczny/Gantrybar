import AppKit
import Combine

/// The full Gantry fleet dashboard in an independent, freely resizable window. It intentionally owns
/// a second `PrinterDashboardViewController` rather than a separate widget UI, so cards, telemetry,
/// Spoolbase assignment and future dashboard changes stay identical to the menu-bar panel.
@MainActor
final class FloatingDashboardWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "GantryFloatingDashboardWindow"
    private let dashboard: PrinterDashboardViewController
    private var subscriptions = Set<AnyCancellable>()
    private var embeddedController: NSViewController?
    private var embeddedPanel: NSView?

    func present(_ controller: NSViewController, size: NSSize, fillsViewport: Bool = true) {
        restoreFromDock()
        dismissEmbeddedPanel()
        guard let host = window?.contentView else { return }
        embeddedController = controller
        dashboard.addChild(controller)
        embeddedPanel = EmbeddedPanelView.show(controller.view, in: host, size: size,
                                               fillsViewport: fillsViewport) { [weak self] in
            self?.dismissEmbeddedPanel()
        }
    }

    func showOnboarding() { dashboard.showOnboarding() }

    func dismissEmbeddedPanel() {
        MaintenancePanelViewController.dismiss()
        embeddedPanel?.removeFromSuperview()
        embeddedPanel = nil
        embeddedController?.removeFromParent()
        embeddedController = nil
    }

    init(
        store: PrinterStore,
        onAdd: @escaping () -> Void,
        onEdit: @escaping (SavedPrinter) -> Void,
        onReconnect: @escaping (SavedPrinter) -> Void,
        onShowDetails: @escaping (String) -> Void,
        onSkipObjects: @escaping (String) -> Void,
        onShowSettings: @escaping () -> Void
    ) {
        dashboard = PrinterDashboardViewController(
            store: store,
            onAdd: onAdd,
            onEdit: onEdit,
            onReconnect: onReconnect,
            onShowDetails: onShowDetails,
            onSkipObjects: onSkipObjects,
            onShowSettings: onShowSettings,
            presentation: .floatingWindow,
            onPreferredContentSize: { _ in }
        )

        let panel = FloatingDashboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.title = "Gantry"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // Only the native title bar moves the window. Background dragging steals the drag handle's
        // mouse sequence before it can start a printer-reordering session.
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentMinSize = NSSize(width: 305, height: 290)
        panel.contentViewController = dashboard

        super.init(window: panel)
        panel.delegate = self
        dashboard.setPreferredContentSizeHandler { [weak self] size in
            self?.fitHeightToCards(size.height)
        }

        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            panel.center()
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        DispatchQueue.main.async { [weak self] in self?.snapWindowToTiles() }

        AppSettings.shared.$floatingWindowEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncVisibility() }
            .store(in: &subscriptions)
        AppSettings.shared.$floatingWindowAlwaysOnTop
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyWindowLevel() }
            .store(in: &subscriptions)
        AppSettings.shared.$cardScalePercent
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.snapWindowToTiles() }
            }
            .store(in: &subscriptions)

        applyWindowLevel()
        syncVisibility()
    }

    required init?(coder: NSCoder) { nil }

    private func syncVisibility() {
        guard let panel = window else { return }
        guard AppSettings.shared.floatingWindowEnabled else {
            dismissEmbeddedPanel()
            DiagnosticCenterViewController.dismiss()
            FleetStatsViewController.dismiss()
            panel.orderOut(nil)
            return
        }
        panel.appearance = AppSettings.shared.appearance
        dashboard.view.appearance = AppSettings.shared.appearance
        dashboard.applyPanelTransparency()
        showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    private func applyWindowLevel() {
        guard let panel = window else { return }
        if AppSettings.shared.floatingWindowAlwaysOnTop {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            panel.level = .normal
            panel.collectionBehavior = [.managed]
        }
    }

    /// The close traffic light hides the dashboard but keeps the app in window mode and in the Dock.
    /// Only the explicit Settings switch is allowed to return Gantry to menu-bar/popover mode.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        dashboard.dismissOnboarding()
        return false
    }

    func restoreFromDock() {
        guard AppSettings.shared.floatingWindowEnabled, let panel = window else { return }
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        syncVisibility()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Keep the native drag responsive. Quantization while the pointer was still moving made the
        // window feel locked until the cursor crossed half a card in one frame.
        frameSize
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        snapWindowToTiles()
    }

    private func snapWindowToTiles() {
        guard let panel = window, !panel.isZoomed else { return }
        let current = panel.contentView?.bounds.size ?? panel.contentRect(forFrameRect: panel.frame).size
        panel.setContentSize(dashboard.snappedFloatingContentSize(for: current))
        DispatchQueue.main.async { [weak self] in self?.dashboard.refreshFloatingContentSize() }
    }

    private func fitHeightToCards(_ requestedHeight: CGFloat) {
        guard let panel = window, !panel.inLiveResize, !panel.isZoomed else { return }
        let current = panel.contentView?.bounds.size ?? panel.contentRect(forFrameRect: panel.frame).size
        guard abs(current.height - requestedHeight) > 0.5 else { return }
        let oldTop = panel.frame.maxY
        panel.setContentSize(NSSize(width: current.width, height: requestedHeight))
        var frame = panel.frame
        frame.origin.y = oldTop - frame.height
        if let visible = panel.screen?.visibleFrame {
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrameOrigin(frame.origin)
    }
}

private final class FloatingDashboardPanel: NSPanel {
    #if GANTRY_RENDER
    // Offscreen rendering has no usable desktop bounds; keep the requested test viewport.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    #endif
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
