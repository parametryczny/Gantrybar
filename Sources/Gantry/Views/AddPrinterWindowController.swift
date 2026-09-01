import AppKit
import Combine

@MainActor
final class AddPrinterWindowController: NSWindowController, NSTextFieldDelegate {
    private let store: PrinterStore
    private let printerPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let serialField = NSTextField()
    private let codeField = NSSecureTextField()
    private let pasteCodeButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let scanButton = NSButton(title: "", target: nil, action: nil)
    private let importButton = NSButton(title: "", target: nil, action: nil)
    // Reading the slicer config is opt-in: it holds printer access codes, so the import button stays
    // disabled until the user ticks this consent checkbox.
    private let importConsent = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let importHint = NSTextField(wrappingLabelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private let detectedLabel = NSTextField(labelWithString: "")
    private let bambuStudioLabel = NSTextField(labelWithString: "Bambu Studio:")
    private let nameLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private let serialLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let typeControl = NSSegmentedControl(labels: ["Bambu", "Elegoo", "Anycubic", "Klipper", "Prusa", "Snapmaker"], trackingMode: .selectOne, target: nil, action: nil)
    private let elegooModelLabel = NSTextField(labelWithString: "Model Elegoo:")
    private let elegooModelPopup = NSPopUpButton()
    private let portField = NSTextField()
    private let apiKeyField = NSTextField()
    private let portLabel = NSTextField(labelWithString: "")
    private let apiKeyLabel = NSTextField(labelWithString: "")
    private let progressCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let subnetSection = NSStackView()
    private let subnetTargetsLabel = NSTextField(labelWithString: "")
    private let subnetTargetsField = NSTextField()
    private let subnetTargetsHint = NSTextField(wrappingLabelWithString: "")
    private let subnetTargetsError = NSTextField(labelWithString: "")
    private var form = NSGridView()
    private var subscription: AnyCancellable?
    private var popupPrinters: [DiscoveredPrinter] = []
    private var editingSerial: String?
    private var editingKind: PrinterKind = .bambu

    init(store: PrinterStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = AppSettings.shared.text("Dodaj drukarkę Bambu Lab", "Add Bambu Lab printer")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        subscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshDiscovery() }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        infoLabel.textColor = .secondaryLabelColor

        printerPopup.target = self
        printerPopup.action = #selector(selectedPrinterChanged)
        scanButton.target = self
        scanButton.action = #selector(scan)
        importButton.target = self
        importButton.action = #selector(importFromBambuStudio)
        importButton.isEnabled = false   // gated behind the consent checkbox below
        importConsent.target = self
        importConsent.action = #selector(importConsentChanged)
        importHint.font = .systemFont(ofSize: 10)
        importHint.textColor = .secondaryLabelColor
        importHint.maximumNumberOfLines = 3
        let importColumn = NSStackView(views: [importConsent, importButton, importHint])
        importColumn.orientation = .vertical
        importColumn.alignment = .leading
        importColumn.spacing = 4
        let discoveryRow = NSStackView(views: [printerPopup, scanButton])
        discoveryRow.orientation = .horizontal
        discoveryRow.spacing = 8
        printerPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pasteCodeButton.target = self
        pasteCodeButton.action = #selector(pasteAccessCode)
        let codeRow = NSStackView(views: [codeField, pasteCodeButton])
        codeRow.orientation = .horizontal
        codeRow.spacing = 8
        codeField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        typeControl.target = self
        typeControl.action = #selector(kindChanged)
        typeControl.segmentStyle = .rounded
        elegooModelPopup.addItems(withTitles: ["Centauri Carbon", "Centauri Carbon 2"])
        elegooModelPopup.target = self
        elegooModelPopup.action = #selector(elegooModelChanged)

        // Host takes the width; the short Port sits beside it (inline) instead of on its own row.
        portField.setContentHuggingPriority(.required, for: .horizontal)
        portField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        hostField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        portLabel.setContentHuggingPriority(.required, for: .horizontal)
        let hostPortRow = NSStackView(views: [hostField, portLabel, portField])
        hostPortRow.orientation = .horizontal
        hostPortRow.spacing = 8
        hostPortRow.alignment = .firstBaseline

        form = NSGridView(views: [
            [elegooModelLabel, elegooModelPopup],
            [detectedLabel, discoveryRow],
            [bambuStudioLabel, importColumn],
            [nameLabel, nameField],
            [hostLabel, hostPortRow],
            [serialLabel, serialField],
            [codeLabel, codeRow],
            [apiKeyLabel, apiKeyField]
        ])
        form.rowSpacing = 10
        form.columnSpacing = 12
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill

        statusLabel.textColor = .systemRed
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        saveButton.target = self
        saveButton.action = #selector(savePrinter)
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        subnetTargetsField.delegate = self
        subnetTargetsField.placeholderString = "100.71.10.5"
        subnetTargetsLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        subnetTargetsLabel.textColor = .secondaryLabelColor
        subnetTargetsHint.font = .systemFont(ofSize: 10)
        subnetTargetsHint.textColor = .tertiaryLabelColor
        subnetTargetsHint.maximumNumberOfLines = 4
        subnetTargetsError.font = .systemFont(ofSize: 10, weight: .medium)
        subnetTargetsError.textColor = .systemOrange
        subnetTargetsError.isHidden = true
        subnetSection.orientation = .vertical
        subnetSection.alignment = .leading
        subnetSection.spacing = 3
        [subnetTargetsLabel, subnetTargetsField, subnetTargetsHint, subnetTargetsError].forEach { subnetSection.addArrangedSubview($0) }

        let stack = NSStackView(views: [titleLabel, typeControl, infoLabel, form, subnetSection, progressCheck, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            infoLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subnetSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subnetTargetsField.widthAnchor.constraint(equalTo: subnetSection.widthAnchor),
            subnetTargetsHint.widthAnchor.constraint(equalTo: subnetSection.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        localize()
        applyKind()
    }

    private var selectedKind: PrinterKind {
        switch typeControl.selectedSegment {
        case 1: return elegooModelPopup.indexOfSelectedItem == 1 ? .elegooCC2 : .elegooCC1
        case 2: return .anycubicKobraS1
        case 3: return .klipper
        case 4: return .prusa
        case 5: return .snapmaker
        default: return .bambu
        }
    }
    /// Klipper and Prusa both connect over HTTP with host/port/API key; Bambu uses discovery + code.
    private var usesHostFields: Bool { ![PrinterKind.bambu, .elegooCC1, .elegooCC2].contains(selectedKind) }

    /// Shows the fields for the selected printer type.
    private func applyKind() {
        let hostBased = usesHostFields
        let isElegoo = selectedKind == .elegooCC1 || selectedKind == .elegooCC2
        // rows: 0 Elegoo model, 1 detected, 2 Bambu Studio, 3 name, 4 host+port, 5 serial, 6 code, 7 API key
        form.row(at: 0).isHidden = !isElegoo
        form.row(at: 1).isHidden = hostBased
        form.row(at: 2).isHidden = selectedKind != .bambu
        form.row(at: 5).isHidden = hostBased
        form.row(at: 6).isHidden = hostBased || selectedKind == .elegooCC1
        form.row(at: 7).isHidden = !hostBased || selectedKind == .snapmaker || selectedKind == .anycubicKobraS1
        subnetSection.isHidden = selectedKind != .bambu
        let settings = AppSettings.shared
        switch selectedKind {
        case .bambu: portField.placeholderString = "8883"
        case .prusa: portField.placeholderString = "80"
        case .klipper: portField.placeholderString = "7125"
        case .snapmaker: portField.placeholderString = "8080"
        case .elegooCC1: portField.placeholderString = "3030"
        case .elegooCC2: portField.placeholderString = "1883"
        case .anycubicKobraS1: portField.placeholderString = "18910"
        }
        switch selectedKind {
        case .klipper:
            infoLabel.stringValue = settings.text(
                "Podaj adres IP hosta Klipper (Moonraker, port 7125). Kod dostępu nie jest wymagany. Działa też przez VPN — wpisz po prostu adres Tailscale.",
                "Enter the Klipper host IP (Moonraker, port 7125). No access code is needed. Works over VPN too — just enter the Tailscale IP.")
        case .prusa:
            infoLabel.stringValue = settings.text(
                "Podaj adres IP drukarki Prusa (PrusaLink, port 80) i klucz API z ustawień PrusaLink. Bez konta Prusy. Działa też przez VPN — wpisz po prostu adres Tailscale.",
                "Enter the Prusa printer IP (PrusaLink, port 80) and the API key from PrusaLink settings. No Prusa account. Works over VPN too — just enter the Tailscale IP.")
        case .snapmaker:
            infoLabel.stringValue = settings.text(
                "Podaj adres IP drukarki Snapmaker (HTTP, port 8080). Obsługa: Snapmaker 2.0 i Artisan. Po dodaniu na EKRANIE DRUKARKI pojawi się prośba o zgodę na połączenie — dotknij „Zezwól” (Allow). Autoryzację trzeba powtórzyć po każdym wyłączeniu drukarki.",
                "Enter the Snapmaker printer IP (HTTP, port 8080). Supports Snapmaker 2.0 and Artisan. After adding, the PRINTER SCREEN shows a permission request — tap “Allow” to authorize. You'll need to re-authorize after each power cycle.")
        case .anycubicKobraS1:
            infoLabel.stringValue = settings.text(
                "Anycubic Kobra S1: podaj adres IP i włącz tryb LAN w drukarce. Gantry automatycznie pobierze dane MQTT przez port 18910. Kamera FLV: port 18088.",
                "Anycubic Kobra S1: enter the IP address and enable LAN mode on the printer. Gantry obtains MQTT settings automatically via port 18910. FLV camera: port 18088.")
        case .bambu:
            infoLabel.stringValue = settings.text(
                "Wykrywanie przez SSDP i skan podsieci. Wybierz urządzenie z listy albo wpisz dane ręcznie. Port zwykle 8883 — zmień tylko przy tunelu (np. socat na kilka drukarek). ",
                "Discovery via SSDP and a subnet scan. Pick a device from the list or enter details manually. Port is usually 8883 — change it only for a tunnel (e.g. socat forwarding several printers). ")
                + (AccessCodeStore.usesKeychain
                    ? settings.text("Kod zostanie zapisany w pęku kluczy macOS.", "The code is stored in macOS Keychain.")
                    : settings.text("Kod zostanie zapisany w lokalnych ustawieniach tego Maca.", "The code is stored in this Mac's local preferences."))
        case .elegooCC1:
            infoLabel.stringValue = settings.text(
                "Elegoo Centauri Carbon łączy się lokalnie przez SDCP/WebSocket na porcie 3030. Kod dostępu nie jest wymagany; kamera działa na porcie 3031.",
                "Elegoo Centauri Carbon connects locally over SDCP/WebSocket on port 3030. No access code is required; camera uses port 3031.")
        case .elegooCC2:
            infoLabel.stringValue = settings.text(
                "Elegoo Centauri Carbon 2 używa MQTT LAN na porcie 1883. Włącz LAN-only w drukarce i wpisz jej kod dostępu. Kamera MJPEG działa na porcie 8080.",
                "Elegoo Centauri Carbon 2 uses LAN MQTT on port 1883. Enable LAN-only on the printer and enter its access code. MJPEG camera uses port 8080.")
        }
    }

    @objc private func kindChanged() {
        statusLabel.stringValue = ""
        applyKind()
        refreshDiscovery()
    }

    @objc private func elegooModelChanged() { statusLabel.stringValue = ""; applyKind(); refreshDiscovery() }

    /// Applies every language-dependent string. Called on each open so the form follows the
    /// current language even though the window is built once and reused.
    private func localize() {
        let settings = AppSettings.shared
        titleLabel.stringValue = editingSerial == nil
            ? settings.text("Dodaj drukarkę", "Add printer")
            : settings.text("Edytuj drukarkę", "Edit printer")
        let storageDescription = AccessCodeStore.usesKeychain
            ? settings.text("Kod zostanie zapisany w pęku kluczy macOS.", "The code is stored in macOS Keychain.")
            : settings.text("Kod zostanie zapisany w lokalnych ustawieniach tego Maca.", "The code is stored in this Mac's local preferences.")
        infoLabel.stringValue = settings.text(
            "Wybierz urządzenie znalezione w Wi‑Fi albo wpisz dane ręcznie. ",
            "Select a device found on Wi-Fi or enter its details manually. "
        ) + storageDescription
        scanButton.title = settings.text("Skanuj ponownie", "Scan again")
        importButton.title = settings.text("Importuj drukarki i kody", "Import printers and codes")
        importButton.toolTip = settings.text(
            "Dopasuj wykryte drukarki i pobierz ich kody z lokalnej konfiguracji Bambu Studio",
            "Match detected printers and load their codes from the local Bambu Studio configuration"
        )
        importConsent.title = settings.text(
            "Pozwól odczytać konfigurację Bambu Studio",
            "Allow reading the Bambu Studio configuration"
        )
        importHint.stringValue = settings.text(
            "Przyspiesza dodawanie, ale odczytuje lokalny plik slicera z kodami dostępu do drukarek. Nic nie jest czytane, dopóki tego nie zaznaczysz.",
            "Speeds up adding, but reads the local slicer file containing printer access codes. Nothing is read until you tick this."
        )
        pasteCodeButton.title = settings.text("Wklej", "Paste")
        pasteCodeButton.toolTip = settings.text("Wklej kod dostępu ze schowka", "Paste access code from clipboard")
        detectedLabel.stringValue = settings.text("Wykryte:", "Detected:")
        nameLabel.stringValue = settings.text("Nazwa:", "Name:")
        hostLabel.stringValue = settings.text("Adres IP:", "IP address:")
        serialLabel.stringValue = settings.text("Numer seryjny:", "Serial number:")
        codeLabel.stringValue = settings.text("Kod dostępu:", "Access code:")
        cancelButton.title = settings.text("Anuluj", "Cancel")
        nameField.placeholderString = settings.text("np. Drukarka w warsztacie", "e.g. Workshop printer")
        hostField.placeholderString = settings.text("np. 192.168.1.50", "e.g. 192.168.1.50")
        serialField.placeholderString = settings.text("Numer seryjny drukarki", "Printer serial number")
        codeField.placeholderString = "PIN / Access Code"
        portLabel.stringValue = settings.text("Port:", "Port:")
        apiKeyLabel.stringValue = settings.text("Klucz API:", "API key:")
        portField.placeholderString = "7125"
        apiKeyField.placeholderString = settings.text("opcjonalny", "optional")
        progressCheck.title = settings.text("Pokaż postęp tej drukarki na pasku menu",
                                            "Show this printer's progress in the menu bar")

        subnetTargetsLabel.stringValue = settings.text("Nie widać drukarki? Dodatkowe adresy do skanowania (VPN):",
                                                       "Printer not listed? Extra scan targets (VPN):")
        subnetTargetsHint.stringValue = settings.text(
            "Bambu wykrywa się w sieci lokalnej. Drukarkę spoza LAN (np. przez Tailscale) dopisz tu jej adresem, potem kliknij ⟳. Obsługiwane: pojedynczy adres (zalecane), zakres a-b, CIDR /n. Duże zakresy odrzucane (limit \(SubnetTargets.maxHosts)).",
            "Bambu is found on the local network. Add a printer outside the LAN (e.g. over Tailscale) by its address here, then click ⟳. Supports: a single address (best), an a-b range, CIDR /n. Large ranges are rejected (limit \(SubnetTargets.maxHosts)).")
        if subnetTargetsField.currentEditor() == nil { subnetTargetsField.stringValue = settings.subnetScanTargets }
        validateSubnetField()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as AnyObject) === subnetTargetsField else { return }
        validateSubnetField()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as AnyObject) === subnetTargetsField else { return }
        let text = subnetTargetsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Save only when valid; leave an invalid entry in place (with the message shown) so it can be fixed.
        if SubnetTargets.isValid(text) {
            AppSettings.shared.subnetScanTargets = text
            subnetTargetsField.stringValue = text
        }
        validateSubnetField()
    }

    private func validateSubnetField() {
        let settings = AppSettings.shared
        let text = subnetTargetsField.stringValue
        if SubnetTargets.isValid(text) {
            subnetTargetsError.isHidden = true
        } else {
            subnetTargetsError.isHidden = false
            subnetTargetsError.stringValue = SubnetTargets.isTooLarge(text)
                ? settings.text("Zakres za duży (max \(SubnetTargets.maxHosts)) — podaj węższy zakres lub pojedynczy adres.",
                                "Range too large (max \(SubnetTargets.maxHosts)) — use a narrower range or a single address.")
                : settings.text("Nieprawidłowy wpis — użyj IP, zakresu a-b lub CIDR /n.",
                                "Invalid entry — use an IP, an a-b range or CIDR /n.")
        }
    }

    private func refreshDiscovery() {
        scanButton.isEnabled = !store.isScanning
        // Import reads the Bambu Studio config directly, so it never needs to wait for a scan — but
        // stays gated behind the consent checkbox.
        importButton.isEnabled = editingSerial == nil && importConsent.state == .on
        guard editingSerial == nil else { return }
        if store.isScanning {
            statusLabel.stringValue = AppSettings.shared.text("Skanowanie sieci…", "Scanning network…")
            statusLabel.textColor = .secondaryLabelColor
        } else if let message = store.globalMessage {
            statusLabel.stringValue = message
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.stringValue = ""
            statusLabel.textColor = .systemRed
        }
        let results = store.discovered.filter { found in
            switch selectedKind {
            case .bambu: found.kind == .bambu
            case .elegooCC1: found.kind == .elegooCC1
            case .elegooCC2: found.kind == .elegooCC2
            default: false
            }
        }
        guard results != popupPrinters else { return }
        // Preserve the user's current pick across a rescan so re-populating the list doesn't
        // silently reset the fields to the first result while they're typing.
        let previouslySelected = popupPrinters.indices.contains(printerPopup.indexOfSelectedItem)
            ? popupPrinters[printerPopup.indexOfSelectedItem].serial : nil
        popupPrinters = results
        printerPopup.removeAllItems()
        if results.isEmpty {
            printerPopup.addItem(withTitle: store.isScanning
                ? AppSettings.shared.text("Szukam drukarek w sieci…", "Searching for printers…")
                : AppSettings.shared.text("Nie znaleziono — wpisz dane ręcznie", "Not found — enter details manually"))
            return
        }
        printerPopup.addItems(withTitles: results.map { "\($0.name) — \($0.host)" })
        if let previouslySelected, let index = results.firstIndex(where: { $0.serial == previouslySelected }) {
            printerPopup.selectItem(at: index)   // keep the pick; don't overwrite typed-in fields
        } else {
            printerPopup.selectItem(at: 0)
            // Only auto-fill when the fields are still empty, i.e. the user hasn't started editing.
            if nameField.stringValue.isEmpty, hostField.stringValue.isEmpty, serialField.stringValue.isEmpty {
                fill(with: results[0])
            }
        }
    }

    @objc private func selectedPrinterChanged() {
        let index = printerPopup.indexOfSelectedItem
        guard popupPrinters.indices.contains(index) else { return }
        fill(with: popupPrinters[index])
    }

    private func fill(with printer: DiscoveredPrinter) {
        if printer.kind == .elegooCC1 || printer.kind == .elegooCC2 {
            elegooModelPopup.selectItem(at: printer.kind == .elegooCC2 ? 1 : 0)
            applyKind()
        }
        nameField.stringValue = printer.name
        hostField.stringValue = printer.host
        serialField.stringValue = printer.serial
    }

    @objc private func scan() {
        statusLabel.stringValue = ""
        statusLabel.textColor = .systemRed
        store.scan()
    }

    @objc private func importConsentChanged() {
        importButton.isEnabled = editingSerial == nil && importConsent.state == .on
    }

    @objc private func importFromBambuStudio() {
        // Defensive: never read the slicer config without explicit consent.
        guard importConsent.state == .on else { return }
        statusLabel.stringValue = ""
        do {
            let count = try store.importFromBambuStudio()
            let alert = NSAlert()
            alert.messageText = AppSettings.shared.text("Zaimportowano drukarki", "Printers imported")
            alert.informativeText = AppSettings.shared.text(
                "Dodano lub zaktualizowano: \(count). Gantry będzie używać kodów z lokalnej konfiguracji Bambu Studio.",
                "Added or updated: \(count). Gantry will use codes from the local Bambu Studio configuration."
            )
            alert.addButton(withTitle: "OK")
            if let window {
                alert.beginSheetModal(for: window) { [weak self] _ in self?.close() }
            }
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func pasteAccessCode() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            statusLabel.stringValue = AppSettings.shared.text("Schowek nie zawiera tekstu.", "The clipboard contains no text.")
            return
        }
        codeField.stringValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel.stringValue = ""
        window?.makeFirstResponder(codeField)
    }

    /// When editing a Klipper/Prusa printer whose host changed, the derived identifier changes too;
    /// remove the stale entry left under the old identifier.
    private func dropOldEntryIfIdentifierChanged(_ newIdentifier: String) {
        if let editingSerial, editingSerial != newIdentifier,
           let old = store.printers.first(where: { $0.serial == editingSerial }) {
            store.remove(old)
        }
    }

    @objc private func savePrinter() {
        statusLabel.stringValue = ""
        do {
            let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            switch selectedKind {
            case .klipper:
                try store.addKlipper(name: nameField.stringValue, host: host, port: port, apiKey: apiKeyField.stringValue)
                dropOldEntryIfIdentifierChanged("klipper-\(host)")
            case .prusa:
                try store.addPrusa(name: nameField.stringValue, host: host, port: port, apiKey: apiKeyField.stringValue)
                dropOldEntryIfIdentifierChanged("prusa-\(host)")
            case .snapmaker:
                try store.addSnapmaker(name: nameField.stringValue, host: host, port: port)
                dropOldEntryIfIdentifierChanged("snapmaker-\(host)")
            case .anycubicKobraS1:
                try store.addAnycubicKobraS1(name: nameField.stringValue, host: host, port: port)
                dropOldEntryIfIdentifierChanged("anycubic-kobra-s1-\(host)")
            case .elegooCC1, .elegooCC2:
                let serial = serialField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let editingSerial, editingSerial != serial,
                   let old = store.printers.first(where: { $0.serial == editingSerial }) { store.remove(old) }
                try store.addElegoo(name: nameField.stringValue, serial: serial, host: host,
                                    generation: selectedKind == .elegooCC2 ? 2 : 1,
                                    accessCode: codeField.stringValue, port: port)
            case .bambu:
                if let editingSerial {
                    try store.update(
                        originalSerial: editingSerial,
                        name: nameField.stringValue,
                        serial: serialField.stringValue,
                        host: hostField.stringValue,
                        accessCode: codeField.stringValue,
                        port: port
                    )
                } else {
                    try store.addManually(name: nameField.stringValue, serial: serialField.stringValue, host: hostField.stringValue, accessCode: codeField.stringValue, port: port)
                }
            }
            // The menu-bar pin checkbox is only shown when editing, so its serial is known here.
            if editingSerial != nil {
                let finalSerial: String
                switch selectedKind {
                case .klipper: finalSerial = "klipper-\(host)"
                case .prusa: finalSerial = "prusa-\(host)"
                case .snapmaker: finalSerial = "snapmaker-\(host)"
                case .anycubicKobraS1: finalSerial = "anycubic-kobra-s1-\(host)"
                case .elegooCC1, .elegooCC2: finalSerial = serialField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                case .bambu: finalSerial = serialField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                MenuBarProgressPreference.setEnabled(progressCheck.state == .on, for: finalSerial)
            }
            clear()
            close()
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func cancel() { close() }

    func prepareForAdding() {
        let settings = AppSettings.shared
        editingSerial = nil
        typeControl.isHidden = false
        typeControl.isEnabled = true
        typeControl.selectedSegment = 0
        progressCheck.isHidden = true          // menu-bar pin is offered when editing a saved printer
        localize()
        applyKind()
        window?.title = settings.text("Dodaj drukarkę", "Add printer")
        saveButton.title = settings.text("Dodaj", "Add")
        codeField.placeholderString = "PIN / Access Code"
        printerPopup.isEnabled = true
        scanButton.isEnabled = true
        importConsent.state = .off
        importButton.isEnabled = false   // re-gate: consent is per-open, not remembered
        clear()
        popupPrinters = []
        printerPopup.removeAllItems()
        printerPopup.addItem(withTitle: settings.text("Szukam drukarek w sieci…", "Searching for printers…"))
        store.scan()
    }

    func prepareForEditing(_ printer: SavedPrinter) {
        let settings = AppSettings.shared
        editingSerial = printer.serial
        editingKind = printer.kind
        switch printer.kind {
        case .bambu: typeControl.selectedSegment = 0
        case .elegooCC1: typeControl.selectedSegment = 1; elegooModelPopup.selectItem(at: 0)
        case .elegooCC2: typeControl.selectedSegment = 1; elegooModelPopup.selectItem(at: 1)
        case .anycubicKobraS1: typeControl.selectedSegment = 2
        case .klipper: typeControl.selectedSegment = 3
        case .prusa: typeControl.selectedSegment = 4
        case .snapmaker: typeControl.selectedSegment = 5
        }
        typeControl.isHidden = true          // kind is fixed when editing
        progressCheck.isHidden = false
        progressCheck.state = MenuBarProgressPreference.isEnabled(printer.serial) ? .on : .off
        localize()
        applyKind()
        window?.title = settings.text("Edytuj drukarkę \(printer.name)", "Edit printer \(printer.name)")
        saveButton.title = settings.text("Zapisz", "Save")
        nameField.stringValue = printer.name
        hostField.stringValue = printer.host
        statusLabel.stringValue = ""
        statusLabel.textColor = .systemRed
        portField.stringValue = printer.port.map(String.init) ?? ""   // Bambu too (tunnel port)
        if printer.kind == .klipper || printer.kind == .prusa {
            // The key now lives in the secure store (Keychain), not the config — prefill from there
            // so editing keeps it. A legacy config may still carry it inline; prefer that if present.
            apiKeyField.stringValue = printer.apiKey ?? AccessCodeStore.accessCode(for: printer.serial) ?? ""
        } else if printer.kind == .bambu || printer.kind == .elegooCC1 || printer.kind == .elegooCC2 {
            serialField.stringValue = printer.serial
            codeField.stringValue = ""
            if printer.kind == .elegooCC2, let code = AccessCodeStore.accessCode(for: printer.serial) { codeField.stringValue = code }
            codeField.placeholderString = printer.kind == .elegooCC1 ? "" : settings.text("Pozostaw puste, aby zachować obecny kod", "Leave blank to keep the current code")
            printerPopup.removeAllItems()
            printerPopup.addItem(withTitle: settings.text("Edycja zapisanej drukarki", "Editing saved printer"))
            printerPopup.isEnabled = false
            scanButton.isEnabled = false
            importButton.isEnabled = false
        }
    }

    private func clear() {
        nameField.stringValue = ""
        hostField.stringValue = ""
        serialField.stringValue = ""
        codeField.stringValue = ""
        portField.stringValue = ""
        apiKeyField.stringValue = ""
        statusLabel.stringValue = ""
    }
}
