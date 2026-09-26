import AppKit
import Combine

/// The full Gantry fleet dashboard in an independent, freely resizable window. It intentionally owns
/// a second `PrinterDashboardViewController` rather than a separate widget UI, so cards, telemetry,
/// Spoolbase assignment and future dashboard changes stay identical to the menu-bar panel.
@MainActor
final class FloatingDashboardWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "GantryFloatingDashboardWindow"
    private let dashboard: PrinterDashboardViewController
    private let workspace: GantryWorkspaceViewController
    private var subscriptions = Set<AnyCancellable>()
    private var embeddedController: NSViewController?
    private var embeddedPanel: NSView?

    func present(_ controller: NSViewController, size: NSSize, fillsViewport: Bool = true) {
        restoreFromDock()
        dismissEmbeddedPanel()
        embeddedController = controller
        dashboard.addChild(controller)
        _ = workspace.present(content: controller.view, name: "Drukarka", size: size, accessories: [], onDismiss: { [weak self] in
            self?.embeddedController?.removeFromParent()
            self?.embeddedController = nil
        })
    }

    func showOnboarding() { dashboard.showOnboarding() }

    func dismissEmbeddedPanel() {
        workspace.dismissPanel()
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
        onShowSettings: @escaping () -> Void,
        onNavigate: @escaping (WorkspaceSection) -> Void = { _ in }
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

        workspace = GantryWorkspaceViewController(dashboard: dashboard, store: store)
        workspace.onNavigate = onNavigate

        let panel = FloatingDashboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 400),   // two cards: 20 + 2 × 325 + the 12 pt gap
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
        panel.contentMinSize = NSSize(width: 403, height: 340)
        panel.contentViewController = workspace

        super.init(window: panel)
        panel.delegate = self
        workspace.onNeedsSize = { [weak self] size in self?.ensureWorkspaceSize(size) }
        // The system window owns its size. Card measurements must never resize its parent.
        dashboard.setPreferredContentSizeHandler { _ in }
        let screen = panel.screen ?? NSScreen.main
        let room = (screen?.visibleFrame ?? NSRect(x:0,y:0,width:1280,height:800)).insetBy(dx:20,dy:20)
        let scale = CGFloat(AppSettings.shared.cardScalePercent)/100
        let pitch = (325 + GantryTheme.cardGap)*scale
        let base = (20-GantryTheme.cardGap)*scale + GantryWorkspaceViewController.railWidth + 1
        let count = max(1,store.printers.count)
        let availableColumns = max(1,Int((room.width-base)/pitch))
        let columns = min(availableColumns,max(1,Int(ceil(sqrt(Double(count))))))
        let rows = Int(ceil(Double(count)/Double(columns)))
        let width = min(room.width,base + CGFloat(columns)*pitch + 2)
        let height = min(room.height,110 + CGFloat(rows)*230*scale)
        panel.setFrame(NSRect(x:room.midX-width/2,y:room.midY-height/2,width:width,height:height),display:false)
        panel.setFrameAutosaveName(Self.frameAutosaveName)

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
            PanelWindowController.workspacePresenter = nil
            workspace.dismissPanel()
            dismissEmbeddedPanel()
            DiagnosticCenterViewController.dismiss()
            FleetStatsViewController.dismiss()
            panel.orderOut(nil)
            return
        }
        PanelWindowController.workspacePresenter = { [weak self] content, name, size, accessories, onDismiss in
            guard let self else { return PanelWindowController.embedded(onDismiss: onDismiss) }
            self.restoreFromDock()
            return self.workspace.present(content: content, name: name, size: size, accessories: accessories, onDismiss: onDismiss)
        }
        panel.appearance = AppSettings.shared.appearance
        dashboard.view.appearance = AppSettings.shared.appearance
        dashboard.applyPanelTransparency()
        showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    private func ensureWorkspaceSize(_ desired: NSSize) {
        guard let panel = window else { return }
        let available = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let current = panel.contentView?.bounds.size ?? .zero
        let size = NSSize(width: min(available.width - 40, max(current.width, desired.width)),
                          height: min(available.height - 70, max(current.height, desired.height)))
        panel.setContentSize(size)
        var origin = panel.frame.origin
        origin.x = min(max(origin.x, available.minX), available.maxX-panel.frame.width)
        origin.y = min(max(origin.y, available.minY), available.maxY-panel.frame.height)
        panel.setFrameOrigin(origin)
    }

    func presentWorkspace(_ content: NSView, name: String, size: NSSize, onDismiss: @escaping () -> Void = {}) {
        restoreFromDock()
        _ = workspace.present(content: content, name: name, size: size, accessories: [], onDismiss: onDismiss)
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
        guard let panel=window, !panel.isZoomed, !panel.styleMask.contains(.fullScreen),
              let visible=panel.screen?.visibleFrame else {return}
        var frame=panel.frame
        frame.size.width=min(frame.width,visible.width)
        frame.size.height=min(frame.height,visible.height)
        frame.origin.x=max(visible.minX,min(frame.minX,visible.maxX-frame.width))
        frame.origin.y=max(visible.minY,min(frame.minY,visible.maxY-frame.height))
        if panel.frame != frame {panel.setFrame(frame,display:true)}
    }

    private func fitHeightToCards(_ requestedHeight: CGFloat) {
        guard let panel = window, !panel.inLiveResize, !panel.isZoomed, !workspace.hasPanel else { return }
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
