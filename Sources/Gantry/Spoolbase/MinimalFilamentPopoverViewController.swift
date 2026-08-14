import AppKit

private let minimalTilePasteboardType = NSPasteboard.PasteboardType("pl.spoolbase.minimal-tile")

@MainActor
final class MinimalFilamentPopoverViewController: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
    private let store: FilamentStore
    private let onClose: () -> Void
    private let onAuxiliaryState: (Bool) -> Void
    private let searchField = NSTextField()
    private let filterButton = NSButton()
    private let chipsStack = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "Brak filamentów dla wybranych filtrów")
    private var chipsHeight: NSLayoutConstraint?
    private var selectedType: String?
    private var selectedBrand: String?
    private var lowStockOnly = false
    private var filterPanel: NSVisualEffectView?
    private var quickStockPopover: NSPopover?
    private var editorController: FilamentEditorWindowController?
    private var catalogController: CatalogPickerWindowController?
    private var auxiliaryCloseObserver: NSObjectProtocol?
    private var tileViews: [UUID: MinimalFilamentTileView] = [:]
    private var renderedFilaments: [Filament] = []

    init(store: FilamentStore, onClose: @escaping () -> Void, onAuxiliaryState: @escaping (Bool) -> Void) {
        self.store = store
        self.onClose = onClose
        self.onAuxiliaryState = onAuxiliaryState
        super.init(nibName: nil, bundle: nil)
        store.onChange = { [weak self] in self?.reload() }
        preferredContentSize = NSSize(width: 500, height: 560)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 500, height: 560))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        view = background

        let icon = NSImageView(image: FilamentIcon.image(size: 28))
        let title = NSTextField(labelWithString: "Spoolbase")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .systemFont(ofSize: 10.5)
        let titles = NSStackView(views: [title, summaryLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 0
        let identity = NSStackView(views: [icon, titles])
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 9
        let add = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Dodaj filament")!,
            target: self,
            action: #selector(addPressed)
        )
        add.bezelStyle = .circular
        add.controlSize = .regular
        add.toolTip = "Dodaj filament"
        let header = NSStackView(views: [identity, NSView(), add])
        header.orientation = .horizontal
        header.alignment = .centerY

        let searchSurface = makeSurface()
        let searchIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Szukaj")!)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchField.placeholderString = "Szukaj nazwy, koloru lub kodu…"
        searchField.delegate = self
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 11.5)
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchSurface.addSubview(searchIcon)
        searchSurface.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 11),
            searchIcon.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 15),
            searchIcon.heightAnchor.constraint(equalToConstant: 15),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 7),
            searchField.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor, constant: -9),
            searchField.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor, constant: 4),
            searchField.heightAnchor.constraint(equalToConstant: 22)
        ])

        filterButton.title = "Filtry"
        filterButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .medium))
        filterButton.imagePosition = .imageLeading
        filterButton.imageHugsTitle = true
        filterButton.imageScaling = .scaleProportionallyDown
        filterButton.alignment = .center
        filterButton.isBordered = false
        filterButton.font = .systemFont(ofSize: 11, weight: .medium)
        filterButton.contentTintColor = .secondaryLabelColor
        filterButton.wantsLayer = true
        filterButton.layer?.cornerRadius = 10
        filterButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        filterButton.layer?.borderWidth = 0.5
        filterButton.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
        filterButton.target = self
        filterButton.action = #selector(toggleFilters)
        let toolbar = NSStackView(views: [searchSurface, filterButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        filterButton.widthAnchor.constraint(equalToConstant: 86).isActive = true
        filterButton.heightAnchor.constraint(equalToConstant: 38).isActive = true

        chipsStack.orientation = .horizontal
        chipsStack.alignment = .centerY
        chipsStack.spacing = 6

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let document = MinimalFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        emptyLabel.isHidden = true
        [header, toolbar, chipsStack, scroll, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        chipsHeight = chipsStack.heightAnchor.constraint(equalToConstant: 0)
        chipsHeight?.isActive = true
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            header.heightAnchor.constraint(equalToConstant: 38),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 11),
            toolbar.heightAnchor.constraint(equalToConstant: 38),
            chipsStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            chipsStack.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.trailingAnchor),
            chipsStack.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: chipsStack.bottomAnchor, constant: 5),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        reload()
    }

    func controlTextDidChange(_ obj: Notification) {
        dismissFilters()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applySearch), object: nil)
        perform(#selector(applySearch), with: nil, afterDelay: 0.07)
    }

    func refreshStockColors() {
        for item in store.filaments { tileViews[item.id]?.update(item) }
    }

    @objc private func applySearch() { renderList() }

    private func makeSurface() -> NSView {
        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 10
        surface.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        surface.layer?.borderWidth = 0.5
        surface.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        return surface
    }

    private func reload() {
        guard isViewLoaded else { return }
        if canUpdateExistingTiles() {
            updateSummary()
            for item in store.filaments { tileViews[item.id]?.update(item) }
            renderedFilaments = store.filaments
            if lowStockOnly { renderList() }
            return
        }
        if let selectedType, !store.filaments.contains(where: { $0.type == selectedType }) { self.selectedType = nil }
        if let selectedBrand, !store.filaments.contains(where: { $0.brand == selectedBrand }) { self.selectedBrand = nil }
        renderChips()
        renderList()
    }

    private func canUpdateExistingTiles() -> Bool {
        guard renderedFilaments.count == store.filaments.count,
              renderedFilaments.map(\.id) == store.filaments.map(\.id) else { return false }
        return zip(renderedFilaments, store.filaments).allSatisfy { old, new in
            old.id == new.id && old.catalogID == new.catalogID && old.brand == new.brand
                && old.name == new.name && old.type == new.type && old.colorName == new.colorName
                && old.colorHex == new.colorHex && old.manufacturerCode == new.manufacturerCode
                && old.notes == new.notes
        }
    }

    private func filteredFilaments() -> [Filament] {
        let query = searchField.stringValue.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return store.filaments.filter { item in
            if let selectedType, item.type != selectedType { return false }
            if let selectedBrand, item.brand != selectedBrand { return false }
            if lowStockOnly, item.spoolCount > StockLevelSettings.redMaximum { return false }
            if !query.isEmpty {
                let text = [item.brand, item.name, item.type, item.colorName, item.colorHex, item.manufacturerCode]
                    .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if !text.contains(query) { return false }
            }
            return true
        }
    }

    private func renderList() {
        let items = filteredFilaments()
        tileViews.removeAll(keepingCapacity: true)
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let grouped = Dictionary(grouping: items, by: \.type)
        let orderedTypes = FilamentCatalog.types.filter { grouped[$0] != nil }
            + grouped.keys.filter { !FilamentCatalog.types.contains($0) }.sorted()
        for (index, type) in orderedTypes.enumerated() {
            let section = MinimalFilamentSectionView(
                type: type,
                filaments: grouped[type] ?? [],
                drawsSeparator: index > 0,
                onQuick: { [weak self] item, anchor in self?.presentQuickStock(item, from: anchor) },
                onEdit: { [weak self] item in self?.presentEditor(item) },
                onDelete: { [weak self] item in self?.confirmDelete(item) },
                onMove: { [weak self] source, target in self?.store.move(id: source, before: target) },
                onTileCreated: { [weak self] tile in self?.tileViews[tile.filamentID] = tile }
            )
            listStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
        emptyLabel.isHidden = !items.isEmpty
        renderedFilaments = store.filaments
        updateSummary()
        DispatchQueue.main.async { [weak self] in self?.fitPopoverToContent() }
    }

    private func updateSummary() {
        let spools = store.filaments.reduce(0) { $0 + $1.spoolCount }
        let variants = store.filaments.count
        let variantWord: String
        if variants == 1 { variantWord = "wariant" }
        else if variants % 10 >= 2 && variants % 10 <= 4 && !(variants % 100 >= 12 && variants % 100 <= 14) {
            variantWord = "warianty"
        } else { variantWord = "wariantów" }
        summaryLabel.stringValue = "\(spools) szpul · \(variants) \(variantWord)"
    }

    private func fitPopoverToContent() {
        view.layoutSubtreeIfNeeded()
        let screenHeight = view.window?.screen?.visibleFrame.height ?? 900
        let chrome: CGFloat = chipsStack.arrangedSubviews.isEmpty ? 125 : 154
        let target = min(screenHeight * 0.75, max(300, chrome + listStack.fittingSize.height))
        preferredContentSize = NSSize(width: 500, height: target)
    }

    private func renderChips() {
        chipsStack.arrangedSubviews.forEach {
            chipsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if let selectedType { chipsStack.addArrangedSubview(chip(selectedType, id: "type")) }
        if let selectedBrand { chipsStack.addArrangedSubview(chip(selectedBrand, id: "brand")) }
        if lowStockOnly { chipsStack.addArrangedSubview(chip("Niski stan", id: "low")) }
        chipsHeight?.constant = chipsStack.arrangedSubviews.isEmpty ? 0 : 28
    }

    private func chip(_ title: String, id: String) -> NSButton {
        let button = NSButton(title: "\(title)  ×", target: self, action: #selector(clearChip(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.isBordered = false
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.contentTintColor = .controlAccentColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    @objc private func clearChip(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "type": selectedType = nil
        case "brand": selectedBrand = nil
        case "low": lowStockOnly = false
        default: break
        }
        renderChips()
        renderList()
    }

    @objc private func toggleFilters() {
        if filterPanel != nil {
            dismissFilters()
            return
        }
        let panel = NSVisualEffectView()
        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 13
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.3
        panel.layer?.shadowRadius = 16
        panel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 13, left: 10, bottom: 11, right: 10)
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
        let types = availableTypes()
        let brands = Array(Set(store.filaments.map(\.brand))).sorted()
        addFilterGroup(title: "Typ", values: types, selected: selectedType, prefix: "type", to: stack)
        addFilterSeparator(to: stack)
        let low = filterOption(title: "Niski stan", selected: lowStockOnly, id: "low:1")
        stack.addArrangedSubview(low)
        low.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        addFilterSeparator(to: stack)
        addFilterGroup(title: "Marka", values: brands, selected: selectedBrand, prefix: "brand", to: stack)
        view.addSubview(panel)
        stack.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height)
        NSLayoutConstraint.activate([
            panel.trailingAnchor.constraint(equalTo: filterButton.trailingAnchor),
            panel.topAnchor.constraint(equalTo: filterButton.bottomAnchor, constant: 7),
            panel.widthAnchor.constraint(equalToConstant: 235),
            panel.heightAnchor.constraint(equalToConstant: height)
        ])
        filterPanel = panel
    }

    private func availableTypes() -> [String] {
        let actual = Set(store.filaments.map(\.type))
        return FilamentCatalog.types.filter(actual.contains) + actual.filter { !FilamentCatalog.types.contains($0) }.sorted()
    }

    private func addFilterGroup(title: String, values: [String], selected: String?, prefix: String, to stack: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.heightAnchor.constraint(equalToConstant: 15).isActive = true
        stack.addArrangedSubview(label)
        for value in values {
            let button = filterOption(title: value, selected: value == selected, id: "\(prefix):\(value)")
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
    }

    private func filterOption(title: String, selected: Bool, id: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(filterOptionPressed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        button.image = selected
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            : NSImage(size: NSSize(width: 12, height: 12))
        button.imagePosition = .imageLeading
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = selected ? NSColor.white.withAlphaComponent(0.09).cgColor : NSColor.clear.cgColor
        button.heightAnchor.constraint(equalToConstant: 27).isActive = true
        return button
    }

    private func addFilterSeparator(to stack: NSStackView) {
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
    }

    @objc private func filterOptionPressed(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "").split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "type": selectedType = selectedType == parts[1] ? nil : parts[1]
        case "brand": selectedBrand = selectedBrand == parts[1] ? nil : parts[1]
        case "low": lowStockOnly.toggle()
        default: break
        }
        dismissFilters()
        renderChips()
        renderList()
    }

    private func dismissFilters() {
        filterPanel?.removeFromSuperview()
        filterPanel = nil
    }

    private func presentQuickStock(_ filament: Filament, from anchor: NSView) {
        quickStockPopover?.performClose(nil)
        let controller = QuickStockViewController(filament: filament)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        quickStockPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              popover === quickStockPopover,
              let controller = popover.contentViewController as? QuickStockViewController else { return }
        let delta = controller.currentValue - controller.initialValue
        quickStockPopover = nil
        if delta != 0 { store.adjust(id: controller.filamentID, spools: delta) }
    }

    @objc private func addPressed() {
        dismissFilters()
        let controller = CatalogPickerWindowController(
            catalog: CatalogFile.filaments,
            existingCatalogIDs: Set(store.filaments.compactMap(\.catalogID))
        ) { [weak self] item, quantity in
            self?.store.add(item.inventoryItem(spoolCount: quantity))
        }
        catalogController = controller
        showFloating(controller)
    }

    private func confirmDelete(_ filament: Filament) {
        guard let parent = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Usunąć z moich filamentów?"
        alert.informativeText = "\(filament.brand) • \(filament.name) • \(filament.colorName)\nProdukt pozostanie dostępny w katalogu."
        alert.addButton(withTitle: "Usuń")
        alert.addButton(withTitle: "Anuluj")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: parent) { [weak self] result in
            if result == .alertFirstButtonReturn { self?.store.delete(id: filament.id) }
        }
    }

    private func presentEditor(_ filament: Filament) {
        let editor = FilamentEditorWindowController(filament: filament) { [weak self] saved in
            guard let self else { return }
            var updated = saved
            var catalog = CatalogFile.filaments
            let catalogID = updated.catalogID ?? "custom-\(UUID().uuidString.lowercased())"
            updated.catalogID = catalogID
            let catalogItem = CatalogFilament(
                id: catalogID,
                brand: updated.brand,
                name: updated.name,
                type: updated.type,
                colorName: updated.colorName,
                colorHex: updated.colorHex,
                manufacturerCode: updated.manufacturerCode
            )
            if let index = catalog.firstIndex(where: { $0.id == catalogID }) { catalog[index] = catalogItem }
            else { catalog.append(catalogItem) }
            try? CatalogFile.save(catalog)
            self.store.update(updated)
        }
        editorController = editor
        showFloating(editor)
    }

    private func showFloating(_ controller: NSWindowController) {
        guard let window = controller.window else { return }
        if let auxiliaryCloseObserver { NotificationCenter.default.removeObserver(auxiliaryCloseObserver) }
        onAuxiliaryState(true)
        auxiliaryCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onAuxiliaryState(false)
                self?.auxiliaryCloseObserver = nil
            }
        }
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class MinimalFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class MinimalFilamentSectionView: NSView {
    init(
        type: String,
        filaments: [Filament],
        drawsSeparator: Bool,
        onQuick: @escaping (Filament, NSView) -> Void,
        onEdit: @escaping (Filament) -> Void,
        onDelete: @escaping (Filament) -> Void,
        onMove: @escaping (UUID, UUID) -> Void,
        onTileCreated: (MinimalFilamentTileView) -> Void
    ) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: type)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let count = NSTextField(labelWithString: "\(filaments.count) \(filaments.count == 1 ? "filament" : "filamentów")")
        count.font = .systemFont(ofSize: 9.5, weight: .medium)
        count.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, NSView(), count])
        header.orientation = .horizontal
        header.alignment = .firstBaseline

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        for start in stride(from: 0, to: filaments.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = 5
            for offset in 0..<2 {
                let index = start + offset
                if index < filaments.count {
                    let tile = MinimalFilamentTileView(
                        filament: filaments[index],
                        onQuick: onQuick,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        onMove: onMove
                    )
                    row.addArrangedSubview(tile)
                    onTileCreated(tile)
                } else {
                    row.addArrangedSubview(NSView())
                }
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 58).isActive = true
        }
        let stack = NSStackView(views: [header, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let top = drawsSeparator ? 13.0 : 8.0
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: top),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        if drawsSeparator {
            let line = NSBox()
            line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
                line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
                line.topAnchor.constraint(equalTo: topAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class MinimalFilamentTileView: NSControl, NSDraggingSource {
    private var filament: Filament
    private let onQuick: (Filament, NSView) -> Void
    private let onEdit: (Filament) -> Void
    private let onDelete: (Filament) -> Void
    private let onMove: (UUID, UUID) -> Void
    private var didDrag = false
    private var tracking: NSTrackingArea?
    private let badge: MinimalStockBadge
    var filamentID: UUID { filament.id }

    init(
        filament: Filament,
        onQuick: @escaping (Filament, NSView) -> Void,
        onEdit: @escaping (Filament) -> Void,
        onDelete: @escaping (Filament) -> Void,
        onMove: @escaping (UUID, UUID) -> Void
    ) {
        self.filament = filament
        self.onQuick = onQuick
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onMove = onMove
        badge = MinimalStockBadge(count: filament.spoolCount)
        super.init(frame: .zero)
        registerForDraggedTypes([minimalTilePasteboardType])
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.clear.cgColor

        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 15
        swatch.layer?.borderWidth = 0.5
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.layer?.backgroundColor = NSColor(filamentHex: filament.colorHex).cgColor
        let color = NSTextField(labelWithString: filament.colorName)
        color.font = .systemFont(ofSize: 10.5, weight: .semibold)
        color.lineBreakMode = .byTruncatingTail
        let product = NSTextField(labelWithString: "\(filament.brand) · \(filament.name)")
        product.font = .systemFont(ofSize: 7.8)
        product.textColor = .secondaryLabelColor
        product.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [color, product])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let row = NSStackView(views: [swatch, labels, NSView(), badge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 30),
            swatch.heightAnchor.constraint(equalToConstant: 30),
            badge.widthAnchor.constraint(equalToConstant: 29),
            badge.heightAnchor.constraint(equalToConstant: 25),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        toolTip = "Kliknij, aby szybko zmienić stan"
    }

    func update(_ filament: Filament) {
        self.filament = filament
        badge.update(count: filament.spoolCount)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.32).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.14).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.32).cgColor
        guard !didDrag, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onQuick(filament, self)
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        let item = NSPasteboardItem()
        item.setString("\(filament.id.uuidString)|\(filament.type)", forType: minimalTilePasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(NSRect(x: bounds.midX - 18, y: bounds.midY - 18, width: 36, height: 36), contents: FilamentIcon.image(size: 30))
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let value = sender.draggingPasteboard.string(forType: minimalTilePasteboardType) else { return [] }
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] != filament.id.uuidString, parts[1] == filament.type else { return [] }
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { restoreBorder() }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { restoreBorder() }
        guard let value = sender.draggingPasteboard.string(forType: minimalTilePasteboardType) else { return false }
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1] == filament.type,
              let source = UUID(uuidString: parts[0]), source != filament.id else { return false }
        onMove(source, filament.id)
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    private func restoreBorder() {
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let stock = NSMenuItem(title: "Zmień liczbę szpul…", action: #selector(changeStock), keyEquivalent: "")
        stock.image = NSImage(systemSymbolName: "plusminus.circle", accessibilityDescription: nil)
        stock.target = self
        menu.addItem(stock)
        let edit = NSMenuItem(title: "Edytuj…", action: #selector(editItem), keyEquivalent: "")
        edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        edit.target = self
        menu.addItem(edit)
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Usuń z moich filamentów", action: #selector(deleteItem), keyEquivalent: "")
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        delete.target = self
        menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func changeStock() { onQuick(filament, self) }
    @objc private func editItem() { onEdit(filament) }
    @objc private func deleteItem() { onDelete(filament) }
}

private final class MinimalStockBadge: NSView {
    private let label = NSTextField(labelWithString: "")

    init(count: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5)
        ])
        update(count: count)
    }

    func update(count: Int) {
        let color: NSColor
        if count == 0 { color = .secondaryLabelColor }
        else if count <= StockLevelSettings.redMaximum { color = .systemRed }
        else if count <= StockLevelSettings.blueMaximum { color = .systemBlue }
        else { color = .systemGreen }
        layer?.backgroundColor = color.withAlphaComponent(count == 0 ? 0.10 : 0.17).cgColor
        label.stringValue = "\(count)"
        label.textColor = color
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class QuickStockViewController: NSViewController, NSTextFieldDelegate {
    let filamentID: UUID
    let initialValue: Int
    private(set) var currentValue: Int
    private let valueField = NSTextField()
    private let name: String

    init(filament: Filament) {
        filamentID = filament.id
        initialValue = filament.spoolCount
        currentValue = filament.spoolCount
        name = "\(filament.colorName) · \(filament.brand)"
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 190, height: 104)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 190, height: 104))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        view = background
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 10, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        let minus = stepButton(symbol: "minus", action: #selector(minusPressed))
        let plus = stepButton(symbol: "plus", action: #selector(plusPressed))
        valueField.integerValue = currentValue
        valueField.alignment = .center
        valueField.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        valueField.isBezeled = false
        valueField.drawsBackground = false
        valueField.delegate = self
        let stepper = NSStackView(views: [minus, valueField, plus])
        stepper.orientation = .horizontal
        stepper.alignment = .centerY
        stepper.distribution = .fillEqually
        stepper.spacing = 6
        let stack = NSStackView(views: [title, stepper])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -11),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -11),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepper.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepper.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        currentValue = max(0, valueField.integerValue)
    }

    @objc private func minusPressed() { setValue(currentValue - 1) }
    @objc private func plusPressed() { setValue(currentValue + 1) }

    private func setValue(_ value: Int) {
        currentValue = max(0, value)
        valueField.integerValue = currentValue
    }

    private func stepButton(symbol: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
}
