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
                self?.popover.appearance = AppSettings.shared.appearance
                self?.popover.contentViewController?.view.appearance = AppSettings.shared.appearance
                self?.applyPanelStyle()
                self?.updateStatusItem()
                self?.updateProgressItems()
            }
        }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .gantryShowDashboard, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.showDashboard() }
        }
        updateNotificationObserver = NotificationCenter.default.addObserver(
            forName: .gantryCheckForUpdates, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async { UpdatePresenter.checkAndPresent(from: nil) }
        }
    }

    /// The status-bar button to anchor menus/popovers to. When printers are pinned the main Gantry
    /// icon is hidden, so fall back to the first visible pinned indicator.
    private var anchorButton: NSStatusBarButton? {
        statusItem.isVisible ? statusItem.button : progressItems.values.first?.button
    }

    func showDashboard() {
        guard let button = anchorButton, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.appearance = AppSettings.shared.appearance
        popover.contentViewController?.view.appearance = AppSettings.shared.appearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

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
                ? AppSettings.shared.text("Gantry — drukuje: \(store.activePrintCount)", "Gantry — printing: \(store.activePrintCount)")
                : "Gantry"
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
                         title: settings.text("Pokaż drukarki", "Show printers")) { [weak self] in
            self?.showPopoverFromMenu()
        })

        if settings.spoolbaseEnabled {
            menu.addItem(row(icon: "shippingbox.fill",
                             title: settings.text("Spoolbase — magazyn filamentów", "Spoolbase — filament stock")) { [weak self] in
                guard let button = self?.anchorButton else { return }
                self?.spoolbase.toggle(from: button)
            })
        }

        menu.addItem(.separator())

        menu.addItem(row(icon: "antenna.radiowaves.left.and.right",
                         title: settings.text("Szukaj drukarek…", "Search printers…"),
                         enabled: !store.isScanning) { [weak self] in
            self?.store.scan()
        })
        menu.addItem(row(icon: "plus",
                         title: settings.text("Dodaj drukarkę…", "Add printer…")) { [weak self] in
            self?.showAddPrinter()
        })
        menu.addItem(row(icon: "arrow.clockwise",
                         title: settings.text("Połącz ponownie (wszystkie)", "Reconnect (all)"),
                         enabled: !store.printers.isEmpty) { [weak self] in
            self?.store.reconnectAll()
        })

        menu.addItem(.separator())

        menu.addItem(row(icon: "globe",
                         title: settings.text("Język", "Language"),
                         accessory: .value(settings.language == .pl ? "PL" : "EN")) {
            AppSettings.shared.language = AppSettings.shared.language == .pl ? .en : .pl
        })
        menu.addItem(row(icon: QuietHours.isEnabled ? "moon.fill" : "moon",
                         title: settings.text("Godziny ciszy", "Quiet hours"),
                         accessory: .detail(QuietHours.isEnabled ? QuietHours.rangeLabel() : settings.text("wył.", "off"))) {
            QuietHours.isEnabled.toggle()
        })
        menu.addItem(row(icon: "arrow.down.circle",
                         title: settings.text("Sprawdź aktualizacje…", "Check for updates…"),
                         accessory: .detail("v\(UpdateService.currentVersion)")) {
            UpdatePresenter.checkAndPresent(from: nil)
        })
        menu.addItem(row(icon: "gearshape",
                         title: settings.text("Ustawienia…", "Settings…"),
                         accessory: .detail("⌘,")) { [weak self] in
            self?.showSettings()
        })

        // Every icon in this menu is drawn by a custom row view; a plain NSMenuItem's native image
        // doesn't render here, and a view-based item won't open a submenu on hover. So the icon is an
        // emoji in the title — it always renders and keeps the row expandable.
        let legendItem = NSMenuItem(title: settings.text("🎨  Legenda kolorów", "🎨  Colour legend"),
                                    action: nil, keyEquivalent: "")
        legendItem.submenu = colourLegendMenu(settings: settings)
        menu.addItem(legendItem)

        menu.addItem(row(icon: "cup.and.saucer.fill",
                         title: settings.text("Postaw kawę ☕️", "Buy me a coffee ☕️")) {
            if let url = URL(string: "https://buycoffee.to/parametryczny") { NSWorkspace.shared.open(url) }
        })

        menu.addItem(.separator())

        menu.addItem(row(icon: "power",
                         title: settings.text("Zakończ Gantry", "Quit Gantry"),
                         accessory: .detail("⌘Q")) {
            NSApplication.shared.terminate(nil)
        })

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 3), in: button)
    }

    /// Expandable colour legend explaining what each status colour on the cards means. Emoji dots keep
    /// the colours crisp inside the submenu without custom drawing.
    private func colourLegendMenu(settings: AppSettings) -> NSMenu {
        let statusEntries: [(String, String)] = [
            ("🔵", settings.text("Drukuje (świeże dane)", "Printing (live data)")),
            ("🟢", settings.text("Gotowe / zakończone", "Ready / finished")),
            ("🟠", settings.text("Uwaga: nieświeże dane, pauza lub wilgotność AMS",
                                 "Attention: stale data, paused, or AMS humidity")),
            ("🔴", settings.text("Błąd drukarki", "Printer error")),
            ("⚪", settings.text("Offline / brak / neutralna informacja", "Offline / none / neutral")),
        ]
        // Slot markers explain the small cues drawn on the filament swatches themselves.
        let slotEntries: [(String, String)] = [
            ("⭕", settings.text("Slot AMS z białym pierścieniem — aktywny (drukuje z niego)",
                                 "AMS slot with a white ring — active (printing from it)")),
            ("🔴", settings.text("Czerwona kropka na slocie — mało filamentu (≤15%)",
                                 "Red dot on a slot — low filament (≤15%)")),
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
        let header = NSMenuItem(title: settings.text("Sloty filamentu:", "Filament slots:"), action: nil, keyEquivalent: "")
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
        guard let button = anchorButton else { return }
        popover.appearance = AppSettings.shared.appearance
        popover.contentViewController?.view.appearance = AppSettings.shared.appearance
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installOutsideClickMonitor()
    }

    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.presentCentered()
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
        // Reset to the fleet list so reopening never lands back in a stale detail view — but not while
        // we're intentionally closing to swap content in a new size.
        if detailViewController != nil, !suppressFleetReset { returnToFleet() }
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

    /// Swaps the popover's content to the in-bubble detail view for one printer, keeping everything
    /// inside the popover instead of opening a separate window.
    private func showDetails(serial: String) {
        let detail = PrinterDetailViewController(store: store, serial: serial) { [weak self] in
            self?.returnToFleet()
        }
        detailViewController = detail
        swapPopoverContent(to: detail, size: NSSize(width: 480, height: 700))
    }

    /// Returns the popover to the fleet dashboard.
    private func returnToFleet() {
        detailViewController = nil
        guard let dashboard = dashboardViewController else { return }
        swapPopoverContent(to: dashboard, size: dashboardContentSize)
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
