import AppKit
import Combine

/// Rich, in-popover per-printer detail view ("Szczegóły") — a HelixScreen-style read view shown by
/// swapping the popover's content, with a back button to return to the fleet. Monitor only: no
/// printer control. Bambu printers also get a live chamber-camera stream.
@MainActor
final class PrinterDetailViewController: NSViewController {
    private let store: PrinterStore
    private let serial: String
    private let onBack: () -> Void
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var refreshScheduled = false

    // Header
    private let backButton = NSButton()
    private let stateDot = NSView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let remainingLabel = NSTextField(labelWithString: "")
    private let layerLabel = NSTextField(labelWithString: "")

    // Temperatures
    private let graph = TemperatureGraphView()
    private let nozzleChip = TempChipView(title: "Dysza")
    private let bedChip = TempChipView(title: "Stół")
    private let chamberChip = TempChipView(title: "Komora")

    // Fans / speed
    private let partFan = FanGaugeView(title: "Part")
    private let auxFan = FanGaugeView(title: "Aux")
    private let chamberFan = FanGaugeView(title: "Chamber")
    private let speedLabel = NSTextField(labelWithString: "")
    private let diameterLabel = NSTextField(labelWithString: "")

    // AMS / filaments
    private let amsStack = NSStackView()

    // Camera
    private let cameraView = CameraView()
    private var cameraCard: NSView?
    private var stream: BambuCameraStream?
    private var cameraTimeout: DispatchWorkItem?
    private var receivedFrame = false

