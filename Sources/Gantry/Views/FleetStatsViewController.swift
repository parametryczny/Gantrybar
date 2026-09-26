import AppKit

/// Fleet-wide totals in a window of their own, centred on the screen.
///
/// `PrinterInsights` already records history, print hours and filament use per printer; nothing put
/// those together, so there was no way to answer "how much did I print this month". This aggregates
/// the same records over a chosen period and can write the summary out as plain text.
@MainActor
final class FleetStatsViewController: NSViewController {
    private static var activePanel: PanelWindowController?
    private static var activeController: FleetStatsViewController?

    private let store: PrinterStore
    private let body = NSStackView()
    private var periodDays = 30
    private var renderedText = ""
    private var renderedCSV = ""

    static func show(store: PrinterStore) {
        dismiss()
        let controller = FleetStatsViewController(store: store)
        activeController = controller
        activePanel = PanelWindowController.present(controller.view,
            name: AppSettings.shared.t("Fleet statistics"),
            size: NSSize(width: 560, height: 640),
            onDismiss: { Self.dismiss() })
    }

    /// The static is cleared before the window is closed, not after: closing it runs the dismissal
    /// callback, which lands back here, and an already-empty static is what stops the recursion.
    static func dismiss() {
        let panel = activePanel
        activePanel = nil
        activeController = nil
        panel?.dismiss()
    }

