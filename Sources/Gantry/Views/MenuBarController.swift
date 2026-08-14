import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: PrinterStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var progressItems: [String: NSStatusItem] = [:]
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

        let dashboard = PrinterDashboardViewController(
            store: store,
            onAdd: { [weak self] in self?.showAddPrinter() },
            onEdit: { [weak self] printer in self?.showEditPrinter(printer) },
            onReconnect: { [weak store] printer in store?.reconnect(printer) },
            onPreferredContentSize: { [weak self] size in
                guard let self, self.popover.contentSize != size else { return }
                self.popover.contentSize = size
            }
        )
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

    func showDashboard() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.appearance = AppSettings.shared.appearance
        popover.contentViewController?.view.appearance = AppSettings.shared.appearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = GantryLogo.statusItemImage(height: 14)
        button.imagePosition = .imageOnly
        button.toolTip = store.activePrintCount > 0
            ? AppSettings.shared.text("Gantry — drukuje: \(store.activePrintCount)", "Gantry — printing: \(store.activePrintCount)")
            : "Gantry"
    }

    /// Adds/removes/updates one extra status item per printer pinned to the menu bar, showing its
    /// live progress. Reconciled on every store change so it follows added/removed/renamed printers.
    private func updateProgressItems() {
        let validSerials = store.printers.map(\.serial)
        MenuBarProgressPreference.prune(keeping: validSerials)
        let pinned = Set(MenuBarProgressPreference.serials()).intersection(validSerials)

        for (serial, item) in progressItems where !pinned.contains(serial) {
            NSStatusBar.system.removeStatusItem(item)
            progressItems[serial] = nil
        }
        for serial in pinned {
            let item = progressItems[serial] ?? makeProgressItem()
            progressItems[serial] = item
            guard let button = item.button else { continue }
            let printer = store.printers.first { $0.serial == serial }
            button.title = progressTitle(name: printer?.name ?? serial, telemetry: store.telemetry[serial])
            button.toolTip = printer?.name
        }
    }

    private func makeProgressItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(progressItemClicked(_:))
        return item
    }

    private func progressTitle(name: String, telemetry: PrinterTelemetry?) -> String {
        guard let telemetry else { return name }
        switch telemetry.state {
        case .printing, .paused: return "\(name) \(telemetry.progress)%"
        default: return name
        }
    }

    @objc private func progressItemClicked(_ sender: NSStatusBarButton) {
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

        menu.addItem(row(icon: "shippingbox.fill",
                         title: settings.text("Spoolbase — magazyn filamentów", "Spoolbase — filament stock")) { [weak self] in
            self?.spoolbase.show()
        })

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
        guard let button = statusItem.button else { return }
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
}
