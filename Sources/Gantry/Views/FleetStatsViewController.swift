import AppKit

/// Dimmed in-window backdrop. Clicking outside the stats card closes it.
private final class FleetStatsBackdropView: NSView {
    var onClickOutside: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClickOutside?() }
}

/// Fleet-wide totals, presented inside Gantry's existing popover/window like the maintenance and
/// diagnostics panels.
///
/// `PrinterInsights` already records history, print hours and filament use per printer; nothing put
/// those together, so there was no way to answer "how much did I print this month". This aggregates
/// the same records over a chosen period and can write the summary out as plain text.
@MainActor
final class FleetStatsViewController: NSViewController {
    private static weak var activeBackdrop: NSView?
    private static var activeController: FleetStatsViewController?

    private let store: PrinterStore
    private let body = NSStackView()
    private var periodDays = 30
    private var renderedText = ""

    static func show(store: PrinterStore, in host: NSView) {
        dismiss()
        let controller = FleetStatsViewController(store: store)
        let backdrop = FleetStatsBackdropView(frame: host.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        backdrop.onClickOutside = { FleetStatsViewController.dismiss() }

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
    }

    static func dismiss() {
        activeBackdrop?.removeFromSuperview()
        activeBackdrop = nil
        activeController = nil
    }

    init(store: PrinterStore) {
        self.store = store
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
        build()
    }

    private func build() {
        let s = AppSettings.shared
        view.appearance = s.appearance

        let title = label(s.t("Fleet statistics"), 18, .bold, GantryTheme.text)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: s.t("Close"))!,
                             target: self, action: #selector(closePressed))
        close.isBordered = false
        close.contentTintColor = GantryTheme.secondary
        let header = NSStackView(views: [title, NSView(), close])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 8

        let period = NSSegmentedControl(labels: [s.t("7 days"), s.t("30 days"),
                                                 s.t("Year"), s.t("All")],
                                        trackingMode: .selectOne, target: self, action: #selector(periodChanged(_:)))
        period.selectedSegment = 1
        let export = button(s.t("Export to file…"), action: #selector(exportPressed))
        let controls = NSStackView(views: [period, NSView(), export])
        controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing = 8

        body.orientation = .vertical; body.alignment = .leading; body.spacing = 9

        let outer = NSStackView(views: [header, controls, body])
        outer.orientation = .vertical; outer.alignment = .leading; outer.spacing = 12
        outer.translatesAutoresizingMaskIntoConstraints = false

        let document = FleetStatsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(outer)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            outer.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            outer.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            outer.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            outer.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: outer.widthAnchor),
            controls.widthAnchor.constraint(equalTo: outer.widthAnchor),
            body.widthAnchor.constraint(equalTo: outer.widthAnchor)
        ])
        render()
    }

    @objc private func closePressed() { Self.dismiss() }

    @objc private func periodChanged(_ sender: NSSegmentedControl) {
        periodDays = [7, 30, 365, Int.max][max(0, min(3, sender.selectedSegment))]
        render()
    }

    // MARK: Aggregation

    private struct Row {
        let name: String, prints: Int, failed: Int, hours: Double, grams: Double
        var successPercent: Int? {
            prints == 0 ? nil : Int((Double(prints - failed) / Double(prints) * 100).rounded())
        }
    }

    private func rows() -> [Row] {
        let polish = AppSettings.shared.isPolish
        let cutoff = periodDays == Int.max ? Date.distantPast
                                           : Date().addingTimeInterval(-Double(periodDays) * 86_400)
        return store.printers.map { printer in
            let snapshot = PrinterInsightsStore.shared.snapshot(serial: printer.serial, polish: polish)
            let entries = snapshot.history.filter { $0.endedAt >= cutoff }
            // Print hours and grams are lifetime counters, so a period view derives hours from the
            // entries themselves and only shows lifetime filament when no period is applied.
            let hours = entries.reduce(0.0) { $0 + $1.durationSeconds } / 3600
            let grams = periodDays == Int.max ? snapshot.consumedGrams : 0
            return Row(name: printer.name, prints: entries.count,
                       failed: entries.filter { $0.result != .completed }.count,
                       hours: periodDays == Int.max ? snapshot.totalPrintHours : hours,
                       grams: grams)
        }
    }

    private func render() {
        let s = AppSettings.shared
        body.arrangedSubviews.forEach { body.removeArrangedSubview($0); $0.removeFromSuperview() }
        let all = rows()
        let prints = all.reduce(0) { $0 + $1.prints }
        let failed = all.reduce(0) { $0 + $1.failed }
        let hours = all.reduce(0.0) { $0 + $1.hours }
        let grams = all.reduce(0.0) { $0 + $1.grams }
        let success = prints == 0 ? nil : Int((Double(prints - failed) / Double(prints) * 100).rounded())

        var lines: [String] = []
        lines.append(String(format: s.t("Period: %@"), periodLabel()))
        lines.append(String(format: s.t("Prints: %d (failed: %d)"), prints, failed))
        lines.append(String(format: s.t("Success rate: %@"),
                            success.map { "\($0)%" } ?? "—"))
        lines.append(String(format: s.t("Print time: %.1f h"), hours))
        if grams > 0 {
            lines.append(String(format: s.t("Filament: %.2f kg"), grams / 1000))
        }

        body.addArrangedSubview(label(s.t("SUMMARY"), 10, .bold, GantryTheme.muted))
        let summary = card(lines)
        body.addArrangedSubview(summary)
        summary.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        body.addArrangedSubview(label(s.t("BY PRINTER"), 10, .bold, GantryTheme.muted))
        if all.isEmpty {
            body.addArrangedSubview(label(s.t("No printers."), 12, .regular, GantryTheme.secondary))
        }
        for row in all.sorted(by: { $0.prints > $1.prints }) {
            let detail = String(format: s.t("%d prints · %.1f h · %@"),
                                row.prints, row.hours, row.successPercent.map { "\($0)%" } ?? "—")
            let box = card([row.name, detail], titleFirst: true)
            body.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        renderedText = plainText(all: all, prints: prints, failed: failed, hours: hours,
                                 grams: grams, success: success)
    }

    private func periodLabel() -> String {
        let s = AppSettings.shared
        switch periodDays {
        case 7: return s.t("last 7 days")
        case 30: return s.t("last 30 days")
        case 365: return s.t("last year")
        default: return s.t("all time")
        }
    }

    // MARK: Export

    private func plainText(all: [Row], prints: Int, failed: Int, hours: Double,
                           grams: Double, success: Int?) -> String {
        let s = AppSettings.shared
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        var out = ["Gantry \(s.t("fleet statistics"))",
                   "\(s.t("Generated")): \(stamp.string(from: Date()))",
                   "\(s.t("Period")): \(periodLabel())",
                   "",
                   "\(s.t("Prints")): \(prints)  (\(s.t("failed")): \(failed))",
                   "\(s.t("Success rate")): \(success.map { "\($0)%" } ?? "—")",
                   String(format: "\(s.t("Print time")): %.1f h", hours)]
        if grams > 0 { out.append(String(format: "\(s.t("Filament")): %.2f kg", grams / 1000)) }
        out.append("")
        out.append(s.t("By printer:"))
        for row in all.sorted(by: { $0.prints > $1.prints }) {
            out.append(String(format: "  %@: %d %@, %.1f h, %@", row.name, row.prints,
                              s.t("prints"), row.hours,
                              row.successPercent.map { "\($0)%" } ?? "—"))
        }
        return out.joined(separator: "\n") + "\n"
    }

    @objc private func exportPressed() {
        let s = AppSettings.shared
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "gantry-statystyki.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.renderedText.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = s.t("Could not save the file.")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: Building blocks

    private func card(_ lines: [String], titleFirst: Bool = false) -> NSView {
        var views: [NSView] = []
        for (index, text) in lines.enumerated() {
            let isTitle = titleFirst && index == 0
            views.append(label(text, isTitle ? 13 : 11, isTitle ? .semibold : .regular,
                               isTitle ? GantryTheme.text : GantryTheme.secondary))
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView(); box.wantsLayer = true; box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = GantryTheme.card.withAlphaComponent(0.72).cgColor
        box.layer?.borderWidth = 1; box.layer?.borderColor = GantryTheme.line.cgColor
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -11),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)
        ])
        return box
    }

    private func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight,
                       _ color: NSColor = GantryTheme.text) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: text)
        value.font = .systemFont(ofSize: size, weight: weight)
        value.textColor = color
        return value
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.borderWidth = 1
        button.layer?.borderColor = GantryTheme.line.cgColor
        button.layer?.backgroundColor = GantryTheme.surface.cgColor
        button.contentTintColor = GantryTheme.text
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }
}

/// Top-down layout for the scrolling document. `nonisolated` because AppKit reads isFlipped on every
/// hit-test: a dynamic isolation check there is pure overhead, and it crashes on macOS 27 beta.
private final class FleetStatsFlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}
