import AppKit
import Combine
import Foundation

@MainActor
final class PrinterStore: ObservableObject {
    @Published private(set) var printers: [SavedPrinter]
    @Published private(set) var telemetry: [String: PrinterTelemetry] = [:]
    @Published private(set) var connectionMessages: [String: String] = [:]
    /// Transient per-printer notices shown on the card until dismissed (e.g. a Spoolbase spool that was
    /// auto-detached because an NFC roll was inserted into its slot).
    @Published private(set) var spoolNotices: [String: [String]] = [:]
    @Published private(set) var discovered: [DiscoveredPrinter] = []
    @Published var isScanning = false
    @Published var globalMessage: String?

    /// Rolling temperature history per printer, drawn by the detail window's graph. Deliberately not
    /// @Published — the detail view already redraws on the store's telemetry change, so publishing it
    /// separately would only add churn to every observer.
    private(set) var temperatureHistory: [String: [TemperatureSample]] = [:]
    private let maxTemperatureSamples = 240

    private let persistence = PrinterPersistence()
    private let discovery = SSDPDiscovery()
    private let subnetDiscovery = BambuSubnetDiscovery()
    private let elegooDiscovery = ElegooDiscovery()
    private var clients: [String: PrinterConnection] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var permissionRetryTask: Task<Void, Never>?
    private var localNetworkWasDenied = false
    private var lastAddressScan: Date?
    private var sessionCodes: [String: String] = [:]
    private var dismissedJobs: [String: String] = [:]
    private var printersWithTelemetry = Set<String>()
    private var firedAutomations: [String: Set<UUID>] = [:]
    private var scanToken: UUID?

    init() {
        AccessCodeStore.migrateLegacyPlaintextCodes()
        printers = persistence.load()
        migratePlaintextApiKeys()
        for printer in printers { telemetry[printer.serial] = PrinterTelemetry() }
        Task { @MainActor [weak self] in
            self?.refreshPrinterNames()
        }
    }

    var activePrintCount: Int {
        telemetry.values.filter { $0.state == .printing }.count
    }

    /// Access code for a Bambu printer, used by the detail window's camera stream. Prefers the
    /// session cache (already unlocked for MQTT) and falls back to the Keychain.
    func accessCode(for serial: String) -> String? {
        sessionCodes[serial] ?? AccessCodeStore.accessCode(for: serial)
    }

    /// Sends a raw JSON command to a Bambu printer over its live MQTT connection (chamber LED,
    /// pause, …). Silently ignores printers that aren't connected Bambu machines.
    func sendCommand(serial: String, json: String) {
        (clients[serial] as? MQTTClient)?.sendCommand(json)
    }

    func sendElegooMethod(serial: String, method: Int, params: [String: Any] = [:]) {
        if let client = clients[serial] as? ElegooCC1Client { client.sendMethod(method, data: params) }
        else if let client = clients[serial] as? ElegooCC2Client { client.sendMethod(method, params: params) }
    }

    @discardableResult
    private func sendElegooRaw(serial: String, json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = (object["method"] as? NSNumber)?.intValue else { return false }
        sendElegooMethod(serial: serial, method: method, params: object["params"] as? [String: Any] ?? [:])
        return true
    }

    /// Sends a raw G-code line to a Klipper printer over Moonraker (chamber light, pause, custom).
    func sendGcode(serial: String, script: String) {
        (clients[serial] as? MoonrakerClient)?.sendGcode(script)
    }

    /// Chamber LED on/off. Bambu uses `ledctrl`; Klipper uses a best-effort `caselight` pin (configs
    /// vary — advanced users can point a custom-command/script action at their own macro).
    func setChamberLight(_ on: Bool, serial: String) {
        // A per-printer override wins: Bambu treats it as MQTT JSON, Klipper as a G-code line.
        let custom = on ? PrinterOverridesStore.shared.overrides(for: serial).ledOn
                        : PrinterOverridesStore.shared.overrides(for: serial).ledOff
        if let custom, !custom.isEmpty {
            let kind = printers.first(where: { $0.serial == serial })?.kind
            if kind == .klipper {
                sendGcode(serial: serial, script: custom)
            } else if kind == .elegooCC1 || kind == .elegooCC2 {
                _ = sendElegooRaw(serial: serial, json: custom)
            } else {
                sendCommand(serial: serial, json: custom)
            }
            return
        }
        switch printers.first(where: { $0.serial == serial })?.kind {
        case .klipper:
            sendGcode(serial: serial, script: on ? "SET_PIN PIN=caselight VALUE=1" : "SET_PIN PIN=caselight VALUE=0")
        case .elegooCC1:
            sendElegooMethod(serial: serial, method: 403, params: ["LightStatus": ["SecondLight": on ? 1 : 0]])
        case .elegooCC2:
            sendElegooMethod(serial: serial, method: 1029, params: ["power": on ? 1 : 0])
        default:
            let mode = on ? "on" : "off"
            sendCommand(serial: serial, json: "{\"system\":{\"sequence_id\":\"2003\",\"command\":\"ledctrl\",\"led_node\":\"chamber_light\",\"led_mode\":\"\(mode)\",\"led_on_time\":500,\"led_off_time\":500,\"loop_times\":0,\"interval_time\":0}}")
        }
    }

