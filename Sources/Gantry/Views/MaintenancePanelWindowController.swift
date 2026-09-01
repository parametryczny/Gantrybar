import AppKit

/// Small, non-modal per-printer maintenance panel opened from the card badge and Details.
@MainActor
final class MaintenancePanelWindowController: NSWindowController, NSWindowDelegate {
    private static var active: [String: MaintenancePanelWindowController] = [:]

    private let printer: SavedPrinter
    private var telemetry: PrinterTelemetry
    private var body = NSStackView()

    static func show(printer: SavedPrinter, telemetry: PrinterTelemetry) {
        if let existing = active[printer.serial] {
            existing.telemetry = telemetry
            existing.rebuild()
            existing.present()
            return
        }
        let controller = MaintenancePanelWindowController(printer: printer, telemetry: telemetry)
        active[printer.serial] = controller
        controller.present()
    }

    private init(printer: SavedPrinter, telemetry: PrinterTelemetry) {
        self.printer = printer
        self.telemetry = telemetry
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 510),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 390, height: 400)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        super.init(window: window)
        window.delegate = self
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        Self.active[printer.serial] = nil
    }

    /// Gantry runs as an accessory/menu-bar app. Merely ordering an NSWindow is not enough when the
    /// click originated inside a transient NSPopover: AppKit can close the popover without activating
    /// the application, leaving the new window behind other apps. Use the same presentation sequence
    /// as Settings and Advanced printer windows.
    private func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func rebuild() {
        guard let window else { return }
        let s = AppSettings.shared
        window.appearance = s.appearance
        window.title = s.text("Konserwacja · \(printer.name)", "Maintenance · \(printer.name)")

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = GantryTheme.canvas.cgColor
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false

        let snapshot = PrinterInsightsStore.shared.snapshot(serial: printer.serial, polish: s.language == .pl)
        let title = label(s.text("Konserwacja · \(printer.name)", "Maintenance · \(printer.name)"), 20, .bold)
        let summary = label(String(format: s.text("%.1f h druku · dysza %@", "%.1f print h · nozzle %@"),
                                   snapshot.totalPrintHours,
                                   telemetry.nozzleDiameter.map { String(format: "%.1f mm", $0) } ?? "—"),
                            12, .regular, GantryTheme.secondary)
        body.addArrangedSubview(title)
        body.addArrangedSubview(summary)

        for task in snapshot.tasks { body.addArrangedSubview(taskCard(task, settings: s)) }

        let historyTitle = label(s.text("OSTATNIE WYDRUKI", "RECENT PRINTS"), 10, .bold, GantryTheme.muted)
        body.addArrangedSubview(historyTitle)
        let recent = Array(snapshot.history.prefix(3))
        if recent.isEmpty {
            body.addArrangedSubview(label(s.text("Brak zapisanej historii.", "No recorded history."), 12, .regular, GantryTheme.secondary))
        } else {
            for entry in recent {
                let icon = entry.result == .completed ? "✓" : entry.result == .failed ? "!" : "×"
                let duration = formatDuration(entry.durationSeconds)
                let text = "\(icon)  \(entry.job.isEmpty ? s.text("Bez nazwy", "Untitled") : entry.job)  ·  \(duration)"
                body.addArrangedSubview(label(text, 12, .medium, entry.result == .completed ? GantryTheme.text : .systemOrange))
            }
        }

        let stats = label(String(format: s.text("STATYSTYKI  ·  %d zakończonych  ·  %@ skuteczności  ·  %.0f g", "STATISTICS  ·  %d completed  ·  %@ success  ·  %.0f g"),
                                       snapshot.completedCount,
                                       snapshot.successPercent.map { "\($0)%" } ?? "—",
                                       snapshot.consumedGrams), 11, .semibold, GantryTheme.secondary)
        body.addArrangedSubview(stats)

        let instructions = button(s.text("Instrukcje", "Instructions")) { [weak self] in self?.showInstructions() }
        let fullHistory = button(s.text("Pełna historia", "Full history")) { [weak self] in self?.showHistory() }
        let footer = NSStackView(views: [instructions, NSView(), fullHistory])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 8
        body.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        let document = MaintenanceFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        scroll.documentView = document
        content.addSubview(scroll)
        window.contentView = content
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
            title.widthAnchor.constraint(equalTo: body.widthAnchor)
        ])
        window.center()
    }

    private func taskCard(_ task: PrinterInsightsStore.TaskStatus, settings s: AppSettings) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = (task.isUrgent ? NSColor.systemRed : task.isDue ? NSColor.systemYellow : GantryTheme.line).withAlphaComponent(0.6).cgColor
        box.layer?.backgroundColor = GantryTheme.card.withAlphaComponent(0.72).cgColor

        let icon = task.isUrgent ? "!" : task.isDue ? "⚠" : "○"
        let title = label("\(icon)  \(task.title)", 13, .semibold)
        let timing: String
        if task.isDue {
            timing = String(format: s.text("Przekroczono o %.0f h", "Overdue by %.0f h"), task.overdueHours)
        } else if let until = task.snoozedUntil, until > Date() {
            timing = s.text("Odłożono do \(until.formatted(date: .abbreviated, time: .omitted))",
                            "Snoozed until \(until.formatted(date: .abbreviated, time: .omitted))")
        } else {
            timing = String(format: s.text("Za %.0f h druku", "In %.0f print h"), task.remainingHours)
        }
        let subtitle = label(timing, 11, .regular, GantryTheme.secondary)
        let interval = NSTextField(string: String(Int(task.intervalHours.rounded())))
        interval.alignment = .right
        interval.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        interval.toolTip = s.text("Interwał w godzinach druku", "Interval in print hours")
        interval.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let hours = label("h", 11, .regular, GantryTheme.muted)
        let save = button(s.text("Ustaw", "Set")) { [weak self, weak interval] in
            guard let self, let value = Double(interval?.stringValue ?? ""), value >= 1 else { return }
            PrinterInsightsStore.shared.setInterval(serial: self.printer.serial, taskID: task.id, hours: value)
            self.rebuild()
        }
        let intervalRow = NSStackView(views: [label(s.text("Co", "Every"), 11, .regular, GantryTheme.muted), interval, hours, save])
        intervalRow.orientation = .horizontal; intervalRow.alignment = .centerY; intervalRow.spacing = 5
        let done = button(s.text("Wykonano", "Done")) { [weak self] in
            guard let self else { return }
            PrinterInsightsStore.shared.complete(serial: self.printer.serial, taskID: task.id)
            self.rebuild()
        }
        let snooze = button(s.text("Przypomnij za 7 dni", "Remind in 7 days")) { [weak self] in
            guard let self else { return }
            PrinterInsightsStore.shared.snooze(serial: self.printer.serial, taskID: task.id)
            self.rebuild()
        }
        let actions = NSStackView(views: [done, snooze, NSView(), intervalRow])
        actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 6
        let stack = NSStackView(views: [title, subtitle, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            box.widthAnchor.constraint(equalTo: body.widthAnchor)
        ])
        return box
    }

    private func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight,
                       _ color: NSColor = GantryTheme.text) -> NSTextField {
        let value = NSTextField(labelWithString: text)
        value.font = .systemFont(ofSize: size, weight: weight)
        value.textColor = color
        value.lineBreakMode = .byTruncatingTail
        return value
    }

    private func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10.5, weight: .medium)
        return button
    }

    private func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func showInstructions() {
        let s = AppSettings.shared
        let alert = NSAlert()
        alert.messageText = s.text("Instrukcje konserwacji", "Maintenance instructions")
        alert.informativeText = s.text(
            "Wyłącz i ostudź drukarkę. Oczyść prowadnice, zastosuj środek zalecany przez producenta, sprawdź paski i dyszę. Instrukcja producenta ma zawsze pierwszeństwo.",
            "Power off and cool the printer. Clean guide rods, use manufacturer-approved lubricant, then inspect belts and nozzle. The manufacturer guide always takes precedence.")
        alert.runModal()
    }

    private func showHistory() {
        let s = AppSettings.shared
        let entries = PrinterInsightsStore.shared.snapshot(serial: printer.serial, polish: s.language == .pl).history
        let rows = entries.map { "\($0.endedAt.formatted(date: .abbreviated, time: .shortened)) · \($0.job.isEmpty ? "—" : $0.job) · \(formatDuration($0.durationSeconds))" }
        let alert = NSAlert()
        alert.messageText = s.text("Pełna historia", "Full history")
        alert.informativeText = rows.isEmpty ? s.text("Brak historii.", "No history.") : rows.joined(separator: "\n")
        alert.runModal()
    }
}

private final class ClosureButton: NSButton {
    private let closure: () -> Void
    init(title: String, action: @escaping () -> Void) {
        closure = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(run)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func run() { closure() }
}

private final class MaintenanceFlippedView: NSView {
    override var isFlipped: Bool { true }
}
