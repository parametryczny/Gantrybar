import AppKit

/// Dimmed in-window backdrop. Clicking outside the maintenance card closes it.
private final class MaintenanceBackdropView: NSView {
    var onClickOutside: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClickOutside?() }
}

/// Per-printer maintenance card presented inside Gantry's existing popover/window.
@MainActor
final class MaintenancePanelViewController: NSViewController {
    private static weak var activeBackdrop: NSView?
    private static var activeController: MaintenancePanelViewController?
    private static var activeOnDismiss: (() -> Void)?

    private let printer: SavedPrinter
    private var telemetry: PrinterTelemetry
    private var body = NSStackView()

    static func show(printer: SavedPrinter, telemetry: PrinterTelemetry, in host: NSView,
                     onDismiss: (() -> Void)? = nil) {
        dismiss()
        let controller = MaintenancePanelViewController(printer: printer, telemetry: telemetry)
        let backdrop = MaintenanceBackdropView(frame: host.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        backdrop.onClickOutside = { MaintenancePanelViewController.dismiss() }

        let panel = controller.view
        panel.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(panel)
        let preferredWidth = panel.widthAnchor.constraint(equalToConstant: 520)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = panel.heightAnchor.constraint(equalToConstant: 680)
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, constant: -24),
            panel.heightAnchor.constraint(lessThanOrEqualTo: backdrop.heightAnchor, constant: -24),
            preferredWidth,
            preferredHeight
        ])
        host.addSubview(backdrop)
        activeBackdrop = backdrop
        activeController = controller
        activeOnDismiss = onDismiss
    }

    static func dismiss() {
        activeBackdrop?.removeFromSuperview()
        activeBackdrop = nil
        activeController = nil
        let completion = activeOnDismiss
        activeOnDismiss = nil
        completion?()
    }

    init(printer: SavedPrinter, telemetry: PrinterTelemetry) {
        self.printer = printer
        self.telemetry = telemetry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 680))
        panel.wantsLayer = true
        panel.layer?.cornerRadius = GantryTheme.cardRadius
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = GantryTheme.line.cgColor
        panel.layer?.backgroundColor = GantryTheme.card.withAlphaComponent(0.98).cgColor
        panel.layer?.masksToBounds = true
        view = panel
        rebuild()
    }

    private func rebuild() {
        guard isViewLoaded else { return }
        let s = AppSettings.shared
        view.appearance = s.appearance
        view.subviews.forEach { $0.removeFromSuperview() }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false

        let snapshot = PrinterInsightsStore.shared.snapshot(serial: printer.serial, polish: s.language == .pl)
        let title = label(s.text("Konserwacja · \(printer.name)", "Maintenance · \(printer.name)"), 20, .bold)
        let instructions = button(s.text("Instrukcje", "Instructions")) { [weak self] in self?.showInstructions() }
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: s.text("Zamknij", "Close"))!,
                             target: self, action: #selector(closePressed))
        close.isBordered = false
        close.contentTintColor = GantryTheme.secondary
        close.toolTip = s.text("Zamknij", "Close")
        let header = NSStackView(views: [title, instructions, NSView(), close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        body.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        let summary = label(String(format: s.text("%.1f h druku · dysza %@", "%.1f print h · nozzle %@"),
                                   snapshot.totalPrintHours,
                                   telemetry.nozzleDiameter.map { String(format: "%.1f mm", $0) } ?? "—"),
                            12, .regular, GantryTheme.secondary)
        body.addArrangedSubview(summary)

        let printerAlerts = alertMessages(settings: s)
        if !printerAlerts.isEmpty {
            body.addArrangedSubview(label(s.text("UWAGI DRUKARKI", "PRINTER ALERTS"), 10, .bold, GantryTheme.muted))
            for alert in printerAlerts {
                let card = printerAlertCard(title: alert.title, code: alert.code)
                body.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            }
        }

        for task in snapshot.tasks {
            let card = taskCard(task, settings: s)
            body.addArrangedSubview(card)
            // The views must share a hierarchy before a cross-view constraint is activated.
            // Activating this inside taskCard() caused an AppKit exception on every open.
            card.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

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

        let document = MaintenanceFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        scroll.documentView = document
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18)
        ])
    }

    @objc private func closePressed() { Self.dismiss() }

    private func alertMessages(settings s: AppSettings) -> [(title: String, code: String?)] {
        let actionableHMS = HMSResolver.shared.actionableCodes(
            telemetry.hmsCodes, serial: printer.serial, language: s.language
        )
        if !actionableHMS.isEmpty {
            return actionableHMS.map { code in
                let description = HMSResolver.shared.description(
                    for: [code], serial: printer.serial, language: s.language
                ) ?? "HMS \(code)"
                return (description, code)
            }
        }
        if telemetry.errorCode != 0 {
            return [(
                String(format: s.text("Kod błędu: 0x%llX", "Error code: 0x%llX"), telemetry.errorCode),
                nil
            )]
        }
        if telemetry.state == .error {
            return [(s.text("Drukarka zgłosiła błąd", "Printer reported an error"), nil)]
        }
        return []
    }

    private func printerAlertCard(title: String, code: String?) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = GantryTheme.tileRadius
        box.layer?.backgroundColor = GantryTheme.statusError.withAlphaComponent(0.08).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = GantryTheme.statusError.withAlphaComponent(0.38).cgColor
        let titleLabel = label("!  \(title)", 12, .semibold, GantryTheme.text)
        var rows: [NSView] = [titleLabel]
        if let code { rows.append(label(code, 10, .regular, GantryTheme.secondary)) }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9)
        ])
        return box
    }

    private func taskCard(_ task: PrinterInsightsStore.TaskStatus, settings s: AppSettings) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = GantryTheme.tileRadius
        box.layer?.borderWidth = 1
        let borderColor: NSColor
        if task.isUrgent { borderColor = GantryTheme.statusError.withAlphaComponent(0.55) }
        else if task.isDue { borderColor = GantryTheme.statusPaused.withAlphaComponent(0.45) }
        else { borderColor = GantryTheme.line }
        box.layer?.borderColor = borderColor.cgColor
        box.layer?.backgroundColor = GantryTheme.surface.cgColor

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
        interval.cell = MaintenanceCenteredTextFieldCell(textCell: interval.stringValue)
        interval.alignment = .center
        interval.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        interval.isBezeled = false
        interval.drawsBackground = true
        interval.backgroundColor = GantryTheme.surface
        interval.textColor = GantryTheme.text
        interval.wantsLayer = true
        interval.layer?.cornerRadius = 7
        interval.layer?.borderWidth = 1
        interval.layer?.borderColor = GantryTheme.line.cgColor
        interval.toolTip = s.text("Interwał w godzinach druku", "Interval in print hours")
        interval.widthAnchor.constraint(equalToConstant: 48).isActive = true
        interval.heightAnchor.constraint(equalToConstant: 28).isActive = true
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
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
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
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.borderWidth = 1
        button.layer?.borderColor = GantryTheme.line.cgColor
        button.layer?.backgroundColor = GantryTheme.surface.cgColor
        button.contentTintColor = GantryTheme.text
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10.5, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
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

/// NSTextField's borderless cell normally draws against the top of a custom-height field. Keep both
/// display and field-editor text vertically centered inside Gantry's 28 pt input pill.
private final class MaintenanceCenteredTextFieldCell: NSTextFieldCell {
    private func centeredRect(_ rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let height = cellSize(forBounds: rect).height
        result.origin.y += max(0, (result.height - height) / 2)
        result.size.height = min(result.height, height)
        return result
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { centeredRect(rect) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centeredRect(rect), in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centeredRect(rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }
}
