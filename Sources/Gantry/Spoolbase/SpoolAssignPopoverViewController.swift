import AppKit

/// In-window overlay shown when an AMS/EXT slot on a printer card is clicked: assign a physical spool
/// to this slot, move one here from another printer, or create a new roll from the Spoolbase catalog.
/// Styled to match the rest of Gantry (tokens, section headers, card rows).
@MainActor
final class SpoolAssignPopoverViewController: NSViewController {
    private let printerSerial: String
    private let location: SpoolLocation
    private let slotTitle: String
    private let amsMaterial: String?
    private let amsColorHex: String?
    private let onChange: () -> Void
    var onClose: (() -> Void)?

    private let spools = SpoolbaseShared.spools
    private let filaments = SpoolbaseShared.filaments

    init(printerSerial: String, location: SpoolLocation, slotTitle: String,
         amsMaterial: String?, amsColorHex: String?, onChange: @escaping () -> Void) {
        self.printerSerial = printerSerial
        self.location = location
        self.slotTitle = slotTitle
        self.amsMaterial = amsMaterial?.isEmpty == true ? nil : amsMaterial
        self.amsColorHex = amsColorHex
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0x151719).cgColor
        root.layer?.cornerRadius = 14
        root.layer?.borderWidth = 1
        root.layer?.borderColor = GantryTheme.line.cgColor
        root.layer?.masksToBounds = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // It fills its window. The width used to come from the longest filament name, which was right
        // for an overlay in a popover and wrong for a window the user can resize.
        showMain()
    }

    private func t(_ english: String) -> String { AppSettings.shared.t(english) }
    private func t(_ english: String, _ arguments: Any...) -> String {
        AppSettings.shared.t(english, arguments: arguments)
    }

    /// Names of saved printers, so a roll loaded elsewhere shows *where* right on its row (spec: see it
    /// at the filament, before selecting).
    private lazy var printerNames: [String: String] =
        Dictionary(PrinterPersistence().load().map { ($0.serial, $0.name) }, uniquingKeysWith: { first, _ in first })

    /// A short location for a roll: "magazyn", or "<printer> · A2" / "<printer> · EXT".
    private func placeLabel(_ loc: SpoolLocation) -> String {
        guard !loc.isStorage else { return t("storage") }
        let name = loc.printerSerial.flatMap { printerNames[$0] } ?? loc.printerSerial ?? t("printer")
        let slot: String
        if loc.feeder == .ext { slot = "EXT" }
        else if let s = loc.slot { slot = (loc.amsIndex ?? 0) == 0 ? "A\(s + 1)" : "AMS\((loc.amsIndex ?? 0) + 1) \(s + 1)" }
        else { slot = "AMS" }
        return "\(name) · \(slot)"
    }

    // MARK: Screens

    /// Main screen (spec §3): the assigned roll on top (with weigh / reset / unassign), then the physical
    /// rolls you can move here, then a "create new roll" button and the catalog grouped by type. The whole
    /// lower region scrolls as one, so a long inventory never squashes the list.
    private func showMain() {
        // The slot's name is in the window header; the body only adds what the printer reports for it.
        let header = note(t("AMS: {0}", amsMaterial ?? t("unknown")))

        // 1. The roll currently in this slot + its per-roll actions. Weight and history live on the roll,
        // never on the slot, so unassigning only moves it to storage (its grams are kept).
        let assignedSection = NSStackView()
        assignedSection.orientation = .vertical
        assignedSection.alignment = .leading
        assignedSection.spacing = 6
        assignedSection.addArrangedSubview(sectionHeader(t("ASSIGNED SPOOL")))
        if let assigned = spools.spool(at: location) {
            let def = filaments.filaments.first { $0.id == assigned.filamentDefinitionID }
            assignedSection.addArrangedSubview(row(
                dot: def.map { NSColor(filamentHex: $0.colorHex) },
                title: def.map { "\($0.brand) \($0.name)".trimmingCharacters(in: .whitespaces) } ?? assigned.id,
                subtitle: "\(assigned.id) · \(Int(assigned.remainingWeightGrams)) g · \(assigned.percent)%",
                action: {}))
            let actions = NSStackView(views: [
                pill(t("Weigh"), filled: false) { [weak self] in self?.showCorrectWeight(assigned) },
                pill(t("Reset"), filled: false) { [weak self] in self?.confirmReset(assigned) },
                pill(t("Unassign"), filled: false) { [weak self] in
                    guard let self else { return }
                    self.spools.assign(spoolID: assigned.id, to: .storage)
                    self.onChange(); self.showMain()
                }])
            actions.orientation = .horizontal
            actions.spacing = 6
            assignedSection.addArrangedSubview(actions)
        } else {
            let none = NSTextField(labelWithString: t("None"))
            none.font = .systemFont(ofSize: 12)
            none.textColor = GantryTheme.secondary
            assignedSection.addArrangedSubview(none)
        }

        // 2. Existing physical rolls (in storage or loaded on another printer) — matching filament first.
        // Clicking one only moves it here: its remembered grams are never re-asked or reset (spec §3–4).
        let rollsSection = NSStackView()
        rollsSection.orientation = .vertical
        rollsSection.alignment = .leading
        rollsSection.spacing = 6
        rollsSection.addArrangedSubview(sectionHeader(t("AVAILABLE ROLLS")))
        let assignedID = spools.spool(at: location)?.id
        let available = spools.spools
            .filter { $0.status != .archived && !$0.location.sameSlot(as: location) && $0.id != assignedID }
            .sorted { a, b in
                let am = matchesSpool(a), bm = matchesSpool(b)
                if am != bm { return am }
                if a.location.isStorage != b.location.isStorage { return a.location.isStorage }
                return a.id < b.id
            }
        if available.isEmpty {
            rollsSection.addArrangedSubview(note(t("No spare rolls. Create one below.")))
        } else {
            for spool in available {
                let def = filaments.filaments.first { $0.id == spool.filamentDefinitionID }
                let name = def.map { "\($0.brand) \($0.name)".trimmingCharacters(in: .whitespaces) } ?? spool.id
                rollsSection.addArrangedSubview(row(
                    dot: def.map { NSColor(filamentHex: $0.colorHex) },
                    title: name.isEmpty ? spool.id : name,
                    subtitle: "\(spool.id) · \(Int(spool.remainingWeightGrams)) g · \(placeLabel(spool.location))"
                        + (spool.price.map { " · " + Self.money($0) } ?? ""),
                    highlight: matchesSpool(spool),
                    onDelete: { [weak self] in
                        guard let self else { return }
                        self.spools.delete(id: spool.id); self.onChange(); self.showMain()
                    }) { [weak self] in self?.assign(spool) })
            }
        }

        // 3. Create a brand-new roll: a guided button, plus the whole catalog grouped by type so a
        // filament is easy to find. Picking a filament asks for the starting grams (spec §2).
        let newRoll = pill(t("+ Create new roll"), filled: false) { [weak self] in
            self?.showPickFilament()
        }

        let catalogSection = NSStackView()
        catalogSection.orientation = .vertical
        catalogSection.alignment = .leading
        catalogSection.spacing = 6
        catalogSection.addArrangedSubview(sectionHeader(t("FILAMENTS (NEW ROLL)")))
        let defs = filaments.filaments.sorted { a, b in
            if a.type != b.type { return a.type < b.type }
            let am = matchesDef(a), bm = matchesDef(b)
            if am != bm { return am }
            return "\(a.brand)\(a.name)" < "\(b.brand)\(b.name)"
        }
        if defs.isEmpty {
            catalogSection.addArrangedSubview(note(t("Empty. Add filaments in the Spoolbase window.")))
        } else {
            var lastType: String?
            for def in defs {
                if def.type != lastType {
                    catalogSection.addArrangedSubview(typeLabel(def.type))
                    lastType = def.type
                }
                let name = "\(def.brand) \(def.name)".trimmingCharacters(in: .whitespaces)
                let colour = def.colorName.isEmpty ? "#\(def.colorHex)" : def.colorName
                catalogSection.addArrangedSubview(row(
                    dot: NSColor(filamentHex: def.colorHex),
                    title: name.isEmpty ? def.type : name,
                    subtitle: "\(def.type) · \(colour)",
                    highlight: matchesDef(def)) { [weak self] in self?.showPickGrams(def: def) })
            }
        }

        // Two columns, not one long strip. Stacked in one column the slot, its roll, every spare roll,
        // the create button and the whole catalog made a window more than twice as tall as it was
        // wide. The left column is about what is in this slot, the right one about making a new roll,
        // and each scrolls its own list.
        [assignedSection, rollsSection, catalogSection].forEach(stretchChildren)
        present(columns: [
            (blocks: [header, assignedSection, divider(), rollsSection], scrollFrom: 3),
            (blocks: [newRoll, catalogSection], scrollFrom: 1)
        ])
    }

    /// Weigh screen (spec §5): set a fresh net reading, or enter gross + the empty-spool tare and let the
    /// app subtract it. The tare is remembered on the roll for next time.
    private func showCorrectWeight(_ spool: PhysicalSpool) {
        let header = pageHeader(title: t("Correct weight"),
                                subtitle: "\(spool.id) · \(t("nominal")) \(Int(spool.nominalWeightGrams)) g",
                                back: { [weak self] in self?.showMain() })

        let netField = NSTextField(string: String(Int(spool.remainingWeightGrams)))
        let grossField = NSTextField(string: "")
        let tareField = NSTextField(string: spool.tareGrams.map { String(Int($0)) } ?? "")
        let priceField = NSTextField(string: spool.price.map { String(format: "%g", $0) } ?? "")
        priceField.placeholderString = PrintCostSettings.current.currency

        let hint = note(t("Enter the net weight, or gross plus the empty-spool tare (the app subtracts it)."))
        let save = pill(t("Save"), filled: true) { [weak self] in
            guard let self else { return }
            func num(_ f: NSTextField) -> Double? { Double(f.stringValue.replacingOccurrences(of: ",", with: ".")) }
            let tare = num(tareField)
            let net: Double?
            if let gross = num(grossField), let tare { net = max(0, gross - tare) } else { net = num(netField) }
            guard let net else { return }
            let priceText = priceField.stringValue.trimmingCharacters(in: .whitespaces)
            let price = priceText.isEmpty ? nil : num(priceField).flatMap { $0 >= 0 ? $0 : nil }
            if priceText.isEmpty || price != nil, price != spool.price { self.spools.setPrice(id: spool.id, price: price) }
            self.spools.correctWeight(id: spool.id, netGrams: net, tare: tareField.stringValue.isEmpty ? nil : tare)
            self.onChange(); self.showMain()
        }

        present([header,
                 labeledField(t("Net (g)"), netField),
                 divider(),
                 labeledField(t("Gross (g)"), grossField),
                 labeledField(t("Spool tare (g)"), tareField),
                 divider(),
                 labeledField(t("Roll price ({0})", PrintCostSettings.current.currency), priceField),
                 hint, save], scrollFrom: nil)
    }

    /// Reset a spent roll back to full (spec §6): the same physical roll, refilled — e.g. you swapped in a
    /// fresh spool of the same product. Clears this roll's consumption history.
    private func confirmReset(_ spool: PhysicalSpool) {
        let alert = NSAlert()
        alert.messageText = t("Reset roll {0}?", spool.id)
        alert.informativeText = t("Sets a full {0} g (a fresh roll of the same product). This roll's usage history is cleared.", Int(spool.nominalWeightGrams))
        alert.addButton(withTitle: t("Reset"))
        alert.addButton(withTitle: t("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        spools.resetToFull(id: spool.id)
        onChange(); showMain()
    }

    /// Step 1 of "new roll": pick a filament from the Spoolbase catalog (matching AMS first).
    private func showPickFilament() {
        let header = pageHeader(title: t("New roll"),
                                subtitle: t("Pick a filament"),
                                back: { [weak self] in self?.showMain() })

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6

        if let mat = amsMaterial {
            list.addArrangedSubview(row(dot: amsColorHex.map { NSColor(filamentHex: $0) },
                                        title: t("New definition from AMS"),
                                        subtitle: mat, highlight: true) { [weak self] in
                guard let self else { return }
                self.showPickGrams(def: self.ensureDefinition())
            })
        }
        let defs = filaments.filaments.sorted { a, b in
            let am = matchesDef(a), bm = matchesDef(b)
            return am != bm ? am : "\(a.brand)\(a.name)" < "\(b.brand)\(b.name)"
        }
        for def in defs {
            let name = "\(def.brand) \(def.name)".trimmingCharacters(in: .whitespaces)
            list.addArrangedSubview(row(dot: NSColor(filamentHex: def.colorHex),
                                        title: name.isEmpty ? def.type : name,
                                        subtitle: "\(def.type) · \(def.colorName.isEmpty ? "#\(def.colorHex)" : def.colorName)",
                                        highlight: matchesDef(def)) { [weak self] in self?.showPickGrams(def: def) })
        }
        if defs.isEmpty && amsMaterial == nil {
            list.addArrangedSubview(note(t("No filaments in Spoolbase yet. Add them in the Spoolbase window.")))
        }
        present([header, list], scrollFrom: 1)
    }

    /// Step 2 of "new roll": choose the starting amount, then create + assign.
    private func showPickGrams(def: Filament) {
        let header = pageHeader(title: t("Starting amount"),
                                subtitle: "\(def.brand) \(def.name) · \(def.type)".trimmingCharacters(in: .whitespaces),
                                back: { [weak self] in self?.showPickFilament() })

        let priceField = NSTextField(string: spools.lastPrice(definitionID: def.id).map { String(format: "%g", $0) } ?? "")
        priceField.placeholderString = PrintCostSettings.current.currency
        func price() -> Double? {
            Double(priceField.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
                .flatMap { $0 >= 0 ? $0 : nil }
        }
        func preset(_ g: Double) -> NSView { pill("\(Int(g)) g", filled: false) { [weak self] in self?.createAndAssign(def: def, grams: g, price: price()) } }
        let presets = NSStackView(views: [preset(1000), preset(750), preset(500)])
        presets.orientation = .horizontal
        presets.spacing = 6

        let field = NSTextField(string: "")
        field.placeholderString = t("Other (g)")
        field.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let create = pill(t("Create"), filled: true) { [weak self] in
            guard let self, let g = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")), g > 0 else { return }
            self.createAndAssign(def: def, grams: g, price: price())
        }
        let customRow = NSStackView(views: [field, create])
        customRow.orientation = .horizontal
        customRow.spacing = 6

        present([header, labeledField(t("Roll price ({0})", PrintCostSettings.current.currency), priceField),
                 presets, customRow], scrollFrom: nil)
    }

    // MARK: Actions

    private func assign(_ spool: PhysicalSpool) {
        if !spool.location.isStorage, !spool.location.sameSlot(as: location) {
            let alert = NSAlert()
            alert.messageText = t("Spool {0} is elsewhere", spool.id)
            alert.informativeText = t("Move it here? Its previous slot is freed.")
            alert.addButton(withTitle: t("Move here"))
            alert.addButton(withTitle: t("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        spools.assign(spoolID: spool.id, to: location)
        onChange(); onClose?()
    }

    private func createAndAssign(def: Filament, grams: Double, price: Double? = nil) {
        let spool = PhysicalSpool(id: spools.nextSpoolID(), filamentDefinitionID: def.id,
                                  nominalWeightGrams: grams, remainingWeightGrams: grams,
                                  status: .active, location: location, price: price)
        spools.add(spool)
        onChange(); onClose?()
    }

    static func money(_ value: Double) -> String {
        String(format: "%.2f %@", value, PrintCostSettings.current.currency)
    }

    private func ensureDefinition() -> Filament {
        if let existing = filaments.filaments.first(where: { matchesDef($0) }) { return existing }
        let material = amsMaterial ?? "PLA"
        let def = Filament(brand: "", name: material, type: material,
                           colorName: "", colorHex: amsColorHex ?? "8E8E93")
        filaments.add(def)
        return filaments.filaments.first { $0.id == def.id } ?? def
    }

    private func matchesDef(_ def: Filament) -> Bool {
        guard amsMaterial != nil else { return false }
        let materialOK = def.type.caseInsensitiveCompare(amsMaterial!) == .orderedSame
        let colorOK = amsColorHex == nil || Filament.normalizedHex(def.colorHex) == Filament.normalizedHex(amsColorHex!)
        return materialOK && colorOK
    }

    private func matchesSpool(_ spool: PhysicalSpool) -> Bool {
        filaments.filaments.first { $0.id == spool.filamentDefinitionID }.map(matchesDef) ?? false
    }

    // MARK: Layout + styled components

    /// Pin every arranged subview of a vertical stack to the stack's width, so rows/pills/dividers fill
    /// the panel instead of keeping a fixed width that could overflow a narrow popover.
    private func stretchChildren(_ stack: NSStackView) {
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// Width of a single-column screen (weigh, pick a filament, starting amount). Kept narrow in a
    /// wide window, so a weigh form does not stretch its fields and pills across it.
    static let singleColumnWidth: CGFloat = 440
    /// Gap between the main screen's two columns.
    static let columnGap: CGFloat = 20

    /// Lays out a one-column screen, centred.
    private func present(_ blocks: [NSView], scrollFrom: Int?) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let column = makeColumn(blocks, scrollFrom: scrollFrom)
        view.addSubview(column)
        let fill = column.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.singleColumnWidth),
            fill,
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
    }

    /// Lays out the main screen: equal columns side by side, each scrolling its own list.
    private func present(columns: [(blocks: [NSView], scrollFrom: Int?)]) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = Self.columnGap
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
        for spec in columns {
            let column = makeColumn(spec.blocks, scrollFrom: spec.scrollFrom)
            row.addArrangedSubview(column)
            column.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        }
    }

    /// One column: fixed rows on top, then (optionally) the row at `scrollFrom` becomes a scrolling
    /// list that fills the remaining height.
    private func makeColumn(_ blocks: [NSView], scrollFrom: Int?) -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false

        var scroll: NSScrollView?
        for (index, block) in blocks.enumerated() {
            if index == scrollFrom {
                let s = NSScrollView()
                s.drawsBackground = false
                s.hasVerticalScroller = true
                // Overlay scrollers so the bar floats over the margin and never eats row width; even so
                // we reserve a small lane below so a legacy (always-on) scrollbar can't clip the rows'
                // right edge (the delete button).
                s.scrollerStyle = .overlay
                s.autohidesScrollers = true
                s.verticalScrollElasticity = .allowed
                s.verticalScroller = SlimScroller()
                s.verticalScroller?.knobStyle = .dark
                // A flipped document view keeps the list pinned to the TOP of the scroll area;
                // a plain NSView would bottom-align it and leave a large empty gap above the rows.
                let doc = FlippedView()
                doc.translatesAutoresizingMaskIntoConstraints = false
                block.translatesAutoresizingMaskIntoConstraints = false
                doc.addSubview(block)
                NSLayoutConstraint.activate([
                    block.topAnchor.constraint(equalTo: doc.topAnchor),
                    block.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                    block.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                    block.bottomAnchor.constraint(equalTo: doc.bottomAnchor)
                ])
                s.documentView = doc
                s.translatesAutoresizingMaskIntoConstraints = false
                column.addArrangedSubview(s)
                // Leave a 14 pt lane on the right for the scrollbar so rows (and the delete button) are
                // never drawn under it.
                doc.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -14).isActive = true
                s.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
                // Prefer to be exactly as tall as the content, so a short list shows whole with no dead
                // space. A low-priority wish: on a short window this compresses and the list scrolls.
                let fit = s.heightAnchor.constraint(equalTo: doc.heightAnchor)
                fit.priority = .defaultLow
                fit.isActive = true
                scroll = s
            } else {
                column.addArrangedSubview(block)
                block.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }
        if let scroll {
            // Keep the list usable even on a short window, but let this break before it would clip.
            let minH = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
            minH.priority = .defaultHigh
            minH.isActive = true
        }
        return column
    }

    private func pageHeader(title: String, subtitle: String, back: (() -> Void)?) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        if let back {
            stack.addArrangedSubview(linkLabel(t("‹ Back"), action: back))
        }
        let t0 = NSTextField(labelWithString: title)
        t0.font = .systemFont(ofSize: 14, weight: .bold)
        t0.textColor = GantryTheme.text
        let s0 = NSTextField(labelWithString: subtitle)
        s0.font = .systemFont(ofSize: 11)
        s0.textColor = GantryTheme.secondary
        stack.addArrangedSubview(t0)
        stack.addArrangedSubview(s0)
        return stack
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = GantryTheme.muted
        return label
    }

    /// A quiet caption that heads each material group in the catalog list (PLA, PETG, …).
    private func typeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 8, weight: .bold)
        label.textColor = GantryTheme.secondary
        return label
    }

    /// A caption + input row used by the weigh screen.
    private func labeledField(_ title: String, _ field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = GantryTheme.secondary
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let stack = NSStackView(views: [label, field, NSView()])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = GantryTheme.muted
        return label
    }

    private func divider() -> NSView {
        let line = ActionView()
        line.wantsLayer = true
        line.layer?.backgroundColor = GantryTheme.line.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func linkLabel(_ text: String, action: @escaping () -> Void) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = GantryTheme.secondary
        let host = ActionView()
        host.onClick = action
        host.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -1),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        return host
    }

    /// A pill button: filled (accent bg, dark text) for primary actions, outlined for secondary ones.
    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> NSView {
        let host = ActionView()
        host.onClick = action
        host.wantsLayer = true
        host.layer?.cornerRadius = 8
        host.layer?.backgroundColor = (filled ? GantryTheme.accent : GantryTheme.surface).cgColor
        host.layer?.borderWidth = filled ? 0 : 1
        host.layer?.borderColor = GantryTheme.line.cgColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = filled ? NSColor(hex: 0x151719) : GantryTheme.text
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            host.heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -12)
        ])
        return host
    }

    /// A tappable list row: optional colour dot, a title and a quiet subtitle, styled as a card.
    private func row(dot: NSColor?, title: String, subtitle: String, trailing: String? = nil,
                     highlight: Bool = false, onDelete: (() -> Void)? = nil, action: @escaping () -> Void) -> NSView {
        let host = ActionView()
        host.onClick = action
        host.wantsLayer = true
        host.layer?.cornerRadius = 8
        host.layer?.backgroundColor = GantryTheme.surface.cgColor
        host.layer?.borderWidth = highlight ? 1 : 0
        host.layer?.borderColor = GantryTheme.humidity.withAlphaComponent(0.5).cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = GantryTheme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = .systemFont(ofSize: 10)
        subLabel.textColor = highlight ? GantryTheme.humidity : GantryTheme.secondary
        subLabel.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [titleLabel, subLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        var rowViews: [NSView] = []
        if let dot {
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 5
            swatch.layer?.backgroundColor = dot.cgColor
            swatch.layer?.borderWidth = 1
            swatch.layer?.borderColor = GantryTheme.line.cgColor
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 12).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 12).isActive = true
            rowViews.append(swatch)
        }
        rowViews.append(text)
        rowViews.append(NSView())
        if let trailing {
            // Decorative hint; the whole row is the click target (its `action` runs the trailing intent).
            let tl = NSTextField(labelWithString: trailing)
            tl.font = .systemFont(ofSize: 11, weight: .medium)
            tl.textColor = GantryTheme.statusPrinting
            rowViews.append(tl)
        }
        if let onDelete {
            // A separate trash target so deleting a stray roll never triggers the row's assign action.
            let del = ActionView()
            del.onClick = onDelete
            del.toolTip = t("Delete roll")
            let icon = NSImageView(image: NSImage(systemSymbolName: "trash", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = GantryTheme.secondary
            icon.translatesAutoresizingMaskIntoConstraints = false
            del.addSubview(icon)
            del.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                del.widthAnchor.constraint(equalToConstant: 22),
                del.heightAnchor.constraint(equalToConstant: 22),
                icon.centerXAnchor.constraint(equalTo: del.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: del.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 13),
                icon.heightAnchor.constraint(equalToConstant: 13)
            ])
            rowViews.append(del)
        }
        let hstack = NSStackView(views: rowViews)
        hstack.orientation = .horizontal
        hstack.alignment = .centerY
        hstack.spacing = 8
        hstack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(hstack)
        NSLayoutConstraint.activate([
            hstack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 10),
            hstack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            hstack.topAnchor.constraint(equalTo: host.topAnchor, constant: 7),
            hstack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -7)
        ])
        return host
    }
}

/// A view whose whole area is one click target (used for pills, rows and links). mouseDown is consumed
/// so a click here never leaks to the dimmed backdrop behind the panel.
private final class ActionView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override var acceptsFirstResponder: Bool { true }
}

/// Top-left origin so a scroll view's content grows downward from the top instead of the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A slim, dark, rounded scrollbar that matches the panel instead of the chunky system default. Works as
/// an overlay scroller and, when the user forces always-on scrollbars, still draws thin with no track.
private final class SlimScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 9 }

    override func drawKnobSlot(in slot: NSRect, highlight flag: Bool) {
        // No visible track — keep it clean; the knob alone signals scroll position.
    }

    override func drawKnob() {
        let frame = rect(for: .knob).insetBy(dx: 3, dy: 2)
        guard frame.width > 0, frame.height > 0 else { return }
        let radius = frame.width / 2
        let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.28).setFill()
        path.fill()
    }
}