    init(store: PrinterStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 640))
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

        let period = NSSegmentedControl(labels: [s.t("7 days"), s.t("30 days"),
                                                 s.t("Year"), s.t("All")],
                                        trackingMode: .selectOne, target: self, action: #selector(periodChanged(_:)))
        period.selectedSegment = 1
        let export = button(s.t("Export to file…"), action: #selector(exportPressed))
        let exportCSV = button(s.t("CSV…"), action: #selector(exportCSVPressed))
        let prices = button(s.t("Prices…"), action: #selector(pricesPressed))
        let controls = NSStackView(views: [period, NSView(), prices, exportCSV, export])
        controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing = 8

        body.orientation = .vertical; body.alignment = .leading; body.spacing = 9

        let outer = NSStackView(views: [controls, body])
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
            controls.widthAnchor.constraint(equalTo: outer.widthAnchor),
            body.widthAnchor.constraint(equalTo: outer.widthAnchor)
        ])
        render()
    }

    @objc private func periodChanged(_ sender: NSSegmentedControl) {
        periodDays = [7, 30, 365, Int.max][max(0, min(3, sender.selectedSegment))]
        render()
    }

    // MARK: Aggregation

    /// One finished (or failed) print with what it cost.
    private struct PrintLine {
        let printer: String
        let serial: String
        let entry: PrinterInsightsStore.HistoryEntry
        let uses: [PrintCost.Use]
        let cost: PrintCost
        var ok: Bool { entry.result == .completed }
    }

    private struct Row {
        let name: String, prints: Int, failed: Int, hours: Double, grams: Double, cost: Double
        let utilization: Double?
        var successPercent: Int? {
            prints == 0 ? nil : Int((Double(prints - failed) / Double(prints) * 100).rounded())
        }
    }

    private var cutoff: Date {
        periodDays == Int.max ? .distantPast : Date().addingTimeInterval(-Double(periodDays) * 86_400)
    }

    private func lines() -> [PrintLine] {
        let polish = AppSettings.shared.isPolish, settings = PrintCostSettings.current, from = cutoff
        return store.printers.flatMap { printer -> [PrintLine] in
            PrinterInsightsStore.shared.snapshot(serial: printer.serial, polish: polish).history
                .filter { $0.endedAt >= from }
                .map { entry in
                    let uses = PrintCost.uses(serial: printer.serial, startedAt: entry.startedAt, endedAt: entry.endedAt)
                    return PrintLine(printer: printer.name, serial: printer.serial, entry: entry, uses: uses,
                                     cost: .compute(durationSeconds: entry.durationSeconds, uses: uses,
                                                    serial: printer.serial, settings: settings))
                }
        }.sorted { $0.entry.endedAt > $1.entry.endedAt }
    }

    private func rows(_ all: [PrintLine]) -> [Row] {
        let now = Date()
        return store.printers.map { printer in
            let mine = all.filter { $0.serial == printer.serial }
            let hours = mine.reduce(0.0) { $0 + $1.entry.durationSeconds } / 3600
            // Share of the period the printer spent printing. "All" starts at its first recorded print.
            let start: Date? = periodDays == Int.max ? mine.map(\.entry.startedAt).min() : cutoff
            let span = start.map { now.timeIntervalSince($0) / 3600 } ?? 0
            return Row(name: printer.name, prints: mine.count,
                       failed: mine.filter { !$0.ok }.count, hours: hours,
                       grams: mine.reduce(0.0) { $0 + ($1.cost.grams ?? 0) },
                       cost: mine.reduce(0.0) { $0 + $1.cost.total },
                       utilization: span > 1 ? min(1, hours / span) : nil)
        }
    }

    /// Prints per week for the last eight weeks, oldest first, as a one-line bar chart.
    private func weeklyTrend(_ all: [PrintLine]) -> (bars: String, counts: [Int]) {
        let week = 7 * 86_400.0, now = Date()
        var counts = Array(repeating: 0, count: 8)
        for line in all {
            let age = Int(now.timeIntervalSince(line.entry.endedAt) / week)
            if (0..<8).contains(age) { counts[7 - age] += 1 }
        }
        let ticks = Array("▁▂▃▄▅▆▇█"), top = max(1, counts.max() ?? 1)
        let bars = String(counts.map { $0 == 0 ? "·" : ticks[min(7, ($0 * 8 - 1) / top)] })
        return (bars, counts)
    }

    private func money(_ value: Double) -> String {
        String(format: "%.2f %@", value, PrintCostSettings.current.currency)
    }

    private func render() {
        let s = AppSettings.shared
        body.arrangedSubviews.forEach { body.removeArrangedSubview($0); $0.removeFromSuperview() }
        let all = lines()
        let byPrinter = rows(all)
        let prints = all.count
        let failed = all.filter { !$0.ok }.count
        let hours = all.reduce(0.0) { $0 + $1.entry.durationSeconds } / 3600
        let grams = all.reduce(0.0) { $0 + ($1.cost.grams ?? 0) }
        let success = prints == 0 ? nil : Int((Double(prints - failed) / Double(prints) * 100).rounded())
        let cost = all.reduce(0.0) { $0 + $1.cost.total }
        let filamentCost = all.reduce(0.0) { $0 + ($1.cost.filament ?? 0) }
        let energy = all.reduce(0.0) { $0 + $1.cost.energy }
        let machine = all.reduce(0.0) { $0 + $1.cost.machine }
        let wasted = all.filter { !$0.ok }.reduce(0.0) { $0 + $1.cost.total }
        let completed = all.filter(\.ok)
        let unknownFilament = all.filter { $0.cost.filament == nil }.count

        var summary: [String] = []
        summary.append(s.t("Period: {0}", periodLabel()))
        summary.append(s.t("Prints: {0} (failed: {1})", prints, failed))
        summary.append(s.t("Success rate: {0}", success.map { "\($0)%" } ?? "—"))
        summary.append(s.t("Print time: {0} h", String(format: "%.1f", hours)))
        if grams > 0 { summary.append(s.t("Filament: {0} kg", String(format: "%.2f", grams / 1000))) }
        let used = byPrinter.compactMap(\.utilization)
        if !used.isEmpty {
            summary.append(s.t("Printer utilization: {0}%", Int((used.reduce(0, +) / Double(used.count) * 100).rounded())))
        }
        body.addArrangedSubview(label(s.t("SUMMARY"), 10, .bold, GantryTheme.muted))
        add(card(summary))

        body.addArrangedSubview(label(s.t("COSTS"), 10, .bold, GantryTheme.muted))
        var costs = [s.t("Total: {0}", money(cost)),
                     s.t("Filament {0} · electricity {1} · machine time {2}", money(filamentCost), money(energy), money(machine))]
        if !completed.isEmpty {
            costs.append(s.t("Average successful print: {0}", money(completed.reduce(0.0) { $0 + $1.cost.total } / Double(completed.count))))
        }
        if wasted > 0 { costs.append(s.t("Lost on failed prints: {0}", money(wasted))) }
        if unknownFilament > 0 {
            costs.append(s.t("{0} prints without filament data — assign rolls in Spoolbase to count it.", unknownFilament))
        }
        add(card(costs))

        let trend = weeklyTrend(periodDays <= 30 ? lines(since: Date().addingTimeInterval(-56 * 86_400)) : all)
        var materials: [String: Double] = [:]
        for line in all { for use in line.uses { materials[(use.material ?? "?").uppercased(), default: 0] += use.grams } }
        var jobs: [String: Int] = [:]
        for line in completed where !line.entry.job.isEmpty { jobs[line.entry.job, default: 0] += 1 }
        body.addArrangedSubview(label(s.t("PRODUCTION"), 10, .bold, GantryTheme.muted))
        var production = [s.t("Prints per week (8 weeks): {0}  {1}", trend.bars, trend.counts.map(String.init).joined(separator: " "))]
        if !materials.isEmpty {
            production.append(s.t("By material: {0}", materials.sorted { $0.value > $1.value }
                .map { "\($0.key) \(String(format: "%.2f", $0.value / 1000)) kg" }.joined(separator: " · ")))
        }
        if !jobs.isEmpty {
            production.append(s.t("Most printed: {0}", jobs.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .prefix(5).map { "\($0.key) ×\($0.value)" }.joined(separator: " · ")))
        }
        let cancelled = all.filter { $0.entry.result == .cancelled }.count
        if failed > 0 { production.append(s.t("Unsuccessful: {0} errors · {1} cancelled", failed - cancelled, cancelled)) }
        add(card(production))

        body.addArrangedSubview(label(s.t("BY PRINTER"), 10, .bold, GantryTheme.muted))
        if byPrinter.isEmpty {
            body.addArrangedSubview(label(s.t("No printers."), 12, .regular, GantryTheme.secondary))
        }
        for row in byPrinter.sorted(by: { $0.prints > $1.prints }) {
            var detail = s.t("{0} prints · {1} h · {2}", row.prints, String(format: "%.1f", row.hours),
                             row.successPercent.map { "\($0)%" } ?? "—")
            detail += " · " + money(row.cost)
            if let u = row.utilization { detail += " · " + s.t("utilization {0}%", Int((u * 100).rounded())) }
            add(card([row.name, detail], titleFirst: true))
        }

        if !all.isEmpty {
            body.addArrangedSubview(label(s.t("RECENT PRINTS"), 10, .bold, GantryTheme.muted))
            let stamp = DateFormatter(); stamp.dateFormat = "dd.MM HH:mm"
            let recent = all.prefix(15).map { line -> String in
                let mark = line.ok ? "✓" : "✕"
                let g = line.cost.grams.map { String(format: " · %.0f g", $0) } ?? ""
                return "\(mark) \(stamp.string(from: line.entry.endedAt)) · \(line.printer) · "
                    + (line.entry.job.isEmpty ? "—" : line.entry.job)
                    + String(format: " · %.1f h", line.entry.durationSeconds / 3600) + g + " · " + money(line.cost.total)
            }
            add(card(Array(recent)))
        }

        renderedText = plainText(all: byPrinter, prints: prints, failed: failed, hours: hours,
                                 grams: grams, success: success, cost: cost)
        renderedCSV = csv(all)
    }

    private func lines(since date: Date) -> [PrintLine] {
        let saved = periodDays
        periodDays = max(1, Int(Date().timeIntervalSince(date) / 86_400) + 1)
        defer { periodDays = saved }
        return lines()
    }

    private func add(_ view: NSView) {
        body.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
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
                           grams: Double, success: Int?, cost: Double) -> String {
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
        out.append("\(s.t("Cost")): \(money(cost))")
        out.append("")
        out.append(s.t("By printer:"))
        for row in all.sorted(by: { $0.prints > $1.prints }) {
            out.append(String(format: "  %@: %d %@, %.1f h, %@, %@", row.name, row.prints,
                              s.t("prints"), row.hours,
                              row.successPercent.map { "\($0)%" } ?? "—", money(row.cost)))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// One row per print, for a spreadsheet. Semicolon-separated with a decimal comma when the app is in
    /// Polish, so Excel and Numbers in a Polish locale open it into columns without an import dialog.
    private func csv(_ all: [PrintLine]) -> String {
        let polish = AppSettings.shared.isPolish, sep = polish ? ";" : ","
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH:mm"; stamp.locale = Locale(identifier: "en_US_POSIX")
        func num(_ v: Double?) -> String {
            guard let v else { return "" }
            let text = String(format: "%.2f", v)
            return polish ? text.replacingOccurrences(of: ".", with: ",") : text
        }
        func field(_ text: String) -> String {
            text.contains(sep) || text.contains("\"") || text.contains("\n")
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        let currency = PrintCostSettings.current.currency
        var out = [["start", "end", "printer", "job", "result", "hours", "grams", "kWh",
                    "filament_\(currency)", "energy_\(currency)", "machine_\(currency)", "total_\(currency)"].joined(separator: sep)]
        for line in all.reversed() {
            out.append([stamp.string(from: line.entry.startedAt), stamp.string(from: line.entry.endedAt),
                        field(line.printer), field(line.entry.job), line.entry.result.rawValue,
                        num(line.entry.durationSeconds / 3600), num(line.cost.grams), num(line.cost.kWh),
                        num(line.cost.filament), num(line.cost.energy), num(line.cost.machine),
                        num(line.cost.total)].joined(separator: sep))
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
                ModalHost.run(alert)
            }
        }
    }

    @objc private func exportCSVPressed() {
        let s = AppSettings.shared
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "gantry-wydruki.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                // BOM so Excel reads the file as UTF-8 (Polish letters in job names).
                try Data(("\u{FEFF}" + self.renderedCSV).utf8).write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.messageText = s.t("Could not save the file.")
                alert.informativeText = error.localizedDescription
                ModalHost.run(alert)
            }
        }
    }

    @objc private func pricesPressed() {
        let s = AppSettings.shared
        var settings = PrintCostSettings.current
        func field(_ value: String) -> NSTextField {
            let f = NSTextField(string: value); f.widthAnchor.constraint(equalToConstant: 170).isActive = true; return f
        }
        func number(_ v: Double) -> String { String(format: "%g", v) }
        let currency = field(settings.currency)
        let perKg = field(number(settings.filamentPerKg))
        let materials = field(settings.materialPerKg.sorted { $0.key < $1.key }.map { "\($0.key)=\(number($0.value))" }.joined(separator: ", "))
        materials.placeholderString = "PETG=90, ASA=120"
        let kWh = field(number(settings.electricityPerKWh))
        let watts = field(number(settings.printerWatts))
        let machine = field(number(settings.machinePerHour))
        let grid = NSGridView(views: [
            [label(s.t("Currency"), 12, .regular), currency],
            [label(s.t("Filament per kg"), 12, .regular), perKg],
            [label(s.t("Per material (per kg)"), 12, .regular), materials],
            [label(s.t("Electricity per kWh"), 12, .regular), kWh],
            [label(s.t("Average printer power (W)"), 12, .regular), watts],
            [label(s.t("Machine time per hour"), 12, .regular), machine]
        ])
        grid.rowSpacing = 8; grid.columnSpacing = 10
        grid.frame = NSRect(x: 0, y: 0, width: 380, height: 190)
        let alert = NSAlert()
        alert.messageText = s.t("Print cost prices")
        alert.informativeText = s.t("Used to price every print: filament from Spoolbase usage, electricity and machine time from its duration.")
        alert.accessoryView = grid
        alert.addButton(withTitle: s.t("Save"))
        alert.addButton(withTitle: s.t("Cancel"))
        guard ModalHost.run(alert) == .alertFirstButtonReturn else { return }
        func parse(_ f: NSTextField) -> Double? {
            Double(f.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil }
        }
        let name = currency.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { settings.currency = String(name.prefix(8)) }
        if let v = parse(perKg) { settings.filamentPerKg = v }
        if let v = parse(kWh) { settings.electricityPerKWh = v }
        if let v = parse(watts) { settings.printerWatts = v }
        if let v = parse(machine) { settings.machinePerHour = v }
        settings.materialPerKg = PrintCostSettings.parseMaterialPrices(materials.stringValue)
        PrintCostSettings.current = settings
        render()
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
