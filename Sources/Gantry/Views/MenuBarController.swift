import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: PrinterStore
    private static let statusAutosaveName = "GantryStatusItemV2"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var progressItems: [String: NSStatusItem] = [:]
    private var dashboardViewController: NSViewController?
    private var detailViewController: PrinterDetailViewController?
    private var skipObjectsViewController: SkipObjectsViewController?
    private var automationsWindows: [String: AutomationsWindowController] = [:]
    private var advancedWindows: [String: PrinterAdvancedWindowController] = [:]
    private var dashboardContentSize = NSSize(width: 540, height: 650)
    private var suppressFleetReset = false
    private let popover = NSPopover()
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var addWindow: AddPrinterWindowController?
    private var settingsWindow: SettingsWindowController?
    private let spoolbase = SpoolbaseController()
    private var notificationObserver: Any?
    private var updateNotificationObserver: Any?
    private var edgeDock: EdgeDockWindowController?
    private var floatingDashboard: FloatingDashboardWindowController?

    init(store: PrinterStore) {
        self.store = store
        super.init()

        // macOS 27 keeps drifting the menu-bar item to the far-left on relaunch: on quit it writes a
        // stale position back under the autosave key, and a nil-guarded seed then never corrects it.
        // So we pin the preferred position near the clock on *every* launch (points measured from the
        // right edge), not just the first. Trade-off: a manual ⌘-drag won't survive a relaunch, but the
        // item reliably reappears by the clock — which is the behaviour that kept regressing.
        let positionKey = "NSStatusItem Preferred Position \(Self.statusAutosaveName)"
        UserDefaults.standard.set(88, forKey: positionKey)
        statusItem.autosaveName = Self.statusAutosaveName

        let dashboard = PrinterDashboardViewController(
            store: store,
            onAdd: { [weak self] in self?.showAddPrinter() },
            onEdit: { [weak self] printer in self?.showEditPrinter(printer) },
            onReconnect: { [weak store] printer in store?.reconnect(printer) },
            onShowDetails: { [weak self] serial in self?.showDetails(serial: serial) },
            onSkipObjects: { [weak self] serial in self?.showSkipObjects(serial: serial) },
            onPreferredContentSize: { [weak self] size in
                guard let self else { return }
                self.dashboardContentSize = size
                // Ignore while the detail view owns the popover, so it doesn't fight for size.
                guard self.detailViewController == nil, self.popover.contentSize != size else { return }
                self.popover.contentSize = size
            }
        )
        dashboardViewController = dashboard
        popover.contentSize = NSSize(width: 540, height: 650)
        popover.contentViewController = dashboard
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = AppSettings.shared.appearance
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem()
        updateProgressItems()
        subscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
                self?.updateProgressItems()
            }
        }
        settingsSubscription = AppSettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                if AppSettings.shared.floatingWindowEnabled { self?.closePopover() }
                else { self?.spoolbase.dismissEmbedded() }
                self?.popover.appearance = AppSettings.shared.appearance
                self?.popover.contentViewController?.view.appearance = AppSettings.shared.appearance
                self?.applyPanelStyle()
                self?.updateStatusItem()
                self?.updateProgressItems()
            }
        }
        // Optional always-on-top strip at a screen edge. It owns its own visibility, so it is safe to
        // create unconditionally: with the setting off it simply never orders itself in. LITE has one
        // surface only — the menu-bar popover — so neither extra window is built there.
        if Build.hasExtras {
            edgeDock = EdgeDockWindowController(store: store) { [weak self] serial in
                self?.revealDetails(serial: serial)
            }
            floatingDashboard = FloatingDashboardWindowController(
                store: store,
                onAdd: { [weak self] in self?.showAddPrinter() },
                onEdit: { [weak self] printer in self?.showEditPrinter(printer) },
                onReconnect: { [weak store] printer in store?.reconnect(printer) },
                onShowDetails: { [weak self] serial in self?.revealDetails(serial: serial) },
                onSkipObjects: { [weak self] serial in self?.showSkipObjects(serial: serial) },
                onShowSettings: { [weak self] in self?.showSettings() }
            )
        }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .gantryShowDashboard, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.showDashboard() }
        }
        if Build.hasExtras {
            updateNotificationObserver = NotificationCenter.default.addObserver(
                forName: .gantryCheckForUpdates, object: nil, queue: .main
            ) { _ in
                DispatchQueue.main.async { UpdatePresenter.checkAndPresent(from: nil) }
            }
        }
    }

    /// The status-bar button to anchor menus/popovers to. When printers are pinned the main Gantry
    /// icon is hidden, so fall back to the first visible pinned indicator.
    private var anchorButton: NSStatusBarButton? {
        statusItem.isVisible ? statusItem.button : progressItems.values.first?.button
    }

    func showDashboard() {
        if AppSettings.shared.floatingWindowEnabled {
            floatingDashboard?.restoreFromDock()
            return
        }
        guard let button = anchorButton, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.appearance = AppSettings.shared.appearance
        popover.contentViewController?.view.appearance = AppSettings.shared.appearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Called when the user clicks Gantry in the Dock while the detached-window mode is active.
    func restoreFloatingDashboardFromDock() {
        floatingDashboard?.restoreFromDock()
    }

    // Native application-menu equivalents of the status item's right-click menu. These are kept on
    // the controller so both entry points use exactly the same stores, windows and popover flows.
    @objc func appMenuShowPrinters(_ sender: Any?) {
        if AppSettings.shared.floatingWindowEnabled { floatingDashboard?.restoreFromDock() }
        else { showPopoverFromMenu() }
    }
    @objc func appMenuShowSpoolbase(_ sender: Any?) {
        showSpoolbase()
    }

    private func showSpoolbase() {
        guard AppSettings.shared.spoolbaseEnabled else { return }
        if AppSettings.shared.floatingWindowEnabled {
            closePopover()
            floatingDashboard?.restoreFromDock()
            if let host = floatingDashboard?.window?.contentView { spoolbase.show(in: host) }
        } else if let button = anchorButton {
            spoolbase.toggle(from: button)
        }
    }
    @objc func appMenuSearchPrinters(_ sender: Any?) { store.scan() }
    @objc func appMenuAddPrinter(_ sender: Any?) { showAddPrinter() }
    @objc func appMenuReconnectAll(_ sender: Any?) { store.reconnectAll() }
    @objc func appMenuDiagnostics(_ sender: Any?) { showDiagnostics() }
    @objc func appMenuFleetStats(_ sender: Any?) { showFleetStats() }
    @objc func appMenuCycleLanguage(_ sender: Any?) {
        let codes = Localization.available().map(\.code)
        guard !codes.isEmpty else { return }
        let next = codes.firstIndex(of: AppSettings.shared.language).map { ($0 + 1) % codes.count } ?? 0
        AppSettings.shared.language = codes[next]
    }
    @objc func appMenuToggleQuietHours(_ sender: Any?) {
        QuietHours.isEnabled.toggle()
        AppSettings.shared.objectWillChange.send()
    }
    @objc func appMenuCheckForUpdates(_ sender: Any?) { UpdatePresenter.checkAndPresent(from: nil) }
    @objc func appMenuSettings(_ sender: Any?) { showSettings() }
    @objc func appMenuOnboarding(_ sender: Any?) {
        if AppSettings.shared.floatingWindowEnabled {
            floatingDashboard?.restoreFromDock()
            floatingDashboard?.showOnboarding()
        } else {
            returnToFleet()
            showDashboard()
            (dashboardViewController as? PrinterDashboardViewController)?.showOnboarding()
        }
    }
    @objc func appMenuBuyCoffee(_ sender: Any?) {
        if let url = URL(string: "https://buycoffee.to/parametryczny") { NSWorkspace.shared.open(url) }
    }
    @objc func appMenuQuit(_ sender: Any?) { NSApplication.shared.terminate(nil) }

    /// Pinned printers, in the dashboard's order. The first one rides on the MAIN status item (so it
    /// replaces the Gantry icon in place, near the clock); any others get their own extra items.
    private func orderedPinned() -> [String] {
        let valid = store.printers.map(\.serial)
        MenuBarProgressPreference.prune(keeping: valid)
        let pinnedSet = Set(MenuBarProgressPreference.serials())
        return valid.filter(pinnedSet.contains)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if let first = orderedPinned().first {
            // The main icon becomes the first pinned printer's live progress — no separate extra icon,
            // and it keeps the main item's spot next to the clock.
            let printer = store.printers.first { $0.serial == first }
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = pinnedTitle(name: printer?.name ?? first, telemetry: store.telemetry[first])
            button.toolTip = printer?.name
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.image = GantryLogo.statusItemImage(height: 14)
            button.imagePosition = .imageOnly
            button.toolTip = store.activePrintCount > 0
                ? AppSettings.shared.t("Gantry — printing: {0}", store.activePrintCount)
                : Build.appName
        }
    }

    /// One extra status item per pinned printer BEYOND the first (the first rides on the main icon).
    /// Reconciled on every store change so it follows added/removed/renamed printers.
    private func updateProgressItems() {
        let extras = Array(orderedPinned().dropFirst())
        let extrasSet = Set(extras)

        for (serial, item) in progressItems where !extrasSet.contains(serial) {
            NSStatusBar.system.removeStatusItem(item)
            progressItems[serial] = nil
        }
        for serial in extras {
            let item = progressItems[serial] ?? makeProgressItem(serial: serial)
            progressItems[serial] = item
            guard let button = item.button else { continue }
            let printer = store.printers.first { $0.serial == serial }
            button.attributedTitle = pinnedTitle(name: printer?.name ?? serial, telemetry: store.telemetry[serial])
            button.toolTip = printer?.name
        }
    }

    private func makeProgressItem(serial: String) -> NSStatusItem {
        // Give each indicator a stable identity + a right-leaning seed position so it lands near the
        // clock (where the main icon sat), not at the far-left end of the status area. macOS remembers
        // any later ⌘-drag per autosaveName.
        let autosave = "GantryProgress-\(serial)"
        let positionKey = "NSStatusItem Preferred Position \(autosave)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(88, forKey: positionKey)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = autosave
        item.button?.target = self
        item.button?.action = #selector(progressItemClicked(_:))
        // The pinned indicator replaces the main Gantry icon, so it must also expose the app menu on
        // right-click (Settings, Quit, …), not just open the popover on left-click.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return item
    }

    private func progressTitle(name: String, telemetry: PrinterTelemetry?) -> String {
        guard let telemetry else { return name }
        switch telemetry.state {
        case .printing, .paused: return "\(name) \(telemetry.progress)%"
        default: return name
        }
    }

    /// A pinned printer's label with a leading status-coloured dot (blue printing / green ready /
    /// orange paused / red error / grey offline), like the dots on the dashboard cards. The name
    /// itself keeps the menu bar's own colour so it stays legible in light and dark menu bars.
    private func pinnedTitle(name: String, telemetry: PrinterTelemetry?) -> NSAttributedString {
        let dotColor: NSColor
        switch telemetry?.state {
        case .printing: dotColor = .systemBlue
        case .finished, .idle: dotColor = .systemGreen
        case .paused: dotColor = .systemOrange
        case .error: dotColor = .systemRed
        case .offline, .none: dotColor = .systemGray
        }
        let result = NSMutableAttributedString(string: "● ", attributes: [
            .foregroundColor: dotColor,
            .font: NSFont.systemFont(ofSize: 9)
        ])
        result.append(NSAttributedString(string: progressTitle(name: name, telemetry: telemetry)))
        return result
    }

    @objc private func progressItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            if popover.isShown { closePopover() }
            showContextMenu(relativeTo: sender)
            return
        }
        if AppSettings.shared.floatingWindowEnabled { showDashboard(); return }
        if popover.isShown { closePopover(); return }
        popover.appearance = AppSettings.shared.appearance
        popover.contentViewController?.view.appearance = AppSettings.shared.appearance
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        installOutsideClickMonitor()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            if popover.isShown { closePopover() }
            showContextMenu(relativeTo: button)
            return
        }
        if AppSettings.shared.floatingWindowEnabled { showDashboard(); return }
        if popover.isShown {
            closePopover()
        } else {
            popover.appearance = AppSettings.shared.appearance
            popover.contentViewController?.view.appearance = AppSettings.shared.appearance
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitor()
        }
    }

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        let settings = AppSettings.shared
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(row(icon: "printer.fill", tint: Self.accentTint,
                         title: settings.t("Show printers")) { [weak self] in
            self?.showPopoverFromMenu()
        })
        if Build.hasExtras {
            menu.addItem(row(icon: "questionmark.circle", title: settings.t("How to read Gantry")) { [weak self] in
                self?.appMenuOnboarding(nil)
            })
        }

        if Build.hasExtras, settings.spoolbaseEnabled {
            menu.addItem(row(icon: "shippingbox.fill",
                             title: settings.t("Spoolbase — filament stock")) { [weak self] in
                self?.showSpoolbase()
            })
        }

        menu.addItem(.separator())

        menu.addItem(row(icon: "antenna.radiowaves.left.and.right",
                         title: settings.t("Search printers…"),
                         enabled: !store.isScanning) { [weak self] in
            self?.store.scan()
        })
        menu.addItem(row(icon: "plus",
                         title: settings.t("Add printer…")) { [weak self] in
            self?.showAddPrinter()
        })
        menu.addItem(row(icon: "arrow.clockwise",
                         title: settings.t("Reconnect (all)"),
                         enabled: !store.printers.isEmpty) { [weak self] in
            self?.store.reconnectAll()
        })
        if Build.hasExtras {
            menu.addItem(row(icon: "stethoscope",
                             title: settings.t("Diagnostic Center…")) { [weak self] in
                self?.showDiagnostics()
            })
            menu.addItem(row(icon: "chart.bar",
                             title: settings.t("Fleet statistics…")) { [weak self] in
                self?.showFleetStats()
            })
        }

        menu.addItem(.separator())

        menu.addItem(row(icon: "globe",
                         title: settings.t("Language"),
                         accessory: .value(settings.language.uppercased())) {
            // Cycles through the installed catalogs, so a dropped-in language is reachable here too.
            let codes = Localization.available().map(\.code)
            let next = codes.firstIndex(of: AppSettings.shared.language).map { ($0 + 1) % codes.count } ?? 0
            AppSettings.shared.language = codes[next]
        })
        menu.addItem(row(icon: QuietHours.isEnabled ? "moon.fill" : "moon",
                         title: settings.t("Quiet hours"),
                         accessory: .detail(QuietHours.isEnabled ? QuietHours.rangeLabel() : settings.t("off"))) {
            QuietHours.isEnabled.toggle()
        })
        if Build.hasExtras {
            menu.addItem(row(icon: "arrow.down.circle",
                             title: settings.t("Check for updates…"),
                             accessory: .detail("v\(UpdateService.currentVersion)")) {
                UpdatePresenter.checkAndPresent(from: nil)
            })
        }
        menu.addItem(row(icon: "gearshape",
                         title: settings.t("Settings…"),
                         accessory: .detail("⌘,")) { [weak self] in
            self?.showSettings()
        })

        // Every icon in this menu is drawn by a custom row view; a plain NSMenuItem's native image
        // doesn't render here, and a view-based item won't open a submenu on hover. So the icon is an
        // emoji in the title — it always renders and keeps the row expandable.
        let legendItem = NSMenuItem(title: settings.t("🎨  Colour legend"),
                                    action: nil, keyEquivalent: "")
        legendItem.submenu = colourLegendMenu(settings: settings)
        menu.addItem(legendItem)

        menu.addItem(row(icon: "cup.and.saucer.fill",
                         title: settings.t("Buy me a coffee ☕️")) {
            if let url = URL(string: "https://buycoffee.to/parametryczny") { NSWorkspace.shared.open(url) }
        })

        menu.addItem(.separator())

        menu.addItem(row(icon: "power",
                         title: settings.t("Quit Gantry"),
                         accessory: .detail("⌘Q")) {
            NSApplication.shared.terminate(nil)
        })

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 3), in: button)
    }

    /// Expandable colour legend explaining what each status colour on the cards means. Emoji dots keep
    /// the colours crisp inside the submenu without custom drawing.
    private func colourLegendMenu(settings: AppSettings) -> NSMenu {
        let statusEntries: [(String, String)] = [
            ("🔵", settings.t("Printing (live data)")),
            ("🟢", settings.t("Ready / finished")),
            ("🟠", settings.t("Attention: stale data, paused, or AMS humidity")),
            ("🔴", settings.t("Printer error")),
            ("⚪", settings.t("Offline / none / neutral")),
        ]
        // Slot markers explain the small cues drawn on the filament swatches themselves.
        let slotEntries: [(String, String)] = [
            ("⭕", settings.t("AMS slot with a white ring — active (printing from it)")),
            ("🔴", settings.t("Red dot on a slot — low filament (≤15%)")),
        ]
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        func addEntry(_ dot: String, _ text: String) {
            let item = NSMenuItem(title: "\(dot)  \(text)", action: nil, keyEquivalent: "")
            item.isEnabled = true   // no action; kept enabled so the emoji dot stays full-colour
            submenu.addItem(item)
        }
        for (dot, text) in statusEntries { addEntry(dot, text) }
        submenu.addItem(.separator())
        let header = NSMenuItem(title: settings.t("Filament slots:"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)
        for (dot, text) in slotEntries { addEntry(dot, text) }
        return submenu
    }

    /// Warm coral tint used to highlight the primary "show printers" row, echoing the app icon.
    private static let accentTint = NSColor(calibratedRed: 0.91, green: 0.57, blue: 0.49, alpha: 1)

    private func row(icon: String, tint: NSColor = .secondaryLabelColor, title: String,
                     accessory: MenuRowView.Accessory = .none, enabled: Bool = true,
                     actions: [MenuRowView.Action] = [],
                     onSelect: (() -> Void)? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem()
        menuItem.view = MenuRowView(icon: icon, tint: tint, title: title, accessory: accessory,
                                    enabled: enabled, actions: actions, onSelect: onSelect)
        return menuItem
    }


    @objc private func showPopoverFromMenu() {
        if AppSettings.shared.floatingWindowEnabled { showDashboard(); return }
        guard let button = anchorButton else { return }
        popover.appearance = AppSettings.shared.appearance
        popover.contentViewController?.view.appearance = AppSettings.shared.appearance
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installOutsideClickMonitor()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(store: store)
            controller.onClose = { [weak self] in
                // A transient popover normally closes as soon as the settings window becomes key.
                // Restore that native behaviour only after settings are gone, so the cards stay on
                // screen while their scale is being adjusted.
                self?.popover.behavior = .transient
            }
            settingsWindow = controller
        }

        // The panel stays where it is, next to the menu bar, and settings open centred on the screen
        // instead of on top of it. Only the window level is borrowed, so the panel cannot cover them.
        let companion: NSWindow?
        if AppSettings.shared.floatingWindowEnabled {
            floatingDashboard?.restoreFromDock()
            companion = floatingDashboard?.window
        } else {
            if !popover.isShown { showPopoverFromMenu() }
            popover.behavior = .applicationDefined
            companion = popover.contentViewController?.view.window
        }
        settingsWindow?.presentCentered(levelMatching: companion)
    }

    /// Resolve the presentation mode at execution time, including actions from the Dock or menu.
    private func withDashboardHost(_ present: @escaping (NSView) -> Void) {
        if AppSettings.shared.floatingWindowEnabled {
            closePopover()
            floatingDashboard?.restoreFromDock()
            if let host = floatingDashboard?.window?.contentView { present(host) }
        } else {
            if !popover.isShown { showPopoverFromMenu() }
            DispatchQueue.main.async { [weak self] in
                guard let host = self?.popover.contentViewController?.view else { return }
                present(host)
            }
        }
    }

    @objc private func showFleetStats() {
        withDashboardHost { [weak self] host in
            guard let self else { return }
            DiagnosticCenterViewController.dismiss()
            FleetStatsViewController.show(store: self.store, in: host)
        }
    }

    @objc private func showDiagnostics() {
        withDashboardHost { [weak self] host in
            guard let self else { return }
            FleetStatsViewController.dismiss()
            DiagnosticCenterViewController.show(store: self.store, in: host)
        }
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closePopover() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        if !suppressFleetReset {
            (dashboardViewController as? PrinterDashboardViewController)?.dismissOnboarding()
        }
        // Reset to the fleet list so reopening never lands back in a stale detail view — but not while
        // we're intentionally closing to swap content in a new size.
        if (detailViewController != nil || skipObjectsViewController != nil), !suppressFleetReset { returnToFleet() }
    }

    // Applied on every show (and on settings change): the vibrancy material plus, for "high", a lower
    // window alpha so the panel is genuinely more see-through than the plain glass material allows.
    func popoverDidShow(_ notification: Notification) {
        applyPanelStyle()
    }

    private func applyPanelStyle() {
        (popover.contentViewController as? PrinterDashboardViewController)?.applyPanelTransparency()
    }

    private func showAddPrinter() {
        popover.performClose(nil)
        if addWindow == nil { addWindow = AddPrinterWindowController(store: store) }
        addWindow?.prepareForAdding()
        addWindow?.showWindow(nil)
        addWindow?.window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showEditPrinter(_ printer: SavedPrinter) {
        popover.performClose(nil)
        if addWindow == nil { addWindow = AddPrinterWindowController(store: store) }
        addWindow?.prepareForEditing(printer)
        addWindow?.showWindow(nil)
        addWindow?.window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Opens the popover on the given printer's details from outside the popover itself (the edge
    /// dock). The popover anchors to the status item, so it has to be shown before the content swap.
    private func revealDetails(serial: String) {
        if AppSettings.shared.floatingWindowEnabled { showDetails(serial: serial); return }
        guard let button = anchorButton else { return }
        if !popover.isShown {
            popover.appearance = AppSettings.shared.appearance
            popover.contentViewController?.view.appearance = AppSettings.shared.appearance
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitor()
        }
        showDetails(serial: serial)
    }

    /// Swaps the popover's content to the in-bubble detail view for one printer, keeping everything
    /// inside the popover instead of opening a separate window.
    private func showDetails(serial: String) {
        // LITE ships no detail view; the cards themselves are the whole surface.
        guard Build.hasExtras else { return }
        if AppSettings.shared.floatingWindowEnabled {
            closePopover()
            let detail = PrinterDetailViewController(
                store: store, serial: serial,
                onBack: { [weak self] in self?.floatingDashboard?.dismissEmbeddedPanel() },
                onOpenAutomations: { [weak self] in self?.showAutomations(serial: serial) },
                onOpenAdvanced: { [weak self] in self?.showAdvanced(serial: serial) },
                onSkipObjects: { [weak self] in self?.showSkipObjects(serial: serial) },
                presentation: .floatingWindow)
            floatingDashboard?.present(detail, size: NSSize(width: 480, height: 700))
            return
        }
        let detail = PrinterDetailViewController(
            store: store, serial: serial,
            onBack: { [weak self] in self?.returnToFleet() },
            onOpenAutomations: { [weak self] in self?.showAutomations(serial: serial) },
            onOpenAdvanced: { [weak self] in self?.showAdvanced(serial: serial) },
            onSkipObjects: { [weak self] in self?.showSkipObjects(serial: serial) })
        // The detail view reports the height its cards need, capped by the screen, instead of being
        // nailed to one number: on a tall display it grows rather than scrolling inside 720 points.
        detail.onPreferredContentSize = { [weak self] size in
            guard let self, self.detailViewController === detail,
                  self.popover.contentSize != size else { return }
            self.popover.contentSize = size
        }
        detailViewController = detail
        swapPopoverContent(to: detail, size: NSSize(width: 600, height: 720))
    }

    /// Opens (or re-focuses) the per-printer automations editor window.
    private func showAutomations(serial: String) {
        popover.performClose(nil)
        if let existing = automationsWindows[serial], existing.window != nil {
            existing.show()
            return
        }
        let controller = AutomationsWindowController(store: store, serial: serial)
        automationsWindows[serial] = controller
        controller.show()
    }

    /// Opens (or re-focuses) the per-printer advanced overrides editor (camera IP, light commands).
    private func showAdvanced(serial: String) {
        popover.performClose(nil)
        if let existing = advancedWindows[serial], existing.window != nil {
            existing.show()
            return
        }
        let controller = PrinterAdvancedWindowController(store: store, serial: serial)
        advancedWindows[serial] = controller
        controller.show()
    }

    /// Returns the popover to the fleet dashboard.
    private func returnToFleet() {
        detailViewController = nil
        skipObjectsViewController = nil
        guard let dashboard = dashboardViewController else { return }
        swapPopoverContent(to: dashboard, size: dashboardContentSize)
    }

    private func showSkipObjects(serial: String) {
        guard Build.hasExtras else { return }
        if AppSettings.shared.floatingWindowEnabled {
            let controller = SkipObjectsViewController(store: store, serial: serial) { [weak self] in
                self?.floatingDashboard?.dismissEmbeddedPanel()
            }
            // On a short window the embedded surface scrolls as a whole instead of squeezing or
            // clipping the bed selector. Its width remains the same focused 480-point modal.
            floatingDashboard?.present(controller, size: NSSize(width: 480, height: 650),
                                       fillsViewport: false)
            return
        }
        let controller = SkipObjectsViewController(store: store, serial: serial) { [weak self] in
            self?.returnToFleet()
        }
        skipObjectsViewController = controller
        detailViewController = nil
        swapPopoverContent(to: controller, size: NSSize(width: 480, height: 650))
    }

    /// Reliably resize the popover when swapping content: an already-open popover won't re-measure on
    /// a contentViewController swap, so close and reopen it in the target size (fresh measurement).
    private func swapPopoverContent(to controller: NSViewController, size: NSSize) {
        guard popover.isShown, let button = anchorButton else {
            popover.contentViewController = controller
            popover.contentSize = size
            return
        }
        // Disable animation so close() (and its popoverDidClose delegate) run synchronously under the
        // guard; otherwise the delayed delegate fires after the guard clears and reopens the fleet.
        let wasAnimating = popover.animates
        popover.animates = false
        suppressFleetReset = true
        popover.close()
        popover.contentViewController = controller
        popover.contentSize = size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        suppressFleetReset = false
        popover.animates = wasAnimating
        // close() removed the outside-click monitor; reinstall it so clicking away still dismisses.
        installOutsideClickMonitor()
    }
}
