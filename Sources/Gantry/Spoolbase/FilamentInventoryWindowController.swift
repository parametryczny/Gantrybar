import AppKit

@MainActor
final class FilamentInventoryWindowController: NSWindowController {
    private let filament: Filament
    private let onAdjust: (_ spools: Int) -> Void
    private let amountField = NSTextField()

    init(filament: Filament, onAdjust: @escaping (Int) -> Void) {
        self.filament = filament
        self.onAdjust = onAdjust
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 250),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 16
        swatch.layer?.borderWidth = 0.5
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.layer?.backgroundColor = NSColor(filamentHex: filament.colorHex).cgColor

        let brand = NSTextField(labelWithString: filament.brand.uppercased())
        brand.font = .systemFont(ofSize: 9, weight: .semibold)
        brand.textColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: filament.name)
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: "\(filament.type)  •  \(filament.colorName)  •  #\(filament.colorHex)")
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [brand, name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Zamknij")!, target: self, action: #selector(closePressed))
        close.bezelStyle = .circular
        close.controlSize = .small
        close.keyEquivalent = "\u{1b}"
        close.toolTip = "Zamknij"
        let heading = NSStackView(views: [swatch, labels, NSView(), close])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10
        swatch.widthAnchor.constraint(equalToConstant: 32).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let currentTitle = NSTextField(labelWithString: "Aktualny stan")
        currentTitle.font = .systemFont(ofSize: 10)
        currentTitle.textColor = .secondaryLabelColor
        let currentBadge = SpoolStateView(count: filament.spoolCount)
        let currentRow = NSStackView(views: [currentTitle, NSView(), currentBadge])
        currentRow.orientation = .horizontal
        currentRow.alignment = .centerY
        currentBadge.widthAnchor.constraint(equalToConstant: 70).isActive = true
        currentBadge.heightAnchor.constraint(equalToConstant: 24).isActive = true

        amountField.integerValue = filament.spoolCount
        amountField.alignment = .center
        amountField.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        amountField.formatter = integerFormatter()
        amountField.widthAnchor.constraint(equalToConstant: 62).isActive = true
        amountField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let minus = roundButton("minus", tooltip: "Odejmij szpule", action: #selector(minusPressed))
        let plus = roundButton("plus", tooltip: "Dodaj szpule", action: #selector(plusPressed))
        let unit = NSTextField(labelWithString: "szp.")
        unit.font = .systemFont(ofSize: 11, weight: .medium)
        unit.textColor = .secondaryLabelColor
        let controls = NSStackView(views: [minus, amountField, unit, plus])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 9
        minus.widthAnchor.constraint(equalToConstant: 32).isActive = true
        minus.heightAnchor.constraint(equalToConstant: 32).isActive = true
        plus.widthAnchor.constraint(equalToConstant: 32).isActive = true
        plus.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let changeTitle = NSTextField(labelWithString: "Nowy stan")
        changeTitle.font = .systemFont(ofSize: 10)
        changeTitle.textColor = .secondaryLabelColor
        let adjustment = NSStackView(views: [changeTitle, NSView(), controls])
        adjustment.orientation = .horizontal
        adjustment.alignment = .centerY

        let separator = NSBox()
        separator.boxType = .separator
        let cancel = NSButton(title: "Anuluj", target: self, action: #selector(closePressed))
        cancel.bezelStyle = .rounded
        let confirm = NSButton(title: "Zatwierdź", target: self, action: #selector(confirmPressed))
        confirm.bezelStyle = .rounded
        confirm.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), cancel, confirm])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [heading, separator, currentRow, adjustment, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        [heading, separator, currentRow, adjustment, footer].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -16)
        ])
    }

    private func roundButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!, target: self, action: action)
        button.bezelStyle = .circular
        button.controlSize = .regular
        button.toolTip = tooltip
        return button
    }

    @objc private func minusPressed() { amountField.integerValue = max(0, amountField.integerValue - 1) }
    @objc private func plusPressed() { amountField.integerValue += 1 }
    @objc private func closePressed() { close() }
    @objc private func confirmPressed() {
        let newCount = max(0, amountField.integerValue)
        let difference = newCount - filament.spoolCount
        if difference != 0 { onAdjust(difference) }
        close()
    }

    private func integerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 0
        formatter.maximum = 100_000
        return formatter
    }
}

private final class SpoolStateView: NSView {
    init(count: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.12).cgColor
        let label = NSTextField(labelWithString: "\(count) szp.")
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .systemGreen
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
