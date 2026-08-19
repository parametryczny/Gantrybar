import AppKit

/// Per-printer advanced overrides: a camera on a separate IP, and custom light on/off commands.
/// Opened from the detail card. Stored in `PrinterOverridesStore`.
@MainActor
final class PrinterAdvancedWindowController: NSWindowController {
    private let serial: String
    private let isKlipper: Bool
    private let cameraField = NSTextField()
    private let ledOnField = NSTextField()
    private let ledOffField = NSTextField()

    init(store: PrinterStore, serial: String) {
        self.serial = serial
        self.isKlipper = store.printers.first(where: { $0.serial == serial })?.kind == .klipper
        let name = store.printers.first(where: { $0.serial == serial })?.name ?? serial
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = AppSettings.shared.text("Zaawansowane — \(name)", "Advanced — \(name)")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        load()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func t(_ pl: String, _ en: String) -> String { AppSettings.shared.text(pl, en) }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func field(_ f: NSTextField, placeholder: String) -> NSTextField {
            f.placeholderString = placeholder
            f.font = .systemFont(ofSize: 12)
            return f
        }

        let cameraLabel = label(t("IP kamery (opcjonalnie)", "Camera IP (optional)"), bold: true)
        let cameraHint = hint(t("Gdy kamera jest pod innym adresem niż drukarka (np. Raspberry Pi z kamerą).",
                                "When the camera is on a different address than the printer (e.g. a Pi cam)."))
        _ = field(cameraField, placeholder: t("np. 192.168.1.50", "e.g. 192.168.1.50"))

        let ledLabel = label(t("Własne komendy światła (opcjonalnie)", "Custom light commands (optional)"), bold: true)
        let ledHint = hint(isKlipper
            ? t("Klipper: linia G-code, np. „SET_PIN PIN=caselight VALUE=1”.",
                "Klipper: a G-code line, e.g. “SET_PIN PIN=caselight VALUE=1”.")
            : t("Bambu: surowy JSON MQTT (jak w automatyzacjach).",
                "Bambu: raw MQTT JSON (as in automations)."))
        _ = field(ledOnField, placeholder: t("Komenda „światło wł.”", "“Light on” command"))
        _ = field(ledOffField, placeholder: t("Komenda „światło wył.”", "“Light off” command"))

        let saveButton = NSButton(title: t("Zapisz", "Save"), target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: t("Zamknij", "Close"), target: self, action: #selector(close))
        cancelButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [
            cameraLabel, cameraField, cameraHint,
            ledLabel, ledHint, ledOnField, ledOffField,
            buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.setCustomSpacing(16, after: cameraHint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            cameraField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ledOnField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ledOffField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func label(_ text: String, bold: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        return l
    }

    private func hint(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 10)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func load() {
        let ov = PrinterOverridesStore.shared.overrides(for: serial)
        cameraField.stringValue = ov.cameraHost ?? ""
        ledOnField.stringValue = ov.ledOn ?? ""
        ledOffField.stringValue = ov.ledOff ?? ""
    }

    @objc private func save() {
        func trimmed(_ f: NSTextField) -> String? {
            let v = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        let overrides = PrinterOverrides(cameraHost: trimmed(cameraField),
                                         ledOn: trimmed(ledOnField),
                                         ledOff: trimmed(ledOffField))
        PrinterOverridesStore.shared.set(overrides, for: serial)
        close()
    }
}