    init(store: PrinterStore, serial: String, onBack: @escaping () -> Void) {
        self.store = store
        self.serial = serial
        self.onBack = onBack
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 700))
        // NSPopover measures the content's Auto Layout fittingSize (contentSize alone isn't honored
        // when the content uses constraints). Nothing here has an absolute width/height, so pin the
        // root to a fixed 480×700 and let the inner scroll view handle overflow.
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 480),
            root.heightAnchor.constraint(equalToConstant: 700)
        ])
        let header = makeHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = flipped
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 16, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        NSLayoutConstraint.activate([
            flipped.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            flipped.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor)
        ])

        stack.addArrangedSubview(makeStatusCard())
        stack.addArrangedSubview(makeTemperatureCard())
        stack.addArrangedSubview(makeFansCard())
        stack.addArrangedSubview(makeAMSCard())
        if store.printers.first(where: { $0.serial == serial })?.kind == .bambu {
            stack.addArrangedSubview(makeCameraCard())
        }
        for case let card as NSView in stack.arrangedSubviews {
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        subscription = store.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
        settingsSubscription = AppSettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startCamera()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopCamera()
    }

    deinit { stream?.stop() }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    // MARK: Header

    private func makeHeader() -> NSView {
        backButton.title = AppSettings.shared.text(" Wróć", " Back")
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.bezelStyle = .accessoryBar
        backButton.controlSize = .small
        backButton.target = self
        backButton.action = #selector(backPressed)

        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 5
        stateDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        stateDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        stateLabel.font = .systemFont(ofSize: 11, weight: .semibold)

        let row = NSStackView(views: [backButton, NSView(), stateDot, stateLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        return row
    }

    @objc private func backPressed() { onBack() }

    // MARK: Card builders

    private func card() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        return box
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func makeStatusCard() -> NSView {
        let box = card()
        nameLabel.font = .systemFont(ofSize: 20, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingTail
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        remainingLabel.textColor = .secondaryLabelColor
        layerLabel.font = .systemFont(ofSize: 11)
        layerLabel.textColor = .secondaryLabelColor
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let topRow = NSStackView(views: [nameLabel, NSView(), percentLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        let bottomRow = NSStackView(views: [remainingLabel, NSView(), layerLabel])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY

        let stack = NSStackView(views: [topRow, progress, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        pin(stack, in: box, inset: 14)
        topRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        progress.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func makeTemperatureCard() -> NSView {
        let box = card()
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 170).isActive = true
        let chips = NSStackView(views: [nozzleChip, bedChip, chamberChip])
        chips.orientation = .horizontal
        chips.distribution = .fillEqually
        chips.spacing = 8
        let stack = NSStackView(views: [sectionTitle("Temperatury"), graph, chips])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: box, inset: 14)
        graph.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        chips.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func makeFansCard() -> NSView {
        let box = card()
        let gauges = NSStackView(views: [partFan, auxFan, chamberFan])
        gauges.orientation = .horizontal
        gauges.distribution = .fillEqually
        gauges.spacing = 8
        speedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        diameterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        diameterLabel.textColor = .secondaryLabelColor
        let infoRow = NSStackView(views: [speedLabel, NSView(), diameterLabel])
        infoRow.orientation = .horizontal
        infoRow.alignment = .centerY
        let stack = NSStackView(views: [sectionTitle("Wentylatory i prędkość"), gauges, infoRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: box, inset: 14)
        gauges.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        infoRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func makeAMSCard() -> NSView {
        let box = card()
        amsStack.orientation = .vertical
        amsStack.alignment = .leading
        amsStack.spacing = 12
        let stack = NSStackView(views: [sectionTitle("Filamenty / AMS"), amsStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: box, inset: 14)
        amsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func makeCameraCard() -> NSView {
        let box = card()
        cameraCard = box
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        cameraView.heightAnchor.constraint(equalToConstant: 230).isActive = true
        let stack = NSStackView(views: [sectionTitle("Kamera"), cameraView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: box, inset: 14)
        cameraView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func pin(_ inner: NSView, in outer: NSView, inset: CGFloat) {
        inner.translatesAutoresizingMaskIntoConstraints = false
        outer.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: outer.topAnchor, constant: inset),
            inner.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: inset),
            inner.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -inset),
            inner.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -inset)
        ])
    }

    // MARK: Refresh

    private func refresh() {
        let settings = AppSettings.shared
        let t = store.telemetry[serial] ?? .init()
        let printer = store.printers.first(where: { $0.serial == serial })

        stateDot.layer?.backgroundColor = Self.color(for: t.state).cgColor
        stateLabel.stringValue = settings.text(t.state.label, englishState(t.state))
        stateLabel.textColor = Self.color(for: t.state)
        nameLabel.stringValue = printer?.name ?? serial
        percentLabel.stringValue = "\(t.progress)%"
        progress.doubleValue = Double(t.progress)

        if let minutes = t.remainingMinutes, minutes > 0, t.state == .printing || t.state == .paused {
            var text = formatRemaining(minutes)
            if let finish = Calendar.current.date(byAdding: .minute, value: minutes, to: Date()) {
                text += " · \(Self.finishFormatter.string(from: finish))"
            }
            remainingLabel.stringValue = text
            remainingLabel.isHidden = false
        } else {
            remainingLabel.isHidden = true
        }
        if let cur = t.currentLayer, let total = t.totalLayers, total > 0 {
            layerLabel.stringValue = settings.text("Warstwa \(cur) / \(total)", "Layer \(cur) / \(total)")
            layerLabel.isHidden = false
        } else {
            layerLabel.isHidden = true
        }

        graph.samples = store.temperatureHistory[serial] ?? []
        nozzleChip.set(current: t.nozzleTemperature, target: t.nozzleTargetTemperature, accent: Self.nozzleColor)
        bedChip.set(current: t.bedTemperature, target: t.bedTargetTemperature, accent: Self.bedColor)
        chamberChip.set(current: t.chamberTemperature, target: nil, accent: Self.chamberColor)

        partFan.set(percent: t.partFanPercent)
        auxFan.set(percent: t.auxFanPercent)
        chamberFan.set(percent: t.chamberFanPercent)
        if let level = t.speedLevel {
            var text = settings.text("Prędkość: ", "Speed: ") + speedName(level)
            if let mag = t.speedPercent { text += " · \(mag)%" }
            speedLabel.stringValue = text
            speedLabel.isHidden = false
        } else {
            speedLabel.isHidden = true
        }
        if let d = t.nozzleDiameter {
            diameterLabel.stringValue = String(format: "⌀ %.1f mm", d)
            diameterLabel.isHidden = false
        } else {
            diameterLabel.isHidden = true
        }

        renderAMS(t.filamentGroups)
    }

    private func renderAMS(_ groups: [FilamentGroup]) {
        amsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !groups.isEmpty else {
            let empty = NSTextField(labelWithString: AppSettings.shared.text("Brak modułów filamentu", "No filament modules"))
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            amsStack.addArrangedSubview(empty)
            return
        }
        for group in groups {
            let module = AMSModuleView(group: group)
            amsStack.addArrangedSubview(module)
            module.widthAnchor.constraint(equalTo: amsStack.widthAnchor).isActive = true
        }
    }

    // MARK: Camera

    private func startCamera() {
        guard stream == nil,
              let printer = store.printers.first(where: { $0.serial == serial }), printer.kind == .bambu,
              let code = store.accessCode(for: serial), !code.isEmpty else {
            if store.printers.first(where: { $0.serial == serial })?.kind == .bambu {
                cameraView.showStatus(AppSettings.shared.text("Kamera niedostępna (brak kodu dostępu)",
                                                              "Camera unavailable (no access code)"))
            }
            return
        }
        receivedFrame = false
        cameraView.showStatus(AppSettings.shared.text("Łączenie z kamerą…", "Connecting to camera…"))
        let stream = BambuCameraStream(
            host: printer.host,
            accessCode: code,
            onFrame: { data in Task { @MainActor [weak self] in self?.handleFrame(data) } },
            onState: { state in Task { @MainActor [weak self] in self?.handleCameraState(state) } }
        )
        self.stream = stream
        stream.start()

        // If no frame arrives, the model/firmware probably has LAN Live View off — say so.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.receivedFrame else { return }
            self.cameraView.showStatus(Self.cameraUnavailableText)
        }
        cameraTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func stopCamera() {
        cameraTimeout?.cancel()
        cameraTimeout = nil
        stream?.stop()
        stream = nil
    }

    private func handleFrame(_ data: Data) {
        receivedFrame = true
        cameraTimeout?.cancel()
        if let image = NSImage(data: data) { cameraView.show(image) }
    }

    private func handleCameraState(_ state: BambuCameraStream.State) {
        switch state {
        case .connecting, .streaming:
            break
        case .failed:
            if !receivedFrame { cameraView.showStatus(Self.cameraUnavailableText) }
        }
    }

    // MARK: Helpers

    private func englishState(_ state: PrinterState) -> String {
        switch state {
        case .idle: "Ready"
        case .printing: "Printing"
        case .paused: "Paused"
        case .finished: "Finished"
        case .error: "Error"
        case .offline: "Offline"
        }
    }

    private func speedName(_ level: Int) -> String {
        switch level {
        case 1: AppSettings.shared.text("Cichy", "Silent")
        case 2: "Standard"
        case 3: "Sport"
        case 4: AppSettings.shared.text("Wariat", "Ludicrous")
        default: "—"
        }
    }

    private func formatRemaining(_ minutes: Int) -> String {
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    static let nozzleColor = NSColor.systemOrange
    static let bedColor = NSColor.systemBlue
    static let chamberColor = NSColor.systemTeal

    static func color(for state: PrinterState) -> NSColor {
        switch state {
        case .printing: .systemBlue
        case .idle, .finished: .systemGreen
        case .paused: .systemOrange
        case .error: .systemRed
        case .offline: .systemGray
        }
    }

    static var cameraUnavailableText: String {
        AppSettings.shared.text(
            "Brak podglądu kamery.\nWłącz „LAN Only Mode” w drukarce — lokalny strumień\nnie działa, gdy drukarka jest połączona z chmurą.",
            "No camera preview.\nEnable “LAN Only Mode” on the printer — the local stream\nis unavailable while the printer is cloud-connected.")
    }

    private static let finishFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

// MARK: - Flipped container so the scroll view stacks top-down

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Temperature graph

@MainActor
final class TemperatureGraphView: NSView {
    var samples: [TemperatureSample] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let inset = NSEdgeInsets(top: 10, left: 34, bottom: 6, right: 8)
        let plot = NSRect(x: inset.left, y: inset.bottom,
                          width: bounds.width - inset.left - inset.right,
                          height: bounds.height - inset.top - inset.bottom)

        NSColor.controlBackgroundColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        guard samples.count >= 2 else {
            drawCentered(AppSettings.shared.text("Zbieranie danych…", "Collecting data…"))
            return
        }

        let allValues = samples.flatMap { [$0.nozzle, $0.bed, $0.chamber].compactMap { $0 } }
        let maxTemp = max((allValues.max() ?? 60) * 1.08, 40)
        let minTemp = 0.0

        let steps = 4
        for i in 0...steps {
            let frac = CGFloat(i) / CGFloat(steps)
            let y = plot.minY + frac * plot.height
            NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 0.5
            line.stroke()
            let temp = minTemp + Double(frac) * (maxTemp - minTemp)
            let label = "\(Int(temp))°"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: plot.minX - size.width - 4, y: y - size.height / 2), withAttributes: attrs)
        }

        let t0 = samples.first!.time.timeIntervalSinceReferenceDate
        let t1 = samples.last!.time.timeIntervalSinceReferenceDate
        let span = max(t1 - t0, 1)

        func x(for sample: TemperatureSample) -> CGFloat {
            plot.minX + CGFloat((sample.time.timeIntervalSinceReferenceDate - t0) / span) * plot.width
        }
        func y(for temp: Double) -> CGFloat {
            plot.minY + CGFloat((temp - minTemp) / (maxTemp - minTemp)) * plot.height
        }
        func drawLine(_ keyPath: KeyPath<TemperatureSample, Double?>, color: NSColor) {
            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineJoinStyle = .round
            var started = false
            for sample in samples {
                guard let temp = sample[keyPath: keyPath] else { started = false; continue }
                let point = NSPoint(x: x(for: sample), y: y(for: temp))
                if started { path.line(to: point) } else { path.move(to: point); started = true }
            }
            color.setStroke()
            path.stroke()
        }

        drawLine(\.chamber, color: PrinterDetailViewController.chamberColor)
        drawLine(\.bed, color: PrinterDetailViewController.bedColor)
        drawLine(\.nozzle, color: PrinterDetailViewController.nozzleColor)
    }

    private func drawCentered(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

// MARK: - Temperature chip

@MainActor
final class TempChipView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let dot = NSView()

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 9, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let titleRow = NSStackView(views: [dot, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        let stack = NSStackView(views: [titleRow, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func set(current: Double?, target: Double?, accent: NSColor) {
        dot.layer?.backgroundColor = accent.cgColor
        guard let current else { valueLabel.stringValue = "—"; return }
        if let target, target > 0 {
            valueLabel.stringValue = "\(Int(current))° / \(Int(target))°"
        } else {
            valueLabel.stringValue = "\(Int(current))°"
        }
    }
}

// MARK: - Fan radial gauge

@MainActor
final class FanGaugeView: NSView {
    private let title: String
    private var percent: Int?
    private let percentLabel = NSTextField(labelWithString: "—")
    private let titleLabel = NSTextField(labelWithString: "")

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 84).isActive = true
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        percentLabel.alignment = .center
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 9, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(percentLabel)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            percentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func set(percent: Int?) {
        self.percent = percent
        percentLabel.stringValue = percent.map { "\($0)%" } ?? "—"
        percentLabel.textColor = percent == nil ? .tertiaryLabelColor : .labelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 26
        let center = NSPoint(x: bounds.midX, y: bounds.midY + 6)
        let bg = NSBezierPath()
        bg.appendArc(withCenter: center, radius: radius, startAngle: -140, endAngle: -400, clockwise: true)
        bg.lineWidth = 6
        bg.lineCapStyle = .round
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        bg.stroke()

        guard let percent, percent > 0 else { return }
        let sweep = 280.0 * Double(min(percent, 100)) / 100.0
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: -140, endAngle: -140 - sweep, clockwise: true)
        arc.lineWidth = 6
        arc.lineCapStyle = .round
        NSColor.systemBlue.setStroke()
        arc.stroke()
    }
}

// MARK: - AMS module (grouped filament slots)

@MainActor
final class AMSModuleView: NSView {
    init(group: FilamentGroup) {
        super.init(frame: .zero)

        let name = NSTextField(labelWithString: group.displayName)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        var subParts: [String] = []
        if let humidity = group.humidityPercent { subParts.append("💧 \(humidity)%") }
        if let temp = group.temperatureCelsius { subParts.append("\(Int(temp))°C") }
        var headerViews: [NSView] = [name, NSView()]
        if !subParts.isEmpty {
            let sub = NSTextField(labelWithString: subParts.joined(separator: " · "))
            sub.font = .systemFont(ofSize: 10)
            sub.textColor = .secondaryLabelColor
            headerViews.append(sub)
        }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let slotsRow = NSStackView(views: group.slots.map { AMSSlotView(slot: $0) })
        slotsRow.orientation = .horizontal
        slotsRow.alignment = .top
        slotsRow.distribution = .fillEqually
        slotsRow.spacing = 8

        let stack = NSStackView(views: [header, slotsRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            slotsRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// A tall "spool" card: colour bar on top, material label, a translucent fill from the bottom that
/// visualises how much filament is left, and the percentage in the corner.
@MainActor
final class AMSSlotView: NSView {
    private let fillLayer = CALayer()
    private let fillFraction: CGFloat

    init(slot: FilamentSlot) {
        fillFraction = CGFloat(slot.remainingPercent ?? 0) / 100
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = slot.isActive ? 2 : 1
        layer?.borderColor = (slot.isActive ? NSColor.systemBlue : NSColor.separatorColor.withAlphaComponent(0.6)).cgColor

        let color = AMSSlotView.color(from: slot.colorHex)
        // Translucent fill from the bottom = remaining amount.
        fillLayer.backgroundColor = (slot.isPresent ? color.withAlphaComponent(0.20) : NSColor.clear).cgColor
        fillLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fillLayer)

        // Colour bar (the spool colour) across the top.
        let colorBar = NSView()
        colorBar.wantsLayer = true
        colorBar.layer?.cornerRadius = 4
        colorBar.layer?.backgroundColor = (slot.isPresent ? color : NSColor.separatorColor).cgColor
        colorBar.translatesAutoresizingMaskIntoConstraints = false
        colorBar.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let slotLabel = NSTextField(labelWithString: slot.label)
        slotLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        slotLabel.textColor = .secondaryLabelColor
        let material = NSTextField(labelWithString: slot.isPresent ? (slot.material ?? "—") : "—")
        material.font = .systemFont(ofSize: 11, weight: .semibold)
        material.lineBreakMode = .byWordWrapping
        material.maximumNumberOfLines = 2
        material.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let percent = NSTextField(labelWithString: slot.isPresent ? (slot.remainingPercent.map { "\($0)%" } ?? "—") : "—")
        percent.font = .monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        percent.textColor = slot.isPresent ? .labelColor : .tertiaryLabelColor

        let top = NSStackView(views: [colorBar, slotLabel, material])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 4
        top.translatesAutoresizingMaskIntoConstraints = false
        addSubview(top)
        percent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(percent)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            colorBar.widthAnchor.constraint(equalTo: top.widthAnchor),
            percent.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            percent.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            heightAnchor.constraint(equalToConstant: 128)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // Fill grows from the bottom to represent the remaining amount.
        let h = bounds.height * max(0, min(1, fillFraction))
        fillLayer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
    }

    static func color(from hex: String?) -> NSColor {
        guard var hex else { return .systemGray }
        hex = hex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else { return .systemGray }
        return NSColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Camera view

@MainActor
final class CameraView: NSView {
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .white
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ image: NSImage) {
        imageView.image = image
        statusLabel.isHidden = true
    }

    func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }
}
