import AppKit
import Combine

/// Switches printers' sockets and runs the two things that happen without a click: the socket going
/// off some minutes after a print finished, and the emergency "everything off".
@MainActor
final class SmartPlugController {
    static let shared = SmartPlugController()

    private weak var store: PrinterStore?
    private var subscription: AnyCancellable?
    private var lastStates: [String: PrinterState] = [:]
    private var autoOffTasks: [String: Task<Void, Never>] = [:]
    /// Last state each socket reported, for the menus. Nil until Gantry has switched or read it.
    private(set) var knownState: [String: Bool] = [:]

    func attach(_ store: PrinterStore) {
        self.store = store
        subscription = store.$telemetry.sink { [weak self] values in
            Task { @MainActor [weak self] in self?.observe(values) }
        }
    }

    var hasPlugs: Bool { !SmartPlugStore.shared.isEmpty }

    func showSetup(serial: String) {
        guard let store else { return }
        SmartPlugWindowController.show(store: store, serial: serial)
    }

    private func name(_ serial: String) -> String {
        store?.printers.first { $0.serial == serial }?.name ?? serial
    }

    private func isBusy(_ serial: String) -> Bool {
        let state = store?.telemetry[serial]?.state
        return state == .printing || state == .paused
    }

    // MARK: One printer

    /// Switches one printer's socket. Cutting power under a running print asks first unless the
    /// caller already decided (an automation, a confirmed Telegram button, the emergency switch).
    func power(_ on: Bool, serial: String, confirmIfPrinting: Bool = true, reason: String? = nil) {
        guard let client = SmartPlugStore.shared.client(for: serial) else {
            NotificationService.post(title: name(serial), body: AppSettings.shared.t("No smart socket is set up for this printer."))
            return
        }
        if !on, confirmIfPrinting, isBusy(serial) {
            let s = AppSettings.shared
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = s.t("Cut the power to {0}?", name(serial))
            alert.informativeText = s.t("The printer is printing. Cutting the power ends the print and it cannot be resumed.")
            alert.addButton(withTitle: s.t("Cut the power"))
            alert.addButton(withTitle: s.t("Cancel"))
            guard ModalHost.run(alert) == .alertFirstButtonReturn else { return }
        }
        if !on { autoOffTasks.removeValue(forKey: serial)?.cancel() }
        let printer = name(serial)
        Task { @MainActor in
            do {
                let reported = try await client.set(on)
                self.knownState[serial] = reported ?? on
                let s = AppSettings.shared
                let title = on ? s.t("Socket switched on") : s.t("Socket switched off")
                NotificationService.post(title: title, body: reason.map { s.t("Automation: {0}", $0) } ?? printer, subtitle: printer)
                TelegramService.notify(printer: printer, title: title, body: reason ?? "")
            } catch {
                let s = AppSettings.shared
                NotificationService.post(title: s.t("Could not switch the socket"), body: error.localizedDescription, subtitle: printer)
                TelegramService.notify(printer: printer, title: s.t("Could not switch the socket"), body: error.localizedDescription)
            }
        }
    }

    func refreshState(serial: String) async -> Bool? {
        guard let client = SmartPlugStore.shared.client(for: serial) else { return nil }
        let state = try? await client.state()
        if let state { knownState[serial] = state }
        return state
    }

    // MARK: Everything

    /// Every socket marked for emergencies, switched off at once. Returns a line per printer.
    @discardableResult
    func emergencyOff() async -> [String] {
        let serials = SmartPlugStore.shared.serials.filter { SmartPlugStore.shared.plug(for: $0)?.includeInEmergency == true }
        autoOffTasks.values.forEach { $0.cancel() }
        autoOffTasks.removeAll()
        let jobs = serials.compactMap { serial -> (String, String, SmartPlugClient)? in
            SmartPlugStore.shared.client(for: serial).map { (serial, name(serial), $0) }
        }
        // All requests leave together; one socket that does not answer must not hold up the others.
        let results = await withTaskGroup(of: (String, String, String?).self) { group in
            for (serial, printer, client) in jobs {
                group.addTask {
                    do { _ = try await client.set(false); return (serial, printer, nil) }
                    catch { return (serial, printer, error.localizedDescription) }
                }
            }
            var all: [(String, String, String?)] = []
            for await result in group { all.append(result) }
            return all
        }
        let s = AppSettings.shared
        var lines: [String] = []
        for (serial, printer, failure) in results.sorted(by: { $0.1 < $1.1 }) {
            if failure == nil { knownState[serial] = false }
            lines.append(failure.map { "✕ \(printer): \($0)" } ?? "✓ \(printer)")
        }
        let failed = results.filter { $0.2 != nil }.count
        let title = failed == 0 ? s.t("Emergency: every socket is off") : s.t("Emergency: {0} sockets did not switch off", failed)
        NotificationService.post(title: title, body: lines.joined(separator: "\n"))
        TelegramService.notify(printer: "Gantry", title: title, body: lines.joined(separator: "\n"))
        return lines
    }

    /// The button: one question, the dangerous answer first so Return confirms it.
    func confirmEmergencyOff() {
        let s = AppSettings.shared
        let count = SmartPlugStore.shared.serials.filter { SmartPlugStore.shared.plug(for: $0)?.includeInEmergency == true }.count
        guard count > 0 else {
            let alert = NSAlert()
            alert.messageText = s.t("No smart sockets are set up")
            alert.informativeText = s.t("Add a socket to a printer: its card ⋯ menu → Power → Set up socket…")
            ModalHost.run(alert)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = s.t("Switch off every printer's power?")
        alert.informativeText = s.t("{0} sockets are switched off at once. Running prints end and cannot be resumed.", count)
        alert.addButton(withTitle: s.t("Switch everything off"))
        alert.addButton(withTitle: s.t("Cancel"))
        guard ModalHost.run(alert) == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            let lines = await emergencyOff()
            let report = NSAlert()
            report.messageText = s.t("Emergency power-off")
            report.informativeText = lines.joined(separator: "\n")
            ModalHost.run(report)
        }
    }

    // MARK: Switching off after a print

    private func observe(_ telemetry: [String: PrinterTelemetry]) {
        for (serial, t) in telemetry {
            let previous = lastStates[serial]
            lastStates[serial] = t.state
            if t.state == .printing || t.state == .paused {
                autoOffTasks.removeValue(forKey: serial)?.cancel()
                continue
            }
            guard t.state == .finished, previous != .finished, previous != nil,
                  let minutes = SmartPlugStore.shared.plug(for: serial)?.autoOffMinutes, minutes > 0 else { continue }
            autoOffTasks[serial]?.cancel()
            autoOffTasks[serial] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.autoOffTasks.removeValue(forKey: serial)
                // Somebody may have started the next print in the meantime.
                guard !self.isBusy(serial) else { return }
                self.power(false, serial: serial, confirmIfPrinting: false,
                           reason: AppSettings.shared.t("{0} min after the print finished", minutes))
            }
        }
    }
}
