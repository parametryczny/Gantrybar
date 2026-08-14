import AppKit

@MainActor
final class CatalogPickerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var catalog: [CatalogFilament]
    private let existingCatalogIDs: Set<String>
    private let onAdd: (CatalogFilament, Int) -> Void
    private let searchField = NSSearchField()
    private let brandPopup = NSPopUpButton()
    private let typePopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let addButton = NSButton()
    private let editButton = NSButton()
    private let deleteButton = NSButton()
    private let quantityField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private var visible: [CatalogFilament] = []
    private var editorController: FilamentEditorWindowController?
    private var scannerController: BarcodeScannerWindowController?

    init(
        catalog: [CatalogFilament],
        existingCatalogIDs: Set<String>,
        onAdd: @escaping (CatalogFilament, Int) -> Void
    ) {
        self.catalog = catalog
        self.existingCatalogIDs = existingCatalogIDs
        self.onAdd = onAdd
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Spoolbase — baza filamentów"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 620, height: 450)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        applyFilters()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let symbol = NSImageView(image: FilamentIcon.image(size: 28))
        symbol.contentTintColor = .labelColor
        let title = NSTextField(labelWithString: "Baza filamentów")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Spoolbase • dodawaj, edytuj i usuwaj produkty")
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        let heading = NSStackView(views: [symbol, labels, NSView(), countLabel])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 9
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 10)

        searchField.placeholderString = "Szukaj marki, serii, koloru lub kodu…"
        searchField.controlSize = .small
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        rebuildFilterMenus()
        [brandPopup, typePopup].forEach {
            $0.controlSize = .small
            $0.target = self
            $0.action = #selector(filtersChanged)
            $0.widthAnchor.constraint(equalToConstant: 145).isActive = true
        }
        let scanButton = NSButton(title: "Skanuj kod…", target: self, action: #selector(scanBarcodePressed))
        scanButton.image = NSImage(systemSymbolName: "barcode.viewfinder", accessibilityDescription: "Skanuj kod")
        scanButton.imagePosition = .imageLeading
        scanButton.controlSize = .small
        scanButton.bezelStyle = .rounded
        scanButton.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let filters = NSStackView(views: [searchField, brandPopup, typePopup, scanButton])
        filters.orientation = .horizontal
        filters.spacing = 8

        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.doubleAction = #selector(editPressed)
        tableView.target = self
        addColumn("color", "", 42)
        addColumn("brand", "Marka", 100)
        addColumn("name", "Nazwa", 155)
        addColumn("type", "Typ", 65)
        addColumn("colorName", "Kolor", 125)
        addColumn("code", "Kod producenta", 125)
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let tableCard = NSVisualEffectView()
        tableCard.material = .contentBackground
        tableCard.blendingMode = .withinWindow
        tableCard.state = .active
        tableCard.wantsLayer = true
        tableCard.layer?.cornerRadius = 14
        tableCard.layer?.masksToBounds = true
        tableCard.translatesAutoresizingMaskIntoConstraints = false
        tableCard.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: tableCard.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: tableCard.trailingAnchor, constant: -5),
            scroll.topAnchor.constraint(equalTo: tableCard.topAnchor, constant: 7),
            scroll.bottomAnchor.constraint(equalTo: tableCard.bottomAnchor, constant: -7)
        ])

        let quantityTitle = NSTextField(labelWithString: "Liczba szpul")
        quantityTitle.textColor = .secondaryLabelColor
        quantityField.integerValue = 1
        quantityField.alignment = .center
        quantityField.formatter = integerFormatter()
        quantityField.widthAnchor.constraint(equalToConstant: 55).isActive = true
        let cancel = NSButton(title: "Anuluj", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let custom = NSButton(title: "Dodaj własny…", target: self, action: #selector(addCustomPressed))
        custom.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Dodaj własny filament")
        custom.imagePosition = .imageLeading
        custom.bezelStyle = .rounded
        editButton.title = "Edytuj…"
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edytuj")
        editButton.imagePosition = .imageLeading
        editButton.target = self
        editButton.action = #selector(editPressed)
        editButton.bezelStyle = .rounded
        deleteButton.title = "Usuń"
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Usuń")
        deleteButton.imagePosition = .imageLeading
        deleteButton.target = self
        deleteButton.action = #selector(deletePressed)
        deleteButton.bezelStyle = .rounded
        addButton.title = "Dodaj do moich"
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Dodaj")
        addButton.imagePosition = .imageLeading
        addButton.target = self
        addButton.action = #selector(addPressed)
        addButton.keyEquivalent = "\r"
        addButton.bezelStyle = .rounded
        [custom, editButton, deleteButton, cancel, addButton].forEach { $0.controlSize = .small }
        let footer = NSStackView(views: [custom, editButton, deleteButton, NSView(), quantityTitle, quantityField, cancel, addButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 9

        let stack = NSStackView(views: [heading, filters, tableCard, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        [heading, filters, tableCard, footer].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 42),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
            heading.heightAnchor.constraint(equalToConstant: 38),
            filters.heightAnchor.constraint(equalToConstant: 28),
            footer.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func addColumn(_ id: String, _ title: String, _ width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = max(35, width - 30)
        column.resizingMask = [.userResizingMask, .autoresizingMask]
        tableView.addTableColumn(column)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let item = visible[row]
        if id == "color" {
            let identifier = NSUserInterfaceItemIdentifier("CatalogColor")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? CatalogColorCell) ?? CatalogColorCell(identifier: identifier)
            cell.update(item.colorHex)
            return cell
        }
        let value: String
        switch id {
        case "brand": value = item.brand
        case "name": value = item.name
        case "type": value = item.type
        case "colorName": value = item.colorName
        case "code": value = item.manufacturerCode
        default: value = ""
        }
        let identifier = NSUserInterfaceItemIdentifier("CatalogText-\(id)")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeTextCell(identifier)
        cell.textField?.stringValue = value
        cell.textField?.textColor = existingCatalogIDs.contains(item.id) ? .tertiaryLabelColor : .labelColor
        cell.textField?.font = id == "code" ? .monospacedSystemFont(ofSize: 10, weight: .regular) : .systemFont(ofSize: 12)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateAddButton() }
    func controlTextDidChange(_ obj: Notification) { applyFilters() }

    private func makeTextCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func applyFilters() {
        let query = searchField.stringValue.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let brand = brandPopup.titleOfSelectedItem ?? "Wszystkie marki"
        let type = typePopup.titleOfSelectedItem ?? "Wszystkie typy"
        visible = catalog.filter { item in
            if brand != "Wszystkie marki", item.brand != brand { return false }
            if type != "Wszystkie typy", item.type != type { return false }
            if !query.isEmpty {
                let text = [item.brand, item.name, item.type, item.colorName, item.manufacturerCode]
                    .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return text.contains(query)
            }
            return true
        }.sorted {
            if $0.brand != $1.brand { return $0.brand.localizedCaseInsensitiveCompare($1.brand) == .orderedAscending }
            if $0.name != $1.name { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.colorName.localizedCaseInsensitiveCompare($1.colorName) == .orderedAscending
        }
        tableView.reloadData()
        countLabel.stringValue = "\(visible.count) pozycji"
        updateAddButton()
    }

    private var selected: CatalogFilament? {
        let row = tableView.selectedRow
        return row >= 0 && row < visible.count ? visible[row] : nil
    }

    private func updateAddButton() {
        addButton.isEnabled = selected != nil
        editButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected != nil
        if let selected, existingCatalogIDs.contains(selected.id) {
            addButton.title = "Dodaj kolejne szpule"
        } else {
            addButton.title = "Dodaj do moich"
        }
    }

    @objc private func filtersChanged() { applyFilters() }
    @objc private func scanBarcodePressed() {
        let scanner = BarcodeScannerWindowController { [weak self] code in
            self?.handleScannedCode(code)
        }
        scannerController = scanner
        guard let scannerWindow = scanner.window else { return }
        scannerWindow.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 3)
        scannerWindow.collectionBehavior.insert(.moveToActiveSpace)
        scannerWindow.center()
        scanner.showWindow(nil)
        scannerWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scanner.startScanning()
    }
    @objc private func cancelPressed() { closeSheet() }
    @objc private func addCustomPressed() {
        presentEditor(nil)
    }
    @objc private func editPressed() {
        guard let selected else { return }
        presentEditor(selected)
    }
    @objc private func deletePressed() {
        guard let selected else { return }
        let alert = NSAlert()
        alert.messageText = "Usunąć filament z bazy?"
        alert.informativeText = "\(selected.brand) • \(selected.name) • \(selected.colorName)\nFilament dodany wcześniej do Twoich stanów pozostanie bez zmian."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Usuń")
        alert.addButton(withTitle: "Anuluj")
        guard let window else { return }
        let selectedID = selected.id
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn, let self else { return }
            self.catalog.removeAll { $0.id == selectedID }
            self.persistCatalog()
        }
    }
    @objc private func addPressed() {
        guard let selected else { return }
        onAdd(selected, max(1, quantityField.integerValue))
        closeSheet()
    }

    private func closeSheet() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { close() }
    }

    private func presentEditor(_ item: CatalogFilament?, prefilledCode: String? = nil) {
        let inventory = item?.inventoryItem(spoolCount: 0)
        let editor = FilamentEditorWindowController(
            filament: inventory,
            catalogMode: true,
            prefilledManufacturerCode: prefilledCode
        ) { [weak self] saved in
            guard let self else { return }
            let catalogItem = CatalogFilament(
                id: item?.id ?? "custom-\(UUID().uuidString.lowercased())",
                brand: saved.brand,
                name: saved.name,
                type: saved.type,
                colorName: saved.colorName,
                colorHex: saved.colorHex,
                manufacturerCode: saved.manufacturerCode
            )
            if let index = self.catalog.firstIndex(where: { $0.id == catalogItem.id }) {
                self.catalog[index] = catalogItem
            } else {
                self.catalog.append(catalogItem)
            }
            self.persistCatalog(selecting: catalogItem.id)
        }
        editorController = editor
        guard let editorWindow = editor.window else { return }
        editorWindow.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        editorWindow.collectionBehavior.insert(.moveToActiveSpace)
        editorWindow.center()
        editor.showWindow(nil)
        editorWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func persistCatalog(selecting id: String? = nil) {
        do {
            try CatalogFile.save(catalog)
            rebuildFilterMenus()
            applyFilters()
            if let id, let row = visible.firstIndex(where: { $0.id == id }) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Nie udało się zapisać bazy"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    private func handleScannedCode(_ code: String) {
        let normalized = normalizeBarcode(code)
        if let match = catalog.first(where: { normalizeBarcode($0.manufacturerCode) == normalized }) {
            searchField.stringValue = match.manufacturerCode
            brandPopup.selectItem(withTitle: "Wszystkie marki")
            typePopup.selectItem(withTitle: "Wszystkie typy")
            applyFilters()
            if let row = visible.firstIndex(where: { $0.id == match.id }) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
            }
            NSSound.beep()
            return
        }
        searchField.stringValue = code
        applyFilters()
        let alert = NSAlert()
        alert.messageText = "Nie znaleziono kodu w bazie"
        alert.informativeText = "Odczytany kod: \(code)\nMożesz dodać ten filament jako własny i wpisać kod producenta."
        alert.addButton(withTitle: "Dodaj własny")
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window) { [weak self] result in
                if result == .alertFirstButtonReturn { self?.presentEditor(nil, prefilledCode: code) }
            }
        }
    }

    private func normalizeBarcode(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private func rebuildFilterMenus() {
        let selectedBrand = brandPopup.titleOfSelectedItem
        let selectedType = typePopup.titleOfSelectedItem
        brandPopup.removeAllItems()
        brandPopup.addItem(withTitle: "Wszystkie marki")
        brandPopup.addItems(withTitles: Set(catalog.map(\.brand)).sorted())
        typePopup.removeAllItems()
        typePopup.addItem(withTitle: "Wszystkie typy")
        let catalogTypes = Set(catalog.map(\.type))
        let knownTypes = FilamentCatalog.types
        let customTypes = catalogTypes.subtracting(knownTypes).sorted()
        typePopup.addItems(withTitles: knownTypes + customTypes)
        if let selectedBrand, brandPopup.itemTitles.contains(selectedBrand) { brandPopup.selectItem(withTitle: selectedBrand) }
        if let selectedType, typePopup.itemTitles.contains(selectedType) { typePopup.selectItem(withTitle: selectedType) }
    }

    private func integerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 100_000
        return formatter
    }
}

private final class CatalogColorCell: NSTableCellView {
    private let swatch = NSView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 11
        swatch.layer?.borderWidth = 0.5
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(swatch)
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 22),
            swatch.heightAnchor.constraint(equalToConstant: 22),
            swatch.centerXAnchor.constraint(equalTo: centerXAnchor),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
    func update(_ hex: String) { swatch.layer?.backgroundColor = NSColor(filamentHex: hex).cgColor }
}
