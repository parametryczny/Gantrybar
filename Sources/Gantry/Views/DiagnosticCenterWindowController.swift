import AppKit
import Network

@MainActor
final class DiagnosticCenterWindowController: NSWindowController {
    private let store: PrinterStore
    private let results = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let runButton = NSButton()

    init(store: PrinterStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 540),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 440, height: 380)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        refreshLanguage()
        showWindow(nil); window?.center(); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true; content.layer?.backgroundColor = GantryTheme.canvas.cgColor
        status.font = .systemFont(ofSize: 11); status.textColor = GantryTheme.secondary
        runButton.target = self; runButton.action = #selector(runTests); runButton.bezelStyle = .rounded
        results.orientation = .vertical; results.alignment = .leading; results.spacing = 9
        let body = NSStackView(views: [status, runButton, results])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        let document = DiagnosticFlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.documentView = document; scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18), body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 18), body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
            results.widthAnchor.constraint(equalTo: body.widthAnchor)
        ])
        refreshLanguage()
    }

    private func refreshLanguage() {
        let s = AppSettings.shared
        window?.title = s.text("Centrum diagnostyczne", "Diagnostic Center")
        status.stringValue = s.text("Sprawdź łączność wszystkich drukarek.", "Check connectivity for every printer.")
        runButton.title = s.text("Uruchom wszystkie testy", "Run all tests")
    }

    @objc private func runTests() {
        runButton.isEnabled = false
        status.stringValue = AppSettings.shared.text("Testuję…", "Testing…")
        results.arrangedSubviews.forEach { results.removeArrangedSubview($0); $0.removeFromSuperview() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for printer in store.printers {
                let port = UInt16(printer.port ?? (printer.kind == .elegooCC2 ? 1883 : printer.kind == .klipper ? 7125 : 8883))
                let network = await Self.probe(host: printer.host, port: port)
                let telemetry = store.telemetry[printer.serial] ?? PrinterTelemetry()
                let mqtt = telemetry.state != .offline
                let jpeg = await CameraSnapshot.capture(printer: printer, store: store, timeout: 5)
                let secret = store.accessCode(for: printer.serial)?.isEmpty == false || printer.kind == .elegooCC1 || printer.kind == .snapmaker || printer.kind == .anycubicKobraS1
                let reason = store.connectionMessages[printer.serial] ?? "—"
                results.addArrangedSubview(card(printer: printer, network: network, mqtt: mqtt,
                                                camera: jpeg != nil, secret: secret, reason: reason))
            }
            if store.printers.isEmpty {
                results.addArrangedSubview(line(AppSettings.shared.text("Brak drukarek.", "No printers.")))
            }
            status.stringValue = AppSettings.shared.text("Testy zakończone.", "Tests complete.")
            runButton.isEnabled = true
        }
    }

    private func card(printer: SavedPrinter, network: (Bool, Double?, String?), mqtt: Bool,
                      camera: Bool, secret: Bool, reason: String) -> NSView {
        let s = AppSettings.shared
        let latency = network.1
        let quality: String = latency.map { value in
            value < 50 ? s.text("bardzo dobra", "excellent") : value < 150 ? s.text("dobra", "good")
                : value < 400 ? s.text("słaba", "poor") : s.text("bardzo słaba", "very poor")
        } ?? "—"
        let networkText = network.0
            ? "✓  \(s.text("Sieć", "Network")) · \(String(format: "%.0f", latency ?? 0)) ms · \(quality)"
            : "×  \(s.text("Sieć", "Network")) · \(network.2 ?? "—")"
        let values = [networkText,
                      "\(mqtt ? "✓" : "×")  MQTT · \(mqtt ? s.text("telemetria aktywna", "telemetry active") : reason)",
                      "\(camera ? "✓" : "×")  \(s.text("Kamera", "Camera"))",
                      "\(secret ? "✓" : "×")  \(s.text("Magazyn sekretów", "Secret storage")) · \(secret ? "OK" : s.text("brak kodu lub błąd Keychain", "missing code or Keychain error"))"]
        let title = line(printer.name, size: 13, weight: .semibold, color: GantryTheme.text)
        let stack = NSStackView(views: [title] + values.map { line($0) })
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView(); box.wantsLayer = true; box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = GantryTheme.card.withAlphaComponent(0.72).cgColor
        box.layer?.borderWidth = 1; box.layer?.borderColor = GantryTheme.line.cgColor
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 11), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -11),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            box.widthAnchor.constraint(equalTo: results.widthAnchor)
        ])
        return box
    }

    private func line(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .regular,
                      color: NSColor = GantryTheme.secondary) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        return label
    }

    nonisolated private static func probe(host: String, port: UInt16) async -> (Bool, Double?, String?) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return (false, nil, "invalid port") }
        return await withCheckedContinuation { continuation in
            let box = DiagnosticProbeBox(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let started = Date()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.finish((true, Date().timeIntervalSince(started) * 1000, nil), connection: connection)
                case .failed(let error): box.finish((false, nil, error.localizedDescription), connection: connection)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                box.finish((false, nil, "timeout"), connection: connection)
            }
        }
    }
}

private final class DiagnosticProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Bool, Double?, String?), Never>?
    init(_ continuation: CheckedContinuation<(Bool, Double?, String?), Never>) { self.continuation = continuation }
    func finish(_ value: (Bool, Double?, String?), connection: NWConnection) {
        lock.lock(); let callback = continuation; continuation = nil; lock.unlock()
        guard let callback else { return }
        connection.cancel(); callback.resume(returning: value)
    }
}

private final class DiagnosticFlippedView: NSView { override var isFlipped: Bool { true } }
