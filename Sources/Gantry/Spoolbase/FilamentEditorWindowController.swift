import AppKit

@MainActor
final class FilamentEditorWindowController: NSWindowController {
    private let original: Filament?
    private let catalogMode: Bool
    private let prefilledManufacturerCode: String?
    private let onSave: (Filament) -> Void
    private let brandField = NSComboBox()
    private let nameField = NSTextField()
    private let typeField = NSComboBox()
    private let colorNameField = NSTextField()
    private let colorWell = NSColorWell()
    private let hexField = NSTextField()
    private let codeField = NSTextField()
    private let spoolsField = NSTextField()
    private let notesField = NSTextField()

    init(
        filament: Filament?,
        catalogMode: Bool = false,
        prefilledManufacturerCode: String? = nil,
        onSave: @escaping (Filament) -> Void
    ) {
        original = filament
        self.catalogMode = catalogMode
        self.prefilledManufacturerCode = prefilledManufacturerCode
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: catalogMode ? 440 : 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = filament == nil ? "Dodaj do bazy" : "Edytuj w bazie"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        populate()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: original == nil ? AppSettings.shared.t("New filament") : AppSettings.shared.t("Filament details"))
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: catalogMode
            ? AppSettings.shared.t("Change the product details saved in the filament catalogue.")
            : AppSettings.shared.t("Fill in the catalogue details and the current stock."))
        subtitle.textColor = .secondaryLabelColor

        brandField.addItems(withObjectValues: FilamentCatalog.brands)
        typeField.addItems(withObjectValues: FilamentCatalog.types)
        [brandField, typeField].forEach { $0.completes = true }
        [nameField, colorNameField, hexField, codeField, spoolsField, notesField].forEach {
            $0.bezelStyle = .roundedBezel
        }
        hexField.placeholderString = AppSettings.shared.t("e.g. FF6A13")
        codeField.placeholderString = AppSettings.shared.t("SKU / EAN / manufacturer code")
        notesField.placeholderString = AppSettings.shared.t("Optional note")
        spoolsField.formatter = integerFormatter()
        colorWell.target = self
        colorWell.action = #selector(colorChanged)

        let colorRow = NSStackView(views: [colorWell, hexField])
        colorRow.orientation = .horizontal
        colorRow.spacing = 8
        colorWell.widthAnchor.constraint(equalToConstant: 54).isActive = true

        var rows: [[NSView]] = [
            [label(AppSettings.shared.t("Brand")), brandField],
            [label(AppSettings.shared.t("Name / series")), nameField],
            [label(AppSettings.shared.t("Material type")), typeField],
            [label(AppSettings.shared.t("Colour name")), colorNameField],
            [label(AppSettings.shared.t("Colour")), colorRow],
            [label(AppSettings.shared.t("Manufacturer code")), codeField]
        ]
        if !catalogMode {
            rows.append([label(AppSettings.shared.t("Number of spools")), spoolsField])
            rows.append([label(AppSettings.shared.t("Notes")), notesField])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 320

        let cancel = NSButton(title: AppSettings.shared.t("Cancel"), target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: AppSettings.shared.t("Save"), target: self, action: #selector(savePressed))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [title, subtitle, separator(), grid, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        ])
    }

    private func populate() {
        let item = original ?? Filament(brand: "Bambu Lab", name: "", type: "PLA", colorName: "", colorHex: "8E8E93")
        brandField.stringValue = item.brand
        nameField.stringValue = item.name
        typeField.stringValue = item.type
        colorNameField.stringValue = item.colorName
        hexField.stringValue = item.colorHex
        colorWell.color = NSColor(filamentHex: item.colorHex)
        codeField.stringValue = original?.manufacturerCode ?? prefilledManufacturerCode ?? item.manufacturerCode
        spoolsField.integerValue = item.spoolCount
        notesField.stringValue = item.notes
    }

    @objc private func colorChanged() {
        hexField.stringValue = colorWell.color.filamentHex
    }

    @objc private func cancelPressed() { closeSheet() }

    @objc private func savePressed() {
        let brand = brandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = typeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let colorName = colorNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brand.isEmpty, !name.isEmpty, !type.isEmpty, !colorName.isEmpty else {
            let alert = NSAlert()
            alert.messageText = AppSettings.shared.t("Required details are missing")
            alert.informativeText = AppSettings.shared.t("Enter the brand, name, type and colour name.")
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        var item = Filament(
            id: original?.id ?? UUID(),
            catalogID: original?.catalogID,
            brand: brand,
            name: name,
            type: type,
            colorName: colorName,
            colorHex: hexField.stringValue,
            manufacturerCode: codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            spoolCount: catalogMode ? (original?.spoolCount ?? 0) : spoolsField.integerValue,
            notes: notesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        item.updatedAt = .now
        onSave(item)
        closeSheet()
    }

    private func closeSheet() {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        else { close() }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func integerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 0
        formatter.maximum = 1_000_000
        return formatter
    }
}
