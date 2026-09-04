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
        let preferredWidth = panel.widthAnchor.constraint(equalToConstant: 470)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = panel.heightAnchor.constraint(equalToConstant: 560)
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
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 560))
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

        body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false

        let snapshot = PrinterInsightsStore.shared.snapshot(serial: printer.serial, polish: s.isPolish)
        let title = label(String(format: s.t("Maintenance · %@"), printer.name), 18, .bold)
        let instructions = button(s.t("Instructions")) { [weak self] in self?.showInstructions() }
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: s.t("Close"))!,
                             target: self, action: #selector(closePressed))
        close.isBordered = false
        close.contentTintColor = GantryTheme.secondary
        close.toolTip = s.t("Close")
        let header = NSStackView(views: [title, instructions, NSView(), close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        body.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        let summary = label(String(format: s.t("%.1f print h · nozzle %@"),
                                   snapshot.totalPrintHours,
                                   telemetry.nozzleDiameter.map { String(format: "%.1f mm", $0) } ?? "—"),
                            12, .regular, GantryTheme.secondary)
        body.addArrangedSubview(summary)

        let printerAlerts = alertMessages(settings: s)
        if !printerAlerts.isEmpty {
            body.addArrangedSubview(label(s.t("PRINTER ALERTS"), 10, .bold, GantryTheme.muted))
            let alertList = compactAlertList(printerAlerts)
            body.addArrangedSubview(alertList)
            alertList.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        let taskGrid = twoColumnGrid(snapshot.tasks.map { taskCard($0, settings: s) })
        body.addArrangedSubview(taskGrid)
        taskGrid.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        let recent = Array(snapshot.history.prefix(3))
        var historyRows: [NSView] = [label(s.t("RECENT PRINTS"), 10, .bold, GantryTheme.muted)]
        if recent.isEmpty {
            historyRows.append(label(s.t("No recorded history."), 12, .regular, GantryTheme.secondary))
        } else {
            for entry in recent {
                let icon = entry.result == .completed ? "✓" : entry.result == .failed ? "!" : "×"
                let duration = formatDuration(entry.durationSeconds)
                let text = "\(icon)  \(entry.job.isEmpty ? s.t("Untitled") : entry.job)  ·  \(duration)"
                historyRows.append(label(text, 11.5, .medium, entry.result == .completed ? GantryTheme.text : .systemOrange))
            }
        }
        let history = compactSection(historyRows)
        let stats = statisticsSection(snapshot: snapshot, settings: s)
        let footerGrid = twoColumnGrid([history, stats])
        body.addArrangedSubview(footerGrid)
        footerGrid.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            body.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18)
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
                String(format: s.t("Error code: 0x%llX"), telemetry.errorCode),
                nil
            )]
        }
        if telemetry.state == .error {
            return [(s.t("Printer reported an error"), nil)]
        }
        return []
    }

    private func printerAlertCard(title: String, code: String?) -> NSView {
        let box = NSView()
        let titleLabel = label("!  \(title)", 11, .semibold, GantryTheme.text)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        var rows: [NSView] = [titleLabel]
        if let code { rows.append(label(code, 10, .regular, GantryTheme.secondary)) }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7)
        ])
        return box
    }

    private func compactAlertList(_ alerts: [(title: String, code: String?)]) -> NSView {
        var rows: [NSView] = []
        for (index, alert) in alerts.enumerated() {
            if index > 0 {
                let separator = NSView()
                separator.wantsLayer = true
                separator.layer?.backgroundColor = GantryTheme.statusError.withAlphaComponent(0.22).cgColor
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
                rows.append(separator)
            }
            rows.append(printerAlertCard(title: alert.title, code: alert.code))
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = GantryTheme.statusError.withAlphaComponent(0.08).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = GantryTheme.statusError.withAlphaComponent(0.38).cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor)
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
        let title = label("\(icon)  \(task.title)", 11, .semibold)
        let timing: String
        if task.isDue {
            timing = String(format: s.t("Overdue by %.0f h"), task.overdueHours)
        } else if let until = task.snoozedUntil, until > Date() {
            // Day + month only: the full date pushed the task title into an ellipsis in a two-column card.
            let day = until.formatted(.dateTime.day().month(.abbreviated))
            timing = String(format: s.t("Snoozed until %@"), day)
        } else {
            timing = String(format: s.t("In %.0f print h"), task.remainingHours)
        }
        let timingLabel = label(timing.replacingOccurrences(of: " druku", with: ""), 10, .regular, GantryTheme.secondary)
        timingLabel.setContentHuggingPriority(.required, for: .horizontal)
        // The task name matters more than the exact timing, so let the timing shrink first.
        timingLabel.lineBreakMode = .byTruncatingTail
        timingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(760), for: .horizontal)
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
        interval.toolTip = s.t("Interval in print hours")
        // Wide enough for a four-digit interval (some axis tasks run into the thousands of hours).
        interval.widthAnchor.constraint(equalToConstant: 44).isActive = true
        interval.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let hours = label("h", 11, .regular, GantryTheme.muted)
        let save = button("✎") { [weak self, weak interval] in
            guard let self, let value = Double(interval?.stringValue ?? ""), value >= 1 else { return }
            PrinterInsightsStore.shared.setInterval(serial: self.printer.serial, taskID: task.id, hours: value)
            self.rebuild()
        }
        save.toolTip = s.t("Set interval")
        let intervalRow = NSStackView(views: [interval, hours, save])
        intervalRow.orientation = .horizontal; intervalRow.alignment = .centerY; intervalRow.spacing = 2
        let done = button(s.t("Done")) { [weak self] in
            guard let self else { return }
            PrinterInsightsStore.shared.complete(serial: self.printer.serial, taskID: task.id)
            self.rebuild()
        }
        let snooze = button("7d") { [weak self] in
            guard let self else { return }
            PrinterInsightsStore.shared.snooze(serial: self.printer.serial, taskID: task.id)
            self.rebuild()
        }
        snooze.toolTip = s.t("Remind in 7 days")
        let heading = NSStackView(views: [title, NSView(), timingLabel])
        heading.orientation = .horizontal; heading.alignment = .centerY; heading.spacing = 6
        // A plain spacer absorbs the slack so every control keeps its natural width. With
        // .fillProportionally the row stretched each item (including the nested interval row), which
        // pushed "h" and the pencil to a different spot in every card depending on the digit count.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [done, snooze, spacer, intervalRow])
        actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 4
        actions.distribution = .fill
        for control in [done, snooze, intervalRow] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(760), for: .horizontal)
        }
        let stack = NSStackView(views: [heading, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return box
    }

    private func twoColumnGrid(_ views: [NSView]) -> NSStackView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 7
        for index in stride(from: 0, to: views.count, by: 2) {
            let first = views[index]
            let second = index + 1 < views.count ? views[index + 1] : NSView()
            let row = NSStackView(views: [first, second])
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 7
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        return grid
    }

    private func compactSection(_ rows: [NSView]) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = GantryTheme.tileRadius
        box.layer?.borderWidth = 1
        box.layer?.borderColor = GantryTheme.line.cgColor
        box.layer?.backgroundColor = GantryTheme.surface.cgColor
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)
        ])
        return box
    }

    private func statisticsSection(snapshot: PrinterInsightsStore.Snapshot, settings s: AppSettings) -> NSView {
        func metric(_ value: String, _ caption: String) -> NSView {
            let valueLabel = label(value, 14, .bold)
            valueLabel.alignment = .center
            let captionLabel = label(caption, 10, .regular, GantryTheme.muted)
            captionLabel.alignment = .center
            let stack = NSStackView(views: [valueLabel, captionLabel])
            stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 2
            return stack
        }
        let metrics = NSStackView(views: [
            metric("\(snapshot.completedCount)", s.t("completed")),
            metric(snapshot.successPercent.map { "\($0)%" } ?? "—", s.t("success")),
            metric(String(format: "%.0f g", snapshot.consumedGrams), s.t("filament"))
        ])
        metrics.orientation = .horizontal
        metrics.alignment = .centerY
        metrics.distribution = .fillEqually
        metrics.spacing = 8
        let title = label(s.t("STATISTICS"), 10, .bold, GantryTheme.muted)
        let stack = NSStackView(views: [title, metrics])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        metrics.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return compactSection([stack])
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
        button.font = .systemFont(ofSize: 10, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func showInstructions() {
        let s = AppSettings.shared
        let alert = NSAlert()
        alert.messageText = s.t("Maintenance instructions")
        alert.informativeText = s.t("Power off and cool the printer. Clean guide rods, use manufacturer-approved lubricant, then inspect belts and nozzle. The manufacturer guide always takes precedence.")
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
