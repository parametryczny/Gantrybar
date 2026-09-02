import AppKit
import Network

/// Dimmed in-window backdrop. Clicking outside the diagnostics card closes it.
private final class DiagnosticBackdropView: NSView {
    var onClickOutside: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClickOutside?() }
}

/// Fleet-wide connectivity check, presented inside Gantry's existing popover/window.
///
/// This used to be a standalone NSWindow owned by the Settings controller. Closing Settings released
/// the controller while its window was still on screen, so AppKit kept hit-testing freed views and the
/// app died with EXC_BAD_ACCESS on the next mouse move. Living in the popover as an overlay (like the
/// maintenance panel) keeps the controller retained for exactly as long as its views are visible.
@MainActor
final class DiagnosticCenterViewController: NSViewController {
    private static weak var activeBackdrop: NSView?
    private static var activeController: DiagnosticCenterViewController?

    private let store: PrinterStore
    private let results = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private var runButton = NSButton()
    private let progress = NSProgressIndicator()
    private var isRunning = false
    private var pending: DiagnosticProbeBox?
    private var pollTimer: Timer?
    private var runPrinters: [SavedPrinter] = []
    private var runIndex = 0
    private var runStarted = Date()
    private var probeStarted = Date()

    static func show(store: PrinterStore, in host: NSView) {
        dismiss()
        let controller = DiagnosticCenterViewController(store: store)
        let backdrop = DiagnosticBackdropView(frame: host.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        backdrop.onClickOutside = { DiagnosticCenterViewController.dismiss() }

        let panel = controller.view
        panel.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(panel)
        let preferredWidth = panel.widthAnchor.constraint(equalToConstant: 470)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = panel.heightAnchor.constraint(equalToConstant: 560)
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, constant: -24),
            panel.heightAnchor.constraint(lessThanOrEqualTo: backdrop.heightAnchor, constant: -24),
            preferredWidth,
            preferredHeight
        ])
        host.addSubview(backdrop)
        activeBackdrop = backdrop
        activeController = controller
    }

    static func dismiss() {
        activeController?.pollTimer?.invalidate()
        activeController?.pollTimer = nil
        activeBackdrop?.removeFromSuperview()
        activeBackdrop = nil
        activeController = nil
    }

    init(store: PrinterStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 560))
        panel.wantsLayer = true
        panel.layer?.cornerRadius = GantryTheme.cardRadius
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = GantryTheme.line.cgColor
        panel.layer?.backgroundColor = GantryTheme.card.withAlphaComponent(0.98).cgColor
        panel.layer?.masksToBounds = true
        view = panel
        build()
    }

    private func build() {
        let s = AppSettings.shared
        view.appearance = s.appearance

        let title = label(s.text("Centrum diagnostyczne", "Diagnostic Center"), 18, .bold, GantryTheme.text)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: s.text("Zamknij", "Close"))!,
                             target: self, action: #selector(closePressed))
        close.isBordered = false
        close.contentTintColor = GantryTheme.secondary
        close.toolTip = s.text("Zamknij", "Close")
        let header = NSStackView(views: [title, NSView(), close])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 8

        status.stringValue = s.text("Sprawdź łączność wszystkich drukarek.", "Check connectivity for every printer.")
        status.font = .systemFont(ofSize: 12)
        status.textColor = GantryTheme.secondary
        runButton = button(s.text("Uruchom wszystkie testy", "Run all tests"), action: #selector(runPressed))
        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.minValue = 0
        progress.isHidden = true

        results.orientation = .vertical; results.alignment = .leading; results.spacing = 9

        let body = NSStackView(views: [header, status, progress, runButton, results])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false

        let document = DiagnosticFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: body.widthAnchor),
            progress.widthAnchor.constraint(equalTo: body.widthAnchor),
            results.widthAnchor.constraint(equalTo: body.widthAnchor)
        ])
    }

    @objc private func closePressed() { Self.dismiss() }

    @objc private func runPressed() { runTests() }

    /// Hard ceiling per printer, so one unreachable host cannot stall the whole run.
    private static let perPrinterLimit: TimeInterval = 3

    private func runTests() {
        guard !isRunning else { return }
        isRunning = true
        runButton.isEnabled = false
        results.arrangedSubviews.forEach { results.removeArrangedSubview($0); $0.removeFromSuperview() }
        let printers = store.printers
        guard !printers.isEmpty else {
            results.addArrangedSubview(line(AppSettings.shared.text("Brak drukarek.", "No printers.")))
            status.stringValue = AppSettings.shared.text("Testy zakończone.", "Tests complete.")
            runButton.isEnabled = true
            isRunning = false
            return
        }
        progress.maxValue = Double(printers.count)
        progress.doubleValue = 0
        progress.isHidden = false
        runPrinters = printers
        runIndex = 0
        runStarted = Date()
        startRun()
    }

    /// The run is driven entirely by a main run-loop timer that owns the deadline itself. The probe is
    /// only ever *asked* for a result; if it never answers, the tick declares a timeout and moves on.
    /// That is the whole point: progress can no longer depend on the network layer calling anybody back.
    /// (No async/await either: on macOS 27 beta a MainActor continuation could sit unresumed forever.)
    private func startRun() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(tick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking while a menu or popover tracks events
        pollTimer = timer
        beginProbe()
    }

    private func beginProbe() {
        let s = AppSettings.shared
        let printer = runPrinters[runIndex]
        status.stringValue = String(format: s.text("Testuję %d z %d: %@", "Testing %d of %d: %@"),
                                    runIndex + 1, runPrinters.count, printer.name)
        let port = UInt16(printer.port ?? (printer.kind == .elegooCC2 ? 1883 : printer.kind == .klipper ? 7125 : 8883))
        probeStarted = Date()
        pending = Self.probe(host: printer.host, port: port, limit: Self.perPrinterLimit)
    }

    @objc private func tick() {
        guard Self.activeController === self, isRunning else {
            pollTimer?.invalidate(); pollTimer = nil
            return
        }
        let s = AppSettings.shared
        let outcome: (Bool, Double?, String?)
        if let answered = pending?.result {
            outcome = answered
        } else if Date().timeIntervalSince(probeStarted) >= Self.perPrinterLimit {
            outcome = (false, nil, s.text("brak odpowiedzi", "no response"))
        } else {
            return                                   // still within this printer's budget
        }
        pending = nil

        let printer = runPrinters[runIndex]
        let telemetry = store.telemetry[printer.serial] ?? PrinterTelemetry()
        let connected = telemetry.state != .offline
        let reason = store.connectionMessages[printer.serial] ?? "—"
        let built = card(printer: printer, network: outcome, connected: connected, reason: reason)
        results.addArrangedSubview(built)
        built.widthAnchor.constraint(equalTo: results.widthAnchor).isActive = true
        runIndex += 1
        progress.doubleValue = Double(runIndex)

        if runIndex < runPrinters.count {
            beginProbe()
        } else {
            pollTimer?.invalidate(); pollTimer = nil
            status.stringValue = String(format: s.text("Testy zakończone: %d drukarek w %.1f s",
                                                       "Tests complete: %d printers in %.1f s"),
                                        runPrinters.count, Date().timeIntervalSince(runStarted))
            progress.isHidden = true
            runButton.isEnabled = true
            isRunning = false
        }
    }

    private func card(printer: SavedPrinter, network: (Bool, Double?, String?),
                      connected: Bool, reason: String) -> NSView {
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
                      "\(connected ? "✓" : "×")  \(s.text("Połączenie z drukarką", "Printer connection")) · \(connected ? s.text("telemetria aktywna", "telemetry active") : reason)"]
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
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)
        ])
        // The width is pinned by the caller, after the box joins the stack: activating a constraint
        // between two views that share no ancestor yet throws inside AppKit and kills the run.
        return box
    }

    private func line(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .regular,
                      color: NSColor = GantryTheme.secondary) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        return label
    }

    private func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight,
                       _ color: NSColor = GantryTheme.text) -> NSTextField {
        let value = NSTextField(labelWithString: text)
        value.font = .systemFont(ofSize: size, weight: weight)
        value.textColor = color
        value.lineBreakMode = .byTruncatingTail
        return value
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.borderWidth = 1
        button.layer?.borderColor = GantryTheme.line.cgColor
        button.layer?.backgroundColor = GantryTheme.surface.cgColor
        button.contentTintColor = GantryTheme.text
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    /// TCP reachability with a hard deadline. Fills the returned box exactly once, from any thread.
    nonisolated private static func probe(host: String, port: UInt16, limit: TimeInterval) -> DiagnosticProbeBox {
        let box = DiagnosticProbeBox()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            box.finish((false, nil, "invalid port"), connection: nil)
            return box
        }
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
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
            box.finish((false, nil, "timeout"), connection: connection)
        }
        return box
    }
}

private final class DiagnosticProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Bool, Double?, String?)?
    private var settled = false

    var result: (Bool, Double?, String?)? {
        lock.lock(); defer { lock.unlock() }; return value
    }

    func finish(_ newValue: (Bool, Double?, String?), connection: NWConnection?) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true; value = newValue
        lock.unlock()
        connection?.cancel()
    }
}

/// Top-down layout for the scrolling document. `nonisolated` because AppKit reads isFlipped on every
/// hit-test: a dynamic isolation check there is pure overhead, and it crashes on macOS 27 beta.
private final class DiagnosticFlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}
