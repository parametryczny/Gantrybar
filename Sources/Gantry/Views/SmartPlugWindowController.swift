import AppKit

/// Setting up the socket that feeds one printer, with buttons that switch it for real, so a wrong IP
/// or outlet number shows up here rather than in an emergency.
@MainActor
final class SmartPlugWindowController: NSWindowController {
    private static var open: [String: SmartPlugWindowController] = [:]

    static func show(store: PrinterStore, serial: String) {
        let controller = open[serial] ?? SmartPlugWindowController(store: store, serial: serial)
        open[serial] = controller
        controller.window?.center()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let store: PrinterStore
    private let serial: String
    private let kindPopup = NSPopUpButton()
    private let hostField = NSTextField()
    private let channelField = NSTextField()
    private let entityField = NSTextField()
    private let onURLField = NSTextField()
    private let offURLField = NSTextField()
    private let userField = NSTextField()
    private let secretField = NSSecureTextField()
    private let autoOffField = NSTextField()
    private let emergencyCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var grid = NSGridView()

    private init(store: PrinterStore, serial: String) {
        self.store = store
        self.serial = serial
        let name = store.printers.first { $0.serial == serial }?.name ?? serial
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = AppSettings.shared.t("Smart socket — {0}", name)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build(name: name)
        load()
        _ = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [serial] _ in
            MainActor.assumeIsolated { _ = Self.open.removeValue(forKey: serial) }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func t(_ english: String, _ arguments: Any...) -> String { AppSettings.shared.t(english, arguments: arguments) }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func build(name: String) {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(labelWithString: t("Smart socket — {0}", name))
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: t("The socket or power-strip outlet this printer is plugged into. Gantry switches it from the card, from automations, from Telegram, and all at once with Emergency power-off."))
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: 11)

        for kind in SmartPlug.Kind.allCases { kindPopup.addItem(withTitle: kind.title) }
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        [hostField, channelField, entityField, onURLField, offURLField, userField, secretField, autoOffField].forEach {
            $0.bezelStyle = .roundedBezel
        }
        channelField.placeholderString = "1"
        entityField.placeholderString = "switch.p1s_zasilanie"
        onURLField.placeholderString = "http://192.168.1.60/on"
        offURLField.placeholderString = "http://192.168.1.60/off"
        userField.placeholderString = "admin"
        autoOffField.placeholderString = t("never")
        emergencyCheck.title = t("Include in Emergency power-off")

        grid = NSGridView(views: [
            [label(t("Type")), kindPopup],
            [label(t("Address")), hostField],
            [label(t("Outlet")), channelField],
            [label(t("Entity")), entityField],
            [label(t("URL to switch on")), onURLField],
            [label(t("URL to switch off")), offURLField],
            [label(t("Login")), userField],
            [label(t("Password / token")), secretField],
            [label(t("Switch off after print (min)")), autoOffField],
            [NSView(), emergencyCheck]
        ])
        grid.rowSpacing = 9
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            return b
        }
        let testRow = NSStackView(views: [button(t("Switch on"), #selector(testOn)), button(t("Switch off"), #selector(testOff)),
                                          button(t("Read state"), #selector(readState)), NSView()])
        testRow.spacing = 8
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let remove = button(t("Remove socket"), #selector(removePressed))
        let close = button(t("Close"), #selector(closePressed))
        close.keyEquivalent = "\u{1b}"
        let save = button(t("Save"), #selector(savePressed))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [remove, NSView(), close, save])
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, intro, grid, testRow, status, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            testRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private var selectedKind: SmartPlug.Kind {
        SmartPlug.Kind.allCases[max(0, kindPopup.indexOfSelectedItem)]
    }

    @objc private func kindChanged() {
        let kind = selectedKind
        func show(_ row: Int, _ visible: Bool) { grid.row(at: row).isHidden = !visible }
        let device = kind == .tasmota || kind == .shelly || kind == .shellyRPC
        show(1, kind != .http)
        show(2, device)
        show(3, kind == .homeAssistant)
        show(4, kind == .http)
        show(5, kind == .http)
        show(6, device)
        show(7, kind != .http)
        (grid.cell(atColumnIndex: 0, rowIndex: 1).contentView as? NSTextField)?.stringValue =
            kind == .homeAssistant ? t("Home Assistant URL") : t("Address")
        hostField.placeholderString = kind == .homeAssistant ? "http://192.168.1.10:8123" : "192.168.1.60"
        (grid.cell(atColumnIndex: 0, rowIndex: 7).contentView as? NSTextField)?.stringValue =
            kind == .homeAssistant ? t("Access token") : t("Password")
    }

    private func load() {
        let plug = SmartPlugStore.shared.plug(for: serial) ?? SmartPlug(kind: .tasmota)
        kindPopup.selectItem(at: SmartPlug.Kind.allCases.firstIndex(of: plug.kind) ?? 0)
        hostField.stringValue = plug.host
        channelField.stringValue = String(plug.channel)
        entityField.stringValue = plug.entityID ?? ""
        onURLField.stringValue = plug.onURL ?? ""
        offURLField.stringValue = plug.offURL ?? ""
        userField.stringValue = plug.username ?? ""
        secretField.stringValue = SmartPlugStore.shared.secret(for: serial) ?? ""
        autoOffField.stringValue = plug.autoOffMinutes.map(String.init) ?? ""
        emergencyCheck.state = plug.includeInEmergency ? .on : .off
        kindChanged()
        if SmartPlugStore.shared.plug(for: serial) == nil { status.stringValue = t("No socket saved yet.") }
    }

    private func current() -> SmartPlug {
        func text(_ f: NSTextField) -> String? {
            let v = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        var plug = SmartPlug(kind: selectedKind, host: text(hostField) ?? "",
                             channel: max(1, Int(channelField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1))
        plug.entityID = text(entityField)
        plug.onURL = text(onURLField)
        plug.offURL = text(offURLField)
        plug.username = text(userField)
        plug.autoOffMinutes = text(autoOffField).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        plug.includeInEmergency = emergencyCheck.state == .on
        return plug
    }

    private func run(_ on: Bool?) {
        let plug = current()
        if let problem = plug.problem { status.stringValue = problem; return }
        let client = SmartPlugClient(plug: plug, secret: secretField.stringValue)
        status.stringValue = t("Talking to the socket…")
        Task { @MainActor in
            do {
                let state: Bool?
                if let on { state = try await client.set(on) } else { state = try await client.state() }
                switch state {
                case true?: status.stringValue = t("The socket reports: on.")
                case false?: status.stringValue = t("The socket reports: off.")
                case nil: status.stringValue = on == nil ? t("The socket answered but did not say whether it is on.") : t("Sent. The socket did not report its state.")
                }
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func testOn() { run(true) }
    @objc private func testOff() {
        let busy = [PrinterState.printing, .paused].contains(store.telemetry[serial]?.state ?? .offline)
        if busy {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = t("The printer is printing")
            alert.informativeText = t("Switching the socket off now ends the print.")
            alert.addButton(withTitle: t("Switch off"))
            alert.addButton(withTitle: t("Cancel"))
            guard ModalHost.run(alert) == .alertFirstButtonReturn else { return }
        }
        run(false)
    }
    @objc private func readState() { run(nil) }

    @objc private func savePressed() {
        let plug = current()
        if let problem = plug.problem { status.stringValue = problem; return }
        SmartPlugStore.shared.set(plug, secret: secretField.stringValue, for: serial)
        close()
    }

    @objc private func removePressed() {
        SmartPlugStore.shared.set(nil, secret: nil, for: serial)
        close()
    }

    @objc private func closePressed() { close() }
}