    /// Runs one automation's action now (used by both the Run button and the trigger engine).
    func runAutomation(_ auto: PrinterAutomation, serial: String) {
        let printer = printers.first { $0.serial == serial }
        let name = printer?.name ?? serial
        let isKlipper = printer?.kind == .klipper

        func printCommand(bambu: String, klipperMacro: String) {
            if isKlipper { sendGcode(serial: serial, script: klipperMacro) }
            else if printer?.kind == .elegooCC1 {
                let command = bambu.contains("\"pause\"") ? 129 : bambu.contains("\"resume\"") ? 131 : 130
                sendElegooMethod(serial: serial, method: command)
            } else if printer?.kind == .elegooCC2 {
                let command = bambu.contains("\"pause\"") ? 1021 : bambu.contains("\"resume\"") ? 1023 : 1022
                sendElegooMethod(serial: serial, method: command)
            }
            else { sendCommand(serial: serial, json: bambu) }
        }

        switch auto.action {
        case .light(let on): setChamberLight(on, serial: serial)
        case .pause: printCommand(bambu: "{\"print\":{\"sequence_id\":\"2004\",\"command\":\"pause\"}}", klipperMacro: "PAUSE")
        case .resume: printCommand(bambu: "{\"print\":{\"sequence_id\":\"2004\",\"command\":\"resume\"}}", klipperMacro: "RESUME")
        case .stop: printCommand(bambu: "{\"print\":{\"sequence_id\":\"2004\",\"command\":\"stop\"}}", klipperMacro: "CANCEL_PRINT")
        case .notify(let text): NotificationService.post(title: name, body: text)
        case .command(let payload):
            // Bambu: raw MQTT JSON. Klipper: raw G-code line.
            guard allowCodeAction(auto, printerName: name) else { break }
            if isKlipper { sendGcode(serial: serial, script: payload) }
            else if printer?.kind == .elegooCC1 || printer?.kind == .elegooCC2 { _ = sendElegooRaw(serial: serial, json: payload) }
            else { sendCommand(serial: serial, json: payload) }
        case .script(let content):
            guard allowCodeAction(auto, printerName: name) else { break }
            ScriptRunner.shared.run(auto.id, script: content)
            NotificationService.post(title: name,
                                     body: AppSettings.shared.text("Uruchomiono skrypt: \(auto.name)",
                                                                   "Ran script: \(auto.name)"))
        }
    }

    /// Guard for automation actions that execute code — `.script` (a program on this Mac) and `.command`
    /// (an arbitrary raw MQTT/G-code command). Two layers: (1) a kill switch that is OFF by default, so a
    /// planted config cannot run code silently; (2) a one-time, per-rule consent prompt showing exactly
    /// what will run. Returns true only when the action may proceed.
    private func allowCodeAction(_ auto: PrinterAutomation, printerName: String) -> Bool {
        let s = AppSettings.shared
        guard s.allowScriptActions else {
            NotificationService.post(title: printerName,
                body: s.text("Pominięto „\(auto.name)” — akcje skryptowe/komendy są wyłączone (Ustawienia → Bezpieczeństwo).",
                             "Skipped \"\(auto.name)\" — script/command actions are disabled (Settings → Security)."))
            return false
        }
        if s.isScriptRuleApproved(auto.id) { return true }

        let isScript = auto.action.isScript
        var preview = ""
        if case .script(let c) = auto.action { preview = c } else if case .command(let c) = auto.action { preview = c }
        preview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.count > 700 { preview = String(preview.prefix(700)) + "…" }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = s.text("Potwierdź automatyzację", "Confirm automation")
        alert.informativeText = s.text(
            "Automatyzacja „\(auto.name)” (\(printerName)) chce wykonać \(isScript ? "skrypt na tym komputerze" : "komendę drukarki"):\n\n\(preview)\n\nZezwolić i zapamiętać dla tej reguły?",
            "Automation \"\(auto.name)\" (\(printerName)) wants to run \(isScript ? "a script on this Mac" : "a printer command"):\n\n\(preview)\n\nAllow and remember for this rule?")
        alert.addButton(withTitle: s.text("Zezwól", "Allow"))
        alert.addButton(withTitle: s.text("Odmów", "Deny"))
        let approved = alert.runModal() == .alertFirstButtonReturn
        if approved { s.approveScriptRule(auto.id) }
        return approved
    }

