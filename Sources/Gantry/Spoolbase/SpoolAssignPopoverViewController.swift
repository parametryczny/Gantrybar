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
        showMain()
    }

    private func t(_ pl: String, _ en: String) -> String { AppSettings.shared.text(pl, en) }

    /// Names of saved printers, so a roll loaded elsewhere shows *where* right on its row (spec: see it
    /// at the filament, before selecting).
    private lazy var printerNames: [String: String] =
        Dictionary(PrinterPersistence().load().map { ($0.serial, $0.name) }, uniquingKeysWith: { first, _ in first })

    /// A short location for a roll: "magazyn", or "<printer> · A2" / "<printer> · EXT".
    private func placeLabel(_ loc: SpoolLocation) -> String {
        guard !loc.isStorage else { return t("magazyn", "storage") }
        let name = loc.printerSerial.flatMap { printerNames[$0] } ?? loc.printerSerial ?? t("drukarka", "printer")
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
        let header = pageHeader(title: slotTitle,
                                subtitle: t("AMS: \(amsMaterial ?? "nieznany")", "AMS: \(amsMaterial ?? "unknown")"),
                                back: nil)

        // 1. The roll currently in this slot + its per-roll actions. Weight and history live on the roll,
        // never on the slot, so unassigning only moves it to storage (its grams are kept).
        let assignedSection = NSStackView()
        assignedSection.orientation = .vertical
        assignedSection.alignment = .leading
        assignedSection.spacing = 6
        assignedSection.addArrangedSubview(sectionHeader(t("PRZYPISANA ROLKA", "ASSIGNED SPOOL")))
        if let assigned = spools.spool(at: location) {
            let def = filaments.filaments.first { $0.id == assigned.filamentDefinitionID }
            assignedSection.addArrangedSubview(row(
                dot: def.map { NSColor(filamentHex: $0.colorHex) },
                title: def.map { "\($0.brand) \($0.name)".trimmingCharacters(in: .whitespaces) } ?? assigned.id,
                subtitle: "\(assigned.id) · \(Int(assigned.remainingWeightGrams)) g · \(assigned.percent)%",
                action: {}))
            let actions = NSStackView(views: [
                pill(t("Skoryguj", "Weigh"), filled: false) { [weak self] in self?.showCorrectWeight(assigned) },
                pill(t("Zeruj", "Reset"), filled: false) { [weak self] in self?.confirmReset(assigned) },
                pill(t("Odepnij", "Unassign"), filled: false) { [weak self] in
                    guard let self else { return }
                    self.spools.assign(spoolID: assigned.id, to: .storage)
                    self.onChange(); self.showMain()
                }])
            actions.orientation = .horizontal
            actions.spacing = 6
            assignedSection.addArrangedSubview(actions)
        } else {
            let none = NSTextField(labelWithString: t("Brak", "None"))
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
        rollsSection.addArrangedSubview(sectionHeader(t("DOSTĘPNE ROLKI", "AVAILABLE ROLLS")))
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
            rollsSection.addArrangedSubview(note(t("Brak wolnych rolek. Utwórz nową poniżej.",
                                                   "No spare rolls. Create one below.")))
        } else {
            for spool in available {
                let def = filaments.filaments.first { $0.id == spool.filamentDefinitionID }
                let name = def.map { "\($0.brand) \($0.name)".trimmingCharacters(in: .whitespaces) } ?? spool.id
                rollsSection.addArrangedSubview(row(
                    dot: def.map { NSColor(filamentHex: $0.colorHex) },
                    title: name.isEmpty ? spool.id : name,
                    subtitle: "\(spool.id) · \(Int(spool.remainingWeightGrams)) g · \(placeLabel(spool.location))",
                    highlight: matchesSpool(spool),
                    onDelete: { [weak self] in
                        guard let self else { return }
                        self.spools.delete(id: spool.id); self.onChange(); self.showMain()
                    }) { [weak self] in self?.assign(spool) })
            }
        }

        // 3. Create a brand-new roll: a guided button, plus the whole catalog grouped by type so a
        // filament is easy to find. Picking a filament asks for the starting grams (spec §2).
        let newRoll = pill(t("+ Utwórz nową rolkę", "+ Create new roll"), filled: false) { [weak self] in
            self?.showPickFilament()
        }
        newRoll.widthAnchor.constraint(equalToConstant: 324).isActive = true

        let catalogSection = NSStackView()
        catalogSection.orientation = .vertical
        catalogSection.alignment = .leading
        catalogSection.spacing = 6
        catalogSection.addArrangedSubview(sectionHeader(t("FILAMENTY (NOWA ROLKA)", "FILAMENTS (NEW ROLL)")))
        let defs = filaments.filaments.sorted { a, b in
            if a.type != b.type { return a.type < b.type }
            let am = matchesDef(a), bm = matchesDef(b)
            if am != bm { return am }
            return "\(a.brand)\(a.name)" < "\(b.brand)\(b.name)"
        }
        if defs.isEmpty {
            catalogSection.addArrangedSubview(note(t("Magazyn pusty. Dodaj filamenty w oknie Spoolbase.",
                                                     "Empty. Add filaments in the Spoolbase window.")))
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

        // The rolls list, the create button and the catalog scroll together as one region.
        let body = NSStackView(views: [rollsSection, newRoll, catalogSection])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        present([header, assignedSection, divider(), body], scrollFrom: 3)
    }

    /// Weigh screen (spec §5): set a fresh net reading, or enter gross + the empty-spool tare and let the
    /// app subtract it. The tare is remembered on the roll for next time.
    private func showCorrectWeight(_ spool: PhysicalSpool) {
        let header = pageHeader(title: t("Skoryguj wagę", "Correct weight"),
                                subtitle: "\(spool.id) · \(t("nominał", "nominal")) \(Int(spool.nominalWeightGrams)) g",
                                back: { [weak self] in self?.showMain() })

        let netField = NSTextField(string: String(Int(spool.remainingWeightGrams)))
        let grossField = NSTextField(string: "")
        let tareField = NSTextField(string: spool.tareGrams.map { String(Int($0)) } ?? "")

        let hint = note(t("Wpisz wagę netto, albo brutto i tarę pustej szpuli (aplikacja odejmie tarę).",
                          "Enter the net weight, or gross plus the empty-spool tare (the app subtracts it)."))
        let save = pill(t("Zapisz", "Save"), filled: true) { [weak self] in
            guard let self else { return }
            func num(_ f: NSTextField) -> Double? { Double(f.stringValue.replacingOccurrences(of: ",", with: ".")) }
            let tare = num(tareField)
            let net: Double?
            if let gross = num(grossField), let tare { net = max(0, gross - tare) } else { net = num(netField) }
            guard let net else { return }
            self.spools.correctWeight(id: spool.id, netGrams: net, tare: tareField.stringValue.isEmpty ? nil : tare)
            self.onChange(); self.showMain()
        }
        save.widthAnchor.constraint(equalToConstant: 324).isActive = true

        present([header,
                 labeledField(t("Netto (g)", "Net (g)"), netField),
                 divider(),
                 labeledField(t("Brutto (g)", "Gross (g)"), grossField),
                 labeledField(t("Tara szpuli (g)", "Spool tare (g)"), tareField),
                 hint, save], scrollFrom: nil)
    }

    /// Reset a spent roll back to full (spec §6): the same physical roll, refilled — e.g. you swapped in a
    /// fresh spool of the same product. Clears this roll's consumption history.
    private func confirmReset(_ spool: PhysicalSpool) {
        let alert = NSAlert()
        alert.messageText = t("Wyzerować rolkę \(spool.id)?", "Reset roll \(spool.id)?")
        alert.informativeText = t(
            "Ustawia pełny stan \(Int(spool.nominalWeightGrams)) g (nowa rolka tego samego typu). Historia zużycia tej rolki zostanie wyczyszczona.",
            "Sets a full \(Int(spool.nominalWeightGrams)) g (a fresh roll of the same product). This roll's usage history is cleared.")
        alert.addButton(withTitle: t("Wyzeruj", "Reset"))
        alert.addButton(withTitle: t("Anuluj", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        spools.resetToFull(id: spool.id)
        onChange(); showMain()
    }

    /// Step 1 of "new roll": pick a filament from the Spoolbase catalog (matching AMS first).
    private func showPickFilament() {
        let header = pageHeader(title: t("Nowa rolka", "New roll"),
                                subtitle: t("Wybierz filament", "Pick a filament"),
                                back: { [weak self] in self?.showMain() })

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6

        if let mat = amsMaterial {
            list.addArrangedSubview(row(dot: amsColorHex.map { NSColor(filamentHex: $0) },
                                        title: t("Nowa definicja z AMS", "New definition from AMS"),
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
            list.addArrangedSubview(note(t("Brak filamentów w Spoolbase. Dodaj je w oknie Spoolbase.",
                                           "No filaments in Spoolbase yet. Add them in the Spoolbase window.")))
        }
        present([header, list], scrollFrom: 1)
    }

    /// Step 2 of "new roll": choose the starting amount, then create + assign.
    private func showPickGrams(def: Filament) {
        let header = pageHeader(title: t("Początkowa ilość", "Starting amount"),
                                subtitle: "\(def.brand) \(def.name) · \(def.type)".trimmingCharacters(in: .whitespaces),
                                back: { [weak self] in self?.showPickFilament() })

        func preset(_ g: Double) -> NSView { pill("\(Int(g)) g", filled: false) { [weak self] in self?.createAndAssign(def: def, grams: g) } }
        let presets = NSStackView(views: [preset(1000), preset(750), preset(500)])
        presets.orientation = .horizontal
        presets.spacing = 6

        let field = NSTextField(string: "")
        field.placeholderString = t("Inna (g)", "Other (g)")
        field.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let create = pill(t("Utwórz", "Create"), filled: true) { [weak self] in
            guard let self, let g = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")), g > 0 else { return }
            self.createAndAssign(def: def, grams: g)
        }
        let customRow = NSStackView(views: [field, create])
        customRow.orientation = .horizontal
        customRow.spacing = 6

        present([header, presets, customRow], scrollFrom: nil)
    }

    // MARK: Actions

    private func assign(_ spool: PhysicalSpool) {
        if !spool.location.isStorage, !spool.location.sameSlot(as: location) {
            let alert = NSAlert()
            alert.messageText = t("Rolka \(spool.id) jest w innym miejscu", "Spool \(spool.id) is elsewhere")
            alert.informativeText = t("Przenieść tutaj? Poprzedni slot zostanie zwolniony.",
                                      "Move it here? Its previous slot is freed.")
            alert.addButton(withTitle: t("Przenieś tutaj", "Move here"))
            alert.addButton(withTitle: t("Anuluj", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        spools.assign(spoolID: spool.id, to: location)
        onChange(); onClose?()
    }

    private func createAndAssign(def: Filament, grams: Double) {
        let spool = PhysicalSpool(id: spools.nextSpoolID(), filamentDefinitionID: def.id,
                                  nominalWeightGrams: grams, remainingWeightGrams: grams,
                                  status: .active, location: location)
        spools.add(spool)
        onChange(); onClose?()
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

    /// Lays out a screen: fixed rows on top, then (optionally) the row at `scrollFrom` becomes a
    /// scrolling list that fills the remaining height.
    private func present(_ blocks: [NSView], scrollFrom: Int?) {
        view.subviews.forEach { $0.removeFromSuperview() }
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
                doc.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
                s.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
                // Prefer to be exactly as tall as the content (so short lists show fully with no dead
                // space and no scrolling). This is a low-priority wish: when the window is short — e.g. a
                // single-printer popover — the panel's height cap wins, this compresses, and the list
                // scrolls instead of overflowing the window. See the height cap in the dashboard.
                let fit = s.heightAnchor.constraint(equalTo: doc.heightAnchor)
                fit.priority = .defaultLow
                fit.isActive = true
                scroll = s
            } else {
                column.addArrangedSubview(block)
                if block is NSStackView || block is NSTextField {
                    block.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
                }
            }
        }
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
        if let scroll {
            // Keep the list usable even on a short window, but let this break before the window cap does
            // (so it can shrink further rather than clip). Required min would fight the cap and clip.
            let minH = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
            minH.priority = .defaultHigh
            minH.isActive = true
        }
        addCloseButton()
    }

    /// A persistent close control in the top-right corner (the panel otherwise only closes after a
    /// choice is made). Re-added on every `present` since that clears the view's subviews.
    private func addCloseButton() {
        let host = ActionView()
        host.onClick = { [weak self] in self?.onClose?() }
        host.wantsLayer = true
        host.layer?.cornerRadius = 11
        host.layer?.backgroundColor = GantryTheme.surface.cgColor
        host.layer?.borderWidth = 1
        host.layer?.borderColor = GantryTheme.line.cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "✕")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = GantryTheme.secondary
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        host.toolTip = t("Zamknij", "Close")
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 22),
            host.heightAnchor.constraint(equalToConstant: 22),
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
    }

    private func pageHeader(title: String, subtitle: String, back: (() -> Void)?) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        if let back {
            stack.addArrangedSubview(linkLabel(t("‹ Wróć", "‹ Back"), action: back))
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
        line.widthAnchor.constraint(equalToConstant: 324).isActive = true
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
        host.widthAnchor.constraint(equalToConstant: 324).isActive = true

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
            del.toolTip = t("Usuń rolkę", "Delete roll")
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
