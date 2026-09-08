import AppKit
import Combine

@main
@MainActor
final class GantryApp: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var permissionPrompter: LocalNetworkPermissionPrompter?
    private var webServer: GantryWebServer?
    private var webServerSub: AnyCancellable?
    private var telegramBot: TelegramBot?
    private var telegramSub: AnyCancellable?
    private var activationPolicySub: AnyCancellable?
    private var mainMenuSub: AnyCancellable?

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let failures = ProtocolSelfTest.run()
            if failures.isEmpty {
                print("Self-test: OK")
                exit(0)
            }
            for failure in failures { print("Self-test FAIL: \(failure)") }
            exit(1)
        }
        if CommandLine.arguments.contains("--storage-self-test") {
            let serial = "BAMBUBAR-SELF-TEST-\(UUID().uuidString)"
            let code = UUID().uuidString
            do {
                try AccessCodeStore.save(accessCode: code, for: serial)
                guard try AccessCodeStore.readAccessCode(for: serial) == code else {
                    print("Storage self-test FAIL: value mismatch")
                    AccessCodeStore.delete(for: serial)
                    exit(1)
                }
                AccessCodeStore.delete(for: serial)
                print("Storage self-test: OK (\(AccessCodeStore.modeName))")
                exit(0)
            } catch {
                AccessCodeStore.delete(for: serial)
                print("Storage self-test FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--certificate-pin-self-test") {
            let serial = "BAMBUBAR-PIN-SELF-TEST-\(UUID().uuidString)"
            let pins = CertificatePinStore.shared
            defer { pins.delete(for: serial) }
            let first = pins.validate(certificateData: Data("certificate-a".utf8), for: serial)
            let same = pins.validate(certificateData: Data("certificate-a".utf8), for: serial)
            let changed = pins.validate(certificateData: Data("certificate-b".utf8), for: serial)
            guard first == .firstUse, same == .matched, changed == .mismatch else {
                print("Certificate pin self-test: FAIL")
                exit(1)
            }
            print("Certificate pin self-test: OK")
            exit(0)
        }
        if CommandLine.arguments.contains("--scan") {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                async let ssdp = SSDPDiscovery().scan(seconds: 4)
                async let subnet = BambuSubnetDiscovery().scan()
                let combined = await ssdp + subnet
                let printers = Array(Dictionary(grouping: combined, by: \.serial).compactMap { $0.value.first })
                if printers.isEmpty {
                    print("SCAN_RESULT: 0 printers")
                } else {
                    for printer in printers {
                        print("SCAN_RESULT: \(printer.name) | \(printer.model) | \(printer.host) | \(printer.serial)")
                    }
                }
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = GantryApp()
        app.delegate = delegate
        // A detached dashboard behaves like a normal Mac window and therefore belongs in the Dock.
        // In menu-bar/popover mode Gantry remains an accessory and stays out of the Dock.
        // LITE has no detached window at all, so it is always an accessory.
        app.setActivationPolicy(!Build.isLite && AppSettings.shared.floatingWindowEnabled ? .regular : .accessory)
        app.mainMenu = makeMainMenu(target: nil)
        app.run()
    }

    private static func makeMainMenu(target: MenuBarController?) -> NSMenu {
        let mainMenu = NSMenu()
        let settings = AppSettings.shared

        if let target {
            let appRoot = NSMenuItem(title: Build.appName, action: nil, keyEquivalent: "")
            let appMenu = NSMenu(title: Build.appName)
            appMenu.autoenablesItems = false

            func action(_ key: String, symbol: String, selector: String,
                        shortcut: String = "") -> NSMenuItem {
                let item = NSMenuItem(title: settings.t(key),
                                      action: Selector((selector)), keyEquivalent: shortcut)
                item.target = target
                item.isEnabled = true
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                item.image?.isTemplate = true
                return item
            }

            appMenu.addItem(action("Show printers", symbol: "printer.fill",
                                   selector: "appMenuShowPrinters:"))
            if Build.hasExtras {
                appMenu.addItem(action("How to read Gantry", symbol: "questionmark.circle",
                                       selector: "appMenuOnboarding:"))
            }
            if Build.hasExtras, settings.spoolbaseEnabled {
                appMenu.addItem(action("Spoolbase — filament stock", symbol: "shippingbox.fill",
                                       selector: "appMenuShowSpoolbase:"))
            }
            appMenu.addItem(.separator())
            appMenu.addItem(action("Search printers…", symbol: "antenna.radiowaves.left.and.right",
                                   selector: "appMenuSearchPrinters:"))
            appMenu.addItem(action("Add printer…", symbol: "plus",
                                   selector: "appMenuAddPrinter:"))
            appMenu.addItem(action("Reconnect (all)", symbol: "arrow.clockwise",
                                   selector: "appMenuReconnectAll:"))
            if Build.hasExtras {
                appMenu.addItem(action("Diagnostic Center…", symbol: "stethoscope",
                                       selector: "appMenuDiagnostics:"))
                appMenu.addItem(action("Fleet statistics…", symbol: "chart.bar",
                                       selector: "appMenuFleetStats:"))
            }
            appMenu.addItem(.separator())

            let language = action("Language", symbol: "globe", selector: "appMenuCycleLanguage:")
            language.title += " — \(settings.language.uppercased())"
            appMenu.addItem(language)
            let quiet = action("Quiet hours", symbol: QuietHours.isEnabled ? "moon.fill" : "moon",
                               selector: "appMenuToggleQuietHours:")
            quiet.title += " — \(QuietHours.isEnabled ? QuietHours.rangeLabel() : settings.t("off"))"
            appMenu.addItem(quiet)
            if Build.hasExtras {
                appMenu.addItem(action("Check for updates…", symbol: "arrow.down.circle",
                                       selector: "appMenuCheckForUpdates:"))
            }
            appMenu.addItem(action("Settings…", symbol: "gearshape",
                                   selector: "appMenuSettings:", shortcut: ","))

            let legend = NSMenuItem(title: settings.t("🎨  Colour legend"), action: nil, keyEquivalent: "")
            let legendMenu = NSMenu()
            [
                ("🔵", "Printing (live data)"),
                ("🟢", "Ready / finished"),
                ("🟠", "Attention: stale data, paused, or AMS humidity"),
                ("🔴", "Printer error"),
                ("⚪", "Offline / none / neutral")
            ].forEach { dot, key in
                let row = NSMenuItem(title: "\(dot)  \(settings.t(key))", action: nil, keyEquivalent: "")
                row.isEnabled = true
                legendMenu.addItem(row)
            }
            legend.submenu = legendMenu
            appMenu.addItem(legend)
            appMenu.addItem(action("Buy me a coffee ☕️", symbol: "cup.and.saucer.fill",
                                   selector: "appMenuBuyCoffee:"))
            appMenu.addItem(.separator())
            appMenu.addItem(action("Quit Gantry", symbol: "power",
                                   selector: "appMenuQuit:", shortcut: "q"))
            appRoot.submenu = appMenu
            mainMenu.addItem(appRoot)
        }

        let editRoot = NSMenuItem()
        let editMenu = NSMenu(title: "Edycja")

        func command(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: key)
        }

        editMenu.addItem(command("Cofnij", Selector(("undo:")), "z"))
        editMenu.addItem(command("Ponów", Selector(("redo:")), "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(command("Wytnij", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(command("Kopiuj", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(command("Wklej", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(command("Zaznacz wszystko", #selector(NSText.selectAll(_:)), "a"))

        editRoot.submenu = editMenu
        mainMenu.addItem(editRoot)
        return mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.applyTheme()
        NotificationService.configure()
        if LaunchAtLoginManager.isEnabled { try? LaunchAtLoginManager.setEnabled(true) }
        let store = PrinterStore()
        let controller = MenuBarController(store: store)
        menuBarController = controller
        NSApp.mainMenu = Self.makeMainMenu(target: controller)
        mainMenuSub = AppSettings.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let controller = self?.menuBarController else { return }
                    NSApp.mainMenu = Self.makeMainMenu(target: controller)
                }
            }
        if Build.hasExtras {
            activationPolicySub = AppSettings.shared.$floatingWindowEnabled
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { enabled in
                    NSApp.setActivationPolicy(enabled ? .regular : .accessory)
                    if enabled { NSApp.activate(ignoringOtherApps: true) }
                }
        }
        store.reconnectAll()
        // Read-only web dashboard on the LAN (http://<host>.local:8787), toggled in Settings. LITE is a
        // pure tray monitor and never opens a listening socket, so it does not build the server at all.
        if Build.hasExtras {
            webServer = GantryWebServer(store: store)
            webServerSub = AppSettings.shared.$webDashboardEnabled
                .removeDuplicates()
                .sink { [weak self] enabled in
                    if enabled { self?.webServer?.start() } else { self?.webServer?.stop() }
                }
            // Two-way Telegram bot (/status, control, /photo). Starts only when enabled + configured; the
            // Settings section re-syncs it directly, and toggling the switch is covered here too.
            let bot = TelegramBot(store: store)
            telegramBot = bot
            bot.syncWithSettings()
            telegramSub = AppSettings.shared.$telegramEnabled.removeDuplicates().sink { _ in bot.syncWithSettings() }
        }
        let prompter = LocalNetworkPermissionPrompter {
            Task { @MainActor in store.retryAfterLocalNetworkPermission() }
        }
        permissionPrompter = prompter
        prompter.start()
        // LITE never checks for or installs updates; it is a fixed, self-contained build.
        if Build.hasExtras { UpdateChecker.start() }
        // After the BambuBar → Gantry rename, offer to remove a leftover old app (once, with consent).
        // Only the full edition does this: LITE may well be installed next to another Gantry, and it is
        // not its place to propose removing the app the user already had.
        if Build.hasExtras { LegacyAppCleanup.offerRemovalIfNeeded() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard AppSettings.shared.floatingWindowEnabled else { return false }
        menuBarController?.restoreFloatingDashboardFromDock()
        return true
    }
}