    /// Fires conditional automations once per print when their condition first becomes true.
    private func evaluateAutomations(serial: String, previous: PrinterTelemetry?, current: PrinterTelemetry) {
        // Re-arm the once-per-print guard only at a clear end-of-print state (idle/finished). Using the
        // job name here was wrong: Bambu's partial MQTT reports drop it constantly, which looked like a
        // new print and made a rule (e.g. "light off") fire again and again mid-print.
        if current.state == .idle || current.state == .finished {
            firedAutomations[serial] = []
        }
        for auto in AutomationStore.shared.automations(for: serial) where auto.enabled {
            guard automationShouldFire(auto.trigger, previous: previous, current: current) else { continue }
            if firedAutomations[serial, default: []].insert(auto.id).inserted {
                runAutomation(auto, serial: serial)
            }
        }
    }

    private func automationShouldFire(_ trigger: AutomationTrigger, previous: PrinterTelemetry?, current: PrinterTelemetry) -> Bool {
        switch trigger {
        case .manual: false
        case .atLayer(let n): (current.currentLayer ?? 0) >= n && (previous?.currentLayer ?? 0) < n
        case .atProgress(let p): current.progress >= p && (previous?.progress ?? -1) < p
        case .onState(let s): current.state.rawValue == s && previous?.state.rawValue != s
        }
    }

    func scan() {
        guard !isScanning else { return }
        let token = UUID()
        scanToken = token
        isScanning = true
        globalMessage = nil
        Task {
            let extraTargets = AppSettings.shared.subnetScanTargets
            async let ssdpResults = discovery.scan()
            async let subnetResults = subnetDiscovery.scan(extraTargets: extraTargets)
            async let elegooResults = elegooDiscovery.scan()
            let combined = await ssdpResults + subnetResults + elegooResults
            guard scanToken == token else { return }
            let results = Array(Dictionary(grouping: combined, by: \.serial).compactMap { $0.value.first })
            discovered = results.filter { candidate in !printers.contains { $0.serial == candidate.serial } }
                .sorted { $0.host.compare($1.host, options: .numeric) == .orderedAscending }
            isScanning = false
            if discovered.isEmpty { globalMessage = "Nie znaleziono nowych drukarek po 4 sekundach." }
        }
        Task {
            try? await Task.sleep(for: .seconds(8))
            guard scanToken == token, isScanning else { return }
            isScanning = false
            globalMessage = "Skanowanie przekroczyło 8 sekund. Sprawdź dostęp Gantry do sieci lokalnej."
        }
    }

