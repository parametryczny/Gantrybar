import AppKit
import Combine

@main
@MainActor
final class GantryApp: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var permissionPrompter: LocalNetworkPermissionPrompter?
    private var languageSubscription: AnyCancellable?

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
        app.setActivationPolicy(.accessory)
        app.mainMenu = makeMainMenu()
        app.run()
    }

    static func makeMainMenu() -> NSMenu {
        let settings = AppSettings.shared
        let mainMenu = NSMenu()
        let editRoot = NSMenuItem()
        let editMenu = NSMenu(title: settings.text("Edycja", "Edit", "Bearbeiten"))

        func command(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: key)
        }

        editMenu.addItem(command(settings.text("Cofnij", "Undo", "Rückgängig"), Selector(("undo:")), "z"))
        editMenu.addItem(command(settings.text("Ponów", "Redo", "Wiederholen"), Selector(("redo:")), "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(command(settings.text("Wytnij", "Cut", "Ausschneiden"), #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(command(settings.text("Kopiuj", "Copy", "Kopieren"), #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(command(settings.text("Wklej", "Paste", "Einfügen"), #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(command(settings.text("Zaznacz wszystko", "Select All", "Alles auswählen"), #selector(NSText.selectAll(_:)), "a"))

        editRoot.submenu = editMenu
        mainMenu.addItem(editRoot)
        return mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.applyTheme()
        languageSubscription = AppSettings.shared.$language.dropFirst().sink { _ in
            NSApp.mainMenu = Self.makeMainMenu()
        }
        NotificationService.configure()
        if LaunchAtLoginManager.isEnabled { try? LaunchAtLoginManager.setEnabled(true) }
        let store = PrinterStore()
        menuBarController = MenuBarController(store: store)
        store.reconnectAll()
        let prompter = LocalNetworkPermissionPrompter {
            Task { @MainActor in store.retryAfterLocalNetworkPermission() }
        }
        permissionPrompter = prompter
        prompter.start()
        UpdateChecker.start()
        // After the BambuBar → Gantry rename, offer to remove a leftover old app (once, with consent).
        LegacyAppCleanup.offerRemovalIfNeeded()
    }
}
