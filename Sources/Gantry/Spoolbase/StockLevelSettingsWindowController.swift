import AppKit

@MainActor
final class StockLevelSettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let redField = NSTextField()
    private let blueField = NSTextField()
    private let redDescription = NSTextField(labelWithString: "")
    private let blueDescription = NSTextField(labelWithString: "")
    private let greenDescription = NSTextField(labelWithString: "")
    private let onSave: () -> Void

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 310),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Limity stanów"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        redField.integerValue = StockLevelSettings.redMaximum
        blueField.integerValue = StockLevelSettings.blueMaximum
        updateDescriptions()
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

        let icon = NSImageView(image: NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)!)
        icon.contentTintColor = .labelColor
        icon.symbolConfiguration = .init(pointSize: 23, weight: .medium)
        let title = NSTextField(labelWithString: "Limity stanów")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Ustal, kiedy licznik zmienia kolor.")
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = .secondaryLabelColor
        let titleLabels = NSStackView(views: [title, subtitle])
        titleLabels.orientation = .vertical
        titleLabels.alignment = .leading
        titleLabels.spacing = 1
        let header = NSStackView(views: [icon, titleLabels])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        configureField(redField)
        configureField(blueField)
        let redRow = limitRow(color: .systemRed, title: "Czerwony", subtitle: "Maksymalnie", field: redField)
        let blueRow = limitRow(color: .systemBlue, title: "Niebieski", subtitle: "Maksymalnie", field: blueField)

        [redDescription, blueDescription, greenDescription].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        }
        redDescription.textColor = .systemRed
        blueDescription.textColor = .systemBlue
        greenDescription.textColor = .systemGreen
        let preview = NSStackView(views: [redDescription, blueDescription, greenDescription])
        preview.orientation = .horizontal
        preview.distribution = .fillEqually
        preview.spacing = 8

        let cancel = NSButton(title: "Anuluj", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Zapisz", target: self, action: #selector(savePressed))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [header, separator(), redRow, blueRow, preview, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        [header, redRow, blueRow, preview, buttons].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 42),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -18)
        ])
    }

    private func configureField(_ field: NSTextField) {
        field.alignment = .center
        field.formatter = integerFormatter()
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 58).isActive = true
    }

    private func limitRow(color: NSColor, title: String, subtitle: String, field: NSTextField) -> NSStackView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.backgroundColor = color.cgColor
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        let hint = NSTextField(labelWithString: subtitle)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name, hint])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        let row = NSStackView(views: [dot, labels, NSView(), field, NSTextField(labelWithString: "szpul")])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return row
    }

    func controlTextDidChange(_ obj: Notification) { updateDescriptions() }

    private func updateDescriptions() {
        let red = max(1, redField.integerValue)
        let blue = max(red + 1, blueField.integerValue)
        redDescription.stringValue = "1–\(red) czerwony"
        blueDescription.stringValue = "\(red + 1)–\(blue) niebieski"
        greenDescription.stringValue = "\(blue + 1)+ zielony"
    }

    @objc private func cancelPressed() { close() }

    @objc private func savePressed() {
        let red = redField.integerValue
        let blue = blueField.integerValue
        guard red >= 1, blue > red else {
            let alert = NSAlert()
            alert.messageText = "Nieprawidłowe limity"
            alert.informativeText = "Limit niebieski musi być większy od czerwonego."
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        StockLevelSettings.save(redMaximum: red, blueMaximum: blue)
        onSave()
        close()
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func integerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 10_000
        return formatter
    }
}