    func add(_ discovered: DiscoveredPrinter, accessCode: String, customName: String? = nil) throws {
        let code = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw ValidationError("Podaj kod PIN / Access Code drukarki.") }
        let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let printer = SavedPrinter(
            serial: discovered.serial,
            name: name?.isEmpty == false ? name! : discovered.name,
            model: discovered.model,
            host: discovered.host
        )
        try upsert(printer, accessCode: code)
        self.discovered.removeAll { $0.serial == printer.serial }
    }

    func addManually(name: String, serial: String, host: String, accessCode: String, port: Int? = nil) throws {
        let cleanSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCode = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSerial.isEmpty, !cleanHost.isEmpty, !cleanCode.isEmpty else {
            throw ValidationError("Adres IP, numer seryjny i kod dostępu są wymagane.")
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try upsert(SavedPrinter(serial: cleanSerial, name: cleanName.isEmpty ? "Bambu \(cleanSerial.suffix(4))" : cleanName,
                                host: cleanHost, port: port), accessCode: cleanCode)
    }

    func addElegoo(name: String, serial: String, host: String, generation: Int, accessCode: String, port: Int?) throws {
        let cleanSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCode = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSerial.isEmpty, !cleanHost.isEmpty else { throw ValidationError("Adres IP i numer seryjny Elegoo są wymagane.") }
        guard generation == 1 || !cleanCode.isEmpty else { throw ValidationError("Podaj kod dostępu Elegoo CC2 i włącz tryb LAN-only.") }
        let kind: PrinterKind = generation == 1 ? .elegooCC1 : .elegooCC2
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let printer = SavedPrinter(serial: cleanSerial,
            name: cleanName.isEmpty ? "Centauri Carbon \(generation == 1 ? "" : "2 ")\(cleanSerial.suffix(4))" : cleanName,
            model: generation == 1 ? "Elegoo Centauri Carbon" : "Elegoo Centauri Carbon 2",
            host: cleanHost, kind: kind, port: port ?? (generation == 1 ? 3030 : 1883))
        if generation == 2 { try AccessCodeStore.save(accessCode: cleanCode, for: cleanSerial); sessionCodes[cleanSerial] = cleanCode }
        if let index = printers.firstIndex(where: { $0.serial == cleanSerial }) { printers[index] = printer } else { printers.append(printer) }
        telemetry[cleanSerial] = PrinterTelemetry(); persistence.save(printers); reconnect(printer)
    }

    /// Adds a Klipper printer (Moonraker). No access code — only host, optional port and API key.
    func addKlipper(name: String, host: String, port: Int?, apiKey: String?) throws {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else {
            throw ValidationError("Podaj adres IP drukarki Klipper.")
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = "klipper-\(cleanHost)"
        // The API key is a secret: keep it out of the plaintext config and in the secure store
        // (Keychain), keyed by serial — the same place Bambu access codes live.
        storeSecret(apiKey, for: identifier)
        let printer = SavedPrinter(
            serial: identifier,
            name: cleanName.isEmpty ? "Klipper \(cleanHost)" : cleanName,
            model: "Klipper",
            host: cleanHost,
            kind: .klipper,
            port: port,
            apiKey: nil
        )
        if let index = printers.firstIndex(where: { $0.serial == identifier }) {
            printers[index] = printer
        } else {
            printers.append(printer)
        }
        telemetry[identifier] = PrinterTelemetry()
        persistence.save(printers)
        reconnect(printer)
    }

    func addPrusa(name: String, host: String, port: Int?, apiKey: String?) throws {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else {
            throw ValidationError("Podaj adres IP drukarki Prusa.")
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = "prusa-\(cleanHost)"
        // Keep the PrusaLink API key in the secure store (Keychain), not the plaintext config.
        storeSecret(apiKey, for: identifier)
        let printer = SavedPrinter(
            serial: identifier,
            name: cleanName.isEmpty ? "Prusa \(cleanHost)" : cleanName,
            model: "Prusa",
            host: cleanHost,
            kind: .prusa,
            port: port,
            apiKey: nil
        )
        if let index = printers.firstIndex(where: { $0.serial == identifier }) {
            printers[index] = printer
        } else {
            printers.append(printer)
        }
        telemetry[identifier] = PrinterTelemetry()
        persistence.save(printers)
        reconnect(printer)
    }

    func addSnapmaker(name: String, host: String, port: Int?) throws {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else {
            throw ValidationError("Podaj adres IP drukarki Snapmaker.")
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = "snapmaker-\(cleanHost)"
        // No stored secret: Snapmaker authorizes each session via a token confirmed on the
        // printer's touchscreen, so there is nothing to keep in the Keychain.
        let printer = SavedPrinter(
            serial: identifier,
            name: cleanName.isEmpty ? "Snapmaker \(cleanHost)" : cleanName,
            model: "Snapmaker",
            host: cleanHost,
            kind: .snapmaker,
            port: port
        )
        if let index = printers.firstIndex(where: { $0.serial == identifier }) {
            printers[index] = printer
        } else {
            printers.append(printer)
        }
        telemetry[identifier] = PrinterTelemetry()
        persistence.save(printers)
        reconnect(printer)
    }

    @discardableResult
    func importFromBambuStudio() throws -> Int {
        let devices = try BambuStudioConfig.devices()
        var imported = 0

        // Prefer an address we already know (saved printer or a fresh discovery hit) and fall
        // back to the IP stored in the Bambu Studio config, so import works on a clean install
        // with no saved printers and without waiting for a network scan.
        for device in devices {
            let existing = printers.first { $0.serial == device.serial }
            let found = discovered.first { $0.serial == device.serial }
            guard let host = existing?.host ?? found?.host ?? device.host else { continue }
            let name = existing?.name ?? found?.name ?? "Bambu \(device.serial.suffix(4))"
            let model = found?.model ?? existing?.model ?? "Bambu Lab"
            try upsert(SavedPrinter(serial: device.serial, name: name, model: model, host: host), accessCode: device.accessCode)
            imported += 1
        }

        discovered.removeAll { found in devices.contains { $0.serial == found.serial } }
        guard imported > 0 else {
            throw BambuStudioConfigError("Nie znaleziono drukarek z zapisanym kodem i adresem IP.")
        }
        return imported
    }

    func update(originalSerial: String, name: String, serial: String, host: String, accessCode: String, port: Int? = nil) throws {
        let cleanSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredCode = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSerial.isEmpty, !cleanHost.isEmpty else {
            throw ValidationError("Adres IP i numer seryjny są wymagane.")
        }
        guard let code = enteredCode.isEmpty ? (sessionCodes[originalSerial] ?? AccessCodeStore.accessCode(for: originalSerial)) : enteredCode,
              !code.isEmpty else {
            throw ValidationError("Podaj kod PIN / Access Code drukarki.")
        }

        clients.removeValue(forKey: originalSerial)?.stop()
        if originalSerial != cleanSerial {
            printers.removeAll { $0.serial == originalSerial }
            telemetry.removeValue(forKey: originalSerial)
            connectionMessages.removeValue(forKey: originalSerial)
            AccessCodeStore.delete(for: originalSerial)
            CertificatePinStore.shared.delete(for: originalSerial)
        }
        let printer = SavedPrinter(
            serial: cleanSerial,
            name: cleanName.isEmpty ? "Bambu \(cleanSerial.suffix(4))" : cleanName,
            host: cleanHost,
            port: port
        )
        try upsert(printer, accessCode: code)
    }

    func remove(_ printer: SavedPrinter) {
        reconnectTasks.removeValue(forKey: printer.serial)?.cancel()
        clients.removeValue(forKey: printer.serial)?.stop()
        sessionCodes.removeValue(forKey: printer.serial)
        printers.removeAll { $0.serial == printer.serial }
        telemetry.removeValue(forKey: printer.serial)
        temperatureHistory.removeValue(forKey: printer.serial)
        connectionMessages.removeValue(forKey: printer.serial)
        AccessCodeStore.delete(for: printer.serial)
        CertificatePinStore.shared.delete(for: printer.serial)
        persistence.save(printers)
    }

    func movePrinter(serial: String, relativeTo targetSerial: String, insertAfter: Bool) {
        guard serial != targetSerial,
              let sourceIndex = printers.firstIndex(where: { $0.serial == serial }) else { return }
        let printer = printers.remove(at: sourceIndex)
        guard let targetIndex = printers.firstIndex(where: { $0.serial == targetSerial }) else {
            printers.insert(printer, at: min(sourceIndex, printers.count))
            return
        }
        printers.insert(printer, at: targetIndex + (insertAfter ? 1 : 0))
        persistence.save(printers)
    }

    func reconnect(_ printer: SavedPrinter) {
        reconnectTasks.removeValue(forKey: printer.serial)?.cancel()
        clients.removeValue(forKey: printer.serial)?.stop()
        telemetry[printer.serial] = PrinterTelemetry()
        connectionMessages[printer.serial] = "Łączenie…"

        let handler: @Sendable (MQTTClient.Event) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event, serial: printer.serial) }
        }
        let client: PrinterConnection
        switch printer.kind {
        case .klipper:
            let objects = PrinterOverridesStore.shared.overrides(for: printer.serial).moonrakerObjects
            client = MoonrakerClient(printer: hydratedWithSecret(printer), objects: objects, onEvent: handler)
        case .prusa:
            client = PrusaLinkClient(printer: hydratedWithSecret(printer), onEvent: handler)
        case .snapmaker:
            client = SnapmakerClient(printer: printer, onEvent: handler)
        case .elegooCC1:
            client = ElegooCC1Client(printer: printer, onEvent: handler)
        case .elegooCC2:
            let code: String
            if let sessionCode = sessionCodes[printer.serial] { code = sessionCode }
            else {
                do { code = try AccessCodeStore.readAccessCode(for: printer.serial); sessionCodes[printer.serial] = code }
                catch { connectionMessages[printer.serial] = error.localizedDescription; return }
            }
            client = ElegooCC2Client(printer: printer, accessCode: code, onEvent: handler)
        case .bambu:
            let code: String
            if let sessionCode = sessionCodes[printer.serial] {
                code = sessionCode
            } else {
                do {
                    code = try AccessCodeStore.readAccessCode(for: printer.serial)
                    sessionCodes[printer.serial] = code
                } catch {
                    connectionMessages[printer.serial] = error.localizedDescription
                    return
                }
            }
            client = MQTTClient(printer: printer, accessCode: code, onEvent: handler)
        }
        clients[printer.serial] = client
        client.start()
    }

    func reconnectAll() {
        for printer in printers { reconnect(printer) }
    }

    /// Clears the card notices for a printer (the user tapped "OK" on the on-card message).
    func dismissSpoolNotices(serial: String) {
        guard spoolNotices[serial] != nil else { return }
        spoolNotices[serial] = nil
    }

    /// Merges peer printers from LAN sync: adds any printer we do not already have (matched by serial).
    /// Secrets are never synced (Bambu access codes live in the Keychain, Klipper/Prusa apiKey is
    /// dropped), so a newly added printer appears but needs its access code entered once on this Mac
    /// before it connects. Existing printers and deletions are left untouched in v1.
    @discardableResult
    func mergeRemote(printers remote: [SyncPrinter]) -> Bool {
        var didChange = false
        for candidate in remote where !printers.contains(where: { $0.serial == candidate.serial }) {
            printers.append(SavedPrinter(serial: candidate.serial, name: candidate.name, model: candidate.model,
                                         host: candidate.host, kind: candidate.kind, port: candidate.port, apiKey: nil))
            didChange = true
        }
        if didChange { persistence.save(printers); reconnectAll() }
        return didChange
    }

    func retryAfterLocalNetworkPermission() {
        guard localNetworkWasDenied else { return }
        reconnectAll()
    }

    func refreshPrinterNames() {
        Task {
            let results = await discovery.scan(seconds: 4)
            var changed = false
            for found in results {
                guard let index = printers.firstIndex(where: { $0.serial == found.serial }),
                      shouldReplaceAutomaticName(printers[index].name),
                      !shouldReplaceAutomaticName(found.name) else { continue }
                printers[index].name = found.name.precomposedStringWithCanonicalMapping
                if found.model != "Bambu Lab" { printers[index].model = found.model }
                changed = true
            }
            guard changed else { return }
            persistence.save(printers)
        }
    }

    func resetCompletedStatuses() {
        for (serial, current) in telemetry where current.state != .printing && current.state != .paused {
            if let jobName = current.jobName, !jobName.isEmpty { dismissedJobs[serial] = jobName }
            telemetry[serial] = clearedCompletedJob(current)
            connectionMessages[serial] = nil
        }
    }

    /// Saves an HTTP printer's API key to the secure store (or clears it), keyed by serial.
    private func storeSecret(_ apiKey: String?, for serial: String) {
        let key = (apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        if let key {
            try? AccessCodeStore.save(accessCode: key, for: serial)
        } else {
            AccessCodeStore.delete(for: serial)
        }
    }

    /// Fills in a Klipper/Prusa printer's API key from the secure store just before connecting, so
    /// the key never has to live on the persisted config.
    private func hydratedWithSecret(_ printer: SavedPrinter) -> SavedPrinter {
        guard printer.apiKey == nil, let key = AccessCodeStore.accessCode(for: printer.serial) else { return printer }
        var copy = printer
        copy.apiKey = key
        return copy
    }

    /// One-time move of any plaintext Klipper/Prusa API keys from an older config into the secure
    /// store, then strip them from the persisted config.
    private func migratePlaintextApiKeys() {
        var changed = false
        for index in printers.indices {
            let printer = printers[index]
            guard printer.kind == .klipper || printer.kind == .prusa,
                  let key = printer.apiKey, !key.isEmpty else { continue }
            try? AccessCodeStore.save(accessCode: key, for: printer.serial)
            printers[index].apiKey = nil
            changed = true
        }
        if changed { persistence.save(printers) }
    }

    private func upsert(_ printer: SavedPrinter, accessCode: String) throws {
        try AccessCodeStore.save(accessCode: accessCode, for: printer.serial)
        sessionCodes[printer.serial] = accessCode
        if let index = printers.firstIndex(where: { $0.serial == printer.serial }) {
            printers[index] = printer
        } else {
            printers.append(printer)
        }
        telemetry[printer.serial] = PrinterTelemetry()
        persistence.save(printers)
        reconnect(printer)
    }

    private func handle(_ event: MQTTClient.Event, serial: String) {
        switch event {
        case .connected:
            localNetworkWasDenied = false
            permissionRetryTask?.cancel()
            permissionRetryTask = nil
            reconnectTasks.removeValue(forKey: serial)?.cancel()
            connectionMessages[serial] = nil
        case .telemetry(var value):
            reconnectTasks.removeValue(forKey: serial)?.cancel()
            let previous = telemetry[serial]
            if value.state == .printing || value.state == .paused {
                dismissedJobs.removeValue(forKey: serial)
            } else if let dismissed = dismissedJobs[serial], value.jobName == dismissed {
                value = clearedCompletedJob(value)
            } else if value.jobName != dismissedJobs[serial] {
                dismissedJobs.removeValue(forKey: serial)
            }
            telemetry[serial] = value
            // Inserting an RFID/NFC spool into a slot supersedes a stale manual Spoolbase assignment;
            // surface a dismissible notice on the card so the change is not silent.
            let detached = SpoolbaseShared.spools.detachAssignmentsReplacedByNFC(
                printerSerial: serial, previous: previous?.filamentGroups ?? [], current: value.filamentGroups)
            for item in detached {
                let text = AppSettings.shared.text(
                    "\(item.spoolID) wróciła do magazynu (wykryto tag NFC w \(item.slot))",
                    "\(item.spoolID) returned to storage (NFC tag detected in \(item.slot))")
                spoolNotices[serial, default: []].append(text)
            }
            recordTemperature(serial: serial, value: value)
            connectionMessages[serial] = nil
            if printersWithTelemetry.contains(serial), let printer = printers.first(where: { $0.serial == serial }) {
                notifyChanges(printer: printer, previous: previous, current: value)
                // Decrement the assigned physical spool on a real finish (idempotent per job).
                FilamentConsumption.onUpdate(printer: printer, previous: previous, current: value)
            }
            printersWithTelemetry.insert(serial)
            evaluateAutomations(serial: serial, previous: previous, current: value)
        case .disconnected(let reason):
            var offline = telemetry[serial] ?? PrinterTelemetry()
            offline.state = .offline
            telemetry[serial] = offline
            connectionMessages[serial] = (reason ?? "Rozłączono") + " • ponowna próba za 20 s"
            scheduleReconnect(serial: serial)
        case .localNetworkDenied:
            localNetworkWasDenied = true
            reconnectTasks.values.forEach { $0.cancel() }
            reconnectTasks.removeAll()
            clients.values.forEach { $0.stop() }
            for printer in printers {
                var offline = telemetry[printer.serial] ?? PrinterTelemetry()
                offline.state = .offline
                telemetry[printer.serial] = offline
                connectionMessages[printer.serial] = "Brak dostępu do sieci lokalnej — włącz Gantry w Ustawienia systemowe › Prywatność i ochrona › Sieć lokalna"
            }
            schedulePermissionRetry()
        }
    }

    private func schedulePermissionRetry() {
        guard permissionRetryTask == nil else { return }
        permissionRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<24 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                for printer in self.printers { self.reconnect(printer) }
            }
            self?.permissionRetryTask = nil
        }
    }

    private func scheduleReconnect(serial: String) {
        guard reconnectTasks[serial] == nil,
              printers.contains(where: { $0.serial == serial }) else { return }
        reconnectTasks[serial] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled,
                  self.printers.contains(where: { $0.serial == serial }),
                  self.telemetry[serial]?.state == .offline else {
                self?.reconnectTasks.removeValue(forKey: serial)
                return
            }
            if self.lastAddressScan.map({ Date().timeIntervalSince($0) >= 300 }) ?? true {
                self.lastAddressScan = Date()
                self.connectionMessages[serial] = "Szukam aktualnego adresu IP…"
                await self.refreshAddresses()
            }
            guard !Task.isCancelled,
                  let printer = self.printers.first(where: { $0.serial == serial }) else { return }
            self.reconnectTasks.removeValue(forKey: serial)
            self.reconnect(printer)
        }
    }

    private func refreshAddresses() async {
        async let ssdpResults = discovery.scan(seconds: 3)
        async let subnetResults = subnetDiscovery.scan()
        async let elegooResults = elegooDiscovery.scan(seconds: 3)
        let results = await ssdpResults + subnetResults + elegooResults
        var changed = false
        for found in results {
            guard let index = printers.firstIndex(where: { $0.serial == found.serial }) else { continue }
            if printers[index].host != found.host {
                printers[index].host = found.host
                changed = true
            }
            if shouldReplaceAutomaticName(printers[index].name), !shouldReplaceAutomaticName(found.name) {
                printers[index].name = found.name.precomposedStringWithCanonicalMapping
                changed = true
            }
            if found.model != "Bambu Lab", printers[index].model != found.model {
                printers[index].model = found.model
                changed = true
            }
        }
        if changed { persistence.save(printers) }
    }

    private func clearedCompletedJob(_ telemetry: PrinterTelemetry) -> PrinterTelemetry {
        var cleared = telemetry
        if cleared.state == .finished { cleared.state = .idle }
        cleared.progress = 0
        cleared.remainingMinutes = nil
        cleared.currentLayer = nil
        cleared.totalLayers = nil
        cleared.jobName = nil
        return cleared
    }

    private func notifyChanges(printer: SavedPrinter, previous: PrinterTelemetry?, current: PrinterTelemetry) {
        let settings = AppSettings.shared
        // One place to fan a notification out to every channel: the native banner and (when enabled)
        // Telegram, both gated by the same per-event toggles below.
        func push(title: String, body: String) {
            NotificationService.post(title: title, body: body, subtitle: printer.name)
            TelegramService.notify(printer: printer.name, title: title, body: body)
        }
        if settings.notifyFinished, current.state == .finished, previous?.state != .finished {
            push(title: settings.text("Druk zakończony", "Print finished"),
                 body: current.jobName ?? settings.text("Zadanie zostało ukończone.", "The job has completed."))
        }
        if settings.notifyError, current.state == .error, previous?.state != .error || previous?.hmsCodes != current.hmsCodes {
            let description = HMSResolver.shared.description(for: current.hmsCodes, serial: printer.serial, language: settings.language)
                ?? (current.errorCode != 0
                    ? String(format: settings.text("Kod błędu: 0x%llX", "Error code: 0x%llX"), current.errorCode)
                    : settings.text("Drukarka zgłosiła błąd.", "The printer reported an error."))
            push(title: settings.text("Błąd drukarki", "Printer error"), body: description)
        } else if settings.notifyPaused, current.state == .paused, previous?.state != .paused {
            push(title: settings.text("Druk wstrzymany", "Print paused"),
                 body: current.jobName ?? settings.text("Drukarka oczekuje na działanie.", "The printer needs attention."))
        }

        // Only trust the level for a chipped (RFID/NFC) spool: a chipless spool has no reliable remain,
        // so `remainingPercent` reads as 0 and must not raise a false "low filament" alert (issue #27).
        func lowAndTrusted(_ s: AMSSlot) -> Bool { s.remainingWeightGrams != nil && (s.remainingPercent ?? 100) <= 15 }
        let previousLow = Set(previous?.amsSlots.filter(lowAndTrusted).map(\.id) ?? [])
        let newLow = current.amsSlots.filter { lowAndTrusted($0) && !previousLow.contains($0.id) }
        if settings.notifyLowFilament, let slot = newLow.first {
            push(title: settings.text("Niski poziom filamentu", "Low filament"),
                 body: "\(slot.label) • \(slot.material) • \(slot.remainingPercent ?? 0)%")
        }

        if settings.notifyHumidity, isHumidityHigh(current.amsHumidity), !isHumidityHigh(previous?.amsHumidity) {
            push(title: settings.text("Wysoka wilgotność AMS", "High AMS humidity"),
                 body: settings.text("Sprawdź lub osusz pochłaniacz wilgoci.", "Check or dry the desiccant."))
        }
    }

    /// Append the latest temperatures to the rolling history (throttled to one sample / 2 s).
    private func recordTemperature(serial: String, value: PrinterTelemetry) {
        guard value.nozzleTemperature != nil || value.bedTemperature != nil || value.chamberTemperature != nil else { return }
        let now = value.lastUpdated ?? Date()
        var history = temperatureHistory[serial] ?? []
        if let last = history.last, now.timeIntervalSince(last.time) < 2 { return }
        history.append(TemperatureSample(time: now, nozzle: value.nozzleTemperature,
                                         bed: value.bedTemperature, chamber: value.chamberTemperature))
        if history.count > maxTemperatureSamples { history.removeFirst(history.count - maxTemperatureSamples) }
        temperatureHistory[serial] = history
    }

    private func isHumidityHigh(_ value: Int?) -> Bool {
        guard let value else { return false }
        return value <= 5 ? value >= 4 : value >= 40
    }

    private func shouldReplaceAutomaticName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bambu ") else { return trimmed.isEmpty }
        let suffix = trimmed.dropFirst(6)
        return suffix.count <= 6 && suffix.allSatisfy { $0.isLetter || $0.isNumber }
    }

}

struct ValidationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
