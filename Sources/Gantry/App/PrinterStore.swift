import Combine
import Foundation

@MainActor
final class PrinterStore: ObservableObject {
    @Published private(set) var printers: [SavedPrinter]
    @Published private(set) var telemetry: [String: PrinterTelemetry] = [:]
    @Published private(set) var connectionMessages: [String: String] = [:]
    @Published private(set) var discovered: [DiscoveredPrinter] = []
    @Published var isScanning = false
    @Published var globalMessage: String?

    private let persistence = PrinterPersistence()
    private let discovery = SSDPDiscovery()
    private let subnetDiscovery = BambuSubnetDiscovery()
    private var clients: [String: PrinterConnection] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var permissionRetryTask: Task<Void, Never>?
    private var localNetworkWasDenied = false
    private var lastAddressScan: Date?
    private var sessionCodes: [String: String] = [:]
    private var dismissedJobs: [String: String] = [:]
    private var printersWithTelemetry = Set<String>()
    private var scanToken: UUID?

    init() {
        AccessCodeStore.migrateLegacyPlaintextCodes()
        printers = persistence.load()
        for printer in printers { telemetry[printer.serial] = PrinterTelemetry() }
        Task { @MainActor [weak self] in
            self?.refreshPrinterNames()
        }
    }

    var activePrintCount: Int {
        telemetry.values.filter { $0.state == .printing }.count
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
            let combined = await ssdpResults + subnetResults
            guard scanToken == token else { return }
            let results = Array(Dictionary(grouping: combined, by: \.serial).compactMap { $0.value.first })
            discovered = results.filter { candidate in !printers.contains { $0.serial == candidate.serial } }
                .sorted { $0.host.compare($1.host, options: .numeric) == .orderedAscending }
            isScanning = false
            if discovered.isEmpty {
                globalMessage = AppSettings.shared.text(
                    "Nie znaleziono nowych drukarek po 4 sekundach.",
                    "No new printers were found after 4 seconds.",
                    "Nach 4 Sekunden wurden keine neuen Drucker gefunden."
                )
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(8))
            guard scanToken == token, isScanning else { return }
            isScanning = false
            globalMessage = AppSettings.shared.text(
                "Skanowanie przekroczyło 8 sekund. Sprawdź dostęp Gantry do sieci lokalnej.",
                "The scan exceeded 8 seconds. Check Gantry's Local Network access.",
                "Der Scan hat länger als 8 Sekunden gedauert. Prüfe Gantrys Zugriff auf das lokale Netzwerk."
            )
        }
    }

    func add(_ discovered: DiscoveredPrinter, accessCode: String, customName: String? = nil) throws {
        let code = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            throw ValidationError(AppSettings.shared.text(
                "Podaj kod PIN / Access Code drukarki.",
                "Enter the printer PIN / Access Code.",
                "Gib die PIN beziehungsweise den Zugriffscode des Druckers ein."
            ))
        }
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
            throw ValidationError(AppSettings.shared.text(
                "Adres IP, numer seryjny i kod dostępu są wymagane.",
                "IP address, serial number and access code are required.",
                "IP-Adresse, Seriennummer und Zugriffscode sind erforderlich."
            ))
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try upsert(SavedPrinter(serial: cleanSerial, name: cleanName.isEmpty ? "Bambu \(cleanSerial.suffix(4))" : cleanName,
                                host: cleanHost, port: port), accessCode: cleanCode)
    }

    /// Adds a Klipper printer (Moonraker). No access code — only host, optional port and API key.
    func addKlipper(name: String, host: String, port: Int?, apiKey: String?) throws {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else {
            throw ValidationError(AppSettings.shared.text(
                "Podaj adres IP drukarki Klipper.",
                "Enter the Klipper printer IP address.",
                "Gib die IP-Adresse des Klipper-Druckers ein."
            ))
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = "klipper-\(cleanHost)"
        let printer = SavedPrinter(
            serial: identifier,
            name: cleanName.isEmpty ? "Klipper \(cleanHost)" : cleanName,
            model: "Klipper",
            host: cleanHost,
            kind: .klipper,
            port: port,
            apiKey: (apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
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
            throw ValidationError(AppSettings.shared.text(
                "Podaj adres IP drukarki Prusa.",
                "Enter the Prusa printer IP address.",
                "Gib die IP-Adresse des Prusa-Druckers ein."
            ))
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = "prusa-\(cleanHost)"
        let printer = SavedPrinter(
            serial: identifier,
            name: cleanName.isEmpty ? "Prusa \(cleanHost)" : cleanName,
            model: "Prusa",
            host: cleanHost,
            kind: .prusa,
            port: port,
            apiKey: (apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
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
            throw BambuStudioConfigError(AppSettings.shared.text(
                "Nie znaleziono drukarek z zapisanym kodem i adresem IP.",
                "No printers with a saved code and IP address were found.",
                "Es wurden keine Drucker mit gespeichertem Code und IP-Adresse gefunden."
            ))
        }
        return imported
    }

    func update(originalSerial: String, name: String, serial: String, host: String, accessCode: String, port: Int? = nil) throws {
        let cleanSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredCode = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSerial.isEmpty, !cleanHost.isEmpty else {
            throw ValidationError(AppSettings.shared.text(
                "Adres IP i numer seryjny są wymagane.",
                "IP address and serial number are required.",
                "IP-Adresse und Seriennummer sind erforderlich."
            ))
        }
        guard let code = enteredCode.isEmpty ? (sessionCodes[originalSerial] ?? AccessCodeStore.accessCode(for: originalSerial)) : enteredCode,
              !code.isEmpty else {
            throw ValidationError(AppSettings.shared.text(
                "Podaj kod PIN / Access Code drukarki.",
                "Enter the printer PIN / Access Code.",
                "Gib die PIN beziehungsweise den Zugriffscode des Druckers ein."
            ))
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
        connectionMessages[printer.serial] = AppSettings.shared.text("Łączenie…", "Connecting…", "Verbindung wird hergestellt …")

        let handler: @Sendable (MQTTClient.Event) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event, serial: printer.serial) }
        }
        let client: PrinterConnection
        switch printer.kind {
        case .klipper:
            client = MoonrakerClient(printer: printer, onEvent: handler)
        case .prusa:
            client = PrusaLinkClient(printer: printer, onEvent: handler)
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
            connectionMessages[serial] = nil
            if printersWithTelemetry.contains(serial), let printer = printers.first(where: { $0.serial == serial }) {
                notifyChanges(printer: printer, previous: previous, current: value)
            }
            printersWithTelemetry.insert(serial)
        case .disconnected(let reason):
            var offline = telemetry[serial] ?? PrinterTelemetry()
            offline.state = .offline
            telemetry[serial] = offline
            let disconnected = reason ?? AppSettings.shared.text("Rozłączono", "Disconnected", "Verbindung getrennt")
            connectionMessages[serial] = disconnected + AppSettings.shared.text(
                " • ponowna próba za 20 s",
                " • retrying in 20 s",
                " • neuer Versuch in 20 s"
            )
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
                connectionMessages[printer.serial] = AppSettings.shared.text(
                    "Brak dostępu do sieci lokalnej — włącz Gantry w Ustawienia systemowe › Prywatność i ochrona › Sieć lokalna",
                    "No Local Network access — enable Gantry in System Settings › Privacy & Security › Local Network",
                    "Kein Zugriff auf das lokale Netzwerk — aktiviere Gantry unter Systemeinstellungen › Datenschutz & Sicherheit › Lokales Netzwerk"
                )
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
                self.connectionMessages[serial] = AppSettings.shared.text(
                    "Szukam aktualnego adresu IP…",
                    "Looking for the current IP address…",
                    "Aktuelle IP-Adresse wird gesucht …"
                )
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
        let results = await ssdpResults + subnetResults
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
        if settings.notifyFinished, current.state == .finished, previous?.state != .finished {
            NotificationService.post(
                title: settings.text("Druk zakończony", "Print finished", "Druck abgeschlossen"),
                body: current.jobName ?? settings.text("Zadanie zostało ukończone.", "The job has completed.", "Der Druckauftrag ist abgeschlossen."),
                subtitle: printer.name
            )
        }
        if settings.notifyError, current.state == .error, previous?.state != .error || previous?.hmsCodes != current.hmsCodes {
            let description = HMSResolver.shared.description(for: current.hmsCodes, serial: printer.serial, language: settings.language)
                ?? (current.errorCode != 0
                    ? String(format: settings.text("Kod błędu: 0x%llX", "Error code: 0x%llX", "Fehlercode: 0x%llX"), current.errorCode)
                    : settings.text("Drukarka zgłosiła błąd.", "The printer reported an error.", "Der Drucker hat einen Fehler gemeldet."))
            NotificationService.post(title: settings.text("Błąd drukarki", "Printer error", "Druckerfehler"), body: description, subtitle: printer.name)
        } else if settings.notifyPaused, current.state == .paused, previous?.state != .paused {
            NotificationService.post(
                title: settings.text("Druk wstrzymany", "Print paused", "Druck pausiert"),
                body: current.jobName ?? settings.text("Drukarka oczekuje na działanie.", "The printer needs attention.", "Der Drucker benötigt deine Aufmerksamkeit."),
                subtitle: printer.name
            )
        }

        let previousLow = Set(previous?.amsSlots.filter { ($0.remainingPercent ?? 100) <= 15 }.map(\.id) ?? [])
        let newLow = current.amsSlots.filter { ($0.remainingPercent ?? 100) <= 15 && !previousLow.contains($0.id) }
        if settings.notifyLowFilament, let slot = newLow.first {
            NotificationService.post(
                title: settings.text("Niski poziom filamentu", "Low filament", "Niedriger Filamentstand"),
                body: "\(slot.label) • \(slot.material) • \(slot.remainingPercent ?? 0)%",
                subtitle: printer.name
            )
        }

        if settings.notifyHumidity, isHumidityHigh(current.amsHumidity), !isHumidityHigh(previous?.amsHumidity) {
            NotificationService.post(
                title: settings.text("Wysoka wilgotność AMS", "High AMS humidity", "Hohe AMS-Luftfeuchtigkeit"),
                body: settings.text("Sprawdź lub osusz pochłaniacz wilgoci.", "Check or dry the desiccant.", "Prüfe oder trockne das Trockenmittel."),
                subtitle: printer.name
            )
        }
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
