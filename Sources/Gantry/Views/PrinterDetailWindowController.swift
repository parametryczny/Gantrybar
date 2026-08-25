import AppKit
import AVFoundation
import Combine
import CoreMedia

/// Rich, in-popover per-printer detail view ("Szczegóły") — a HelixScreen-style read view shown by
/// swapping the popover's content, with a back button to return to the fleet. Monitor only: no
/// printer control. Bambu printers also get a live chamber-camera stream.
@MainActor
final class PrinterDetailViewController: NSViewController {
    private let store: PrinterStore
    private let serial: String
    private let onBack: () -> Void
    private let onOpenAutomations: () -> Void
    private let onOpenAdvanced: () -> Void
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var refreshScheduled = false

    // Reorderable section cards
    private let contentStack = NSStackView()
    private var cardViews: [String: NSView] = [:]
    // Contract order (GANTRY-DESIGN-SYSTEM.md §Widok szczegółów): Status → Kamera → Filamenty/AMS →
    // Temperatury → Wentylatory → Sterowanie.
    private static let defaultCardOrder = ["status", "camera", "ams", "temps", "fans", "control"]
    private static let cardOrderKey = "detail-card-order"

    // Header
    private let backButton = NSButton()
    private let stateDot = NSView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let progress = BrutalistProgressView()
    private let phaseStepper = PhaseStepperView()
    private let fileLabel = NSTextField(labelWithString: "")
    private let remainingLabel = NSTextField(labelWithString: "")
    private let layerLabel = NSTextField(labelWithString: "")

    // Temperatures
    private let graph = TemperatureGraphView()
    private let nozzleChip = TempChipView(title: "Dysza")
    private let bedChip = TempChipView(title: "Stół")
    private let chamberChip = TempChipView(title: "Komora")

    // Fans / speed
    private let partFan = FanChip(title: "Part")
    private let auxFan = FanChip(title: "Aux")
    private let chamberFan = FanChip(title: "Chamber")
    private let speedLabel = NSTextField(labelWithString: "")
    private let diameterLabel = NSTextField(labelWithString: "")

    // AMS / filaments — reuse the fleet card's dock so the layout logic stays identical.
    private let filamentDock = FilamentDockView()

    // Camera
    private let cameraView = CameraView()
    private var cameraCard: NSView?
    private var stream: RTSPCameraStream?
    private var klipperStream: KlipperCameraStream?
    private var cameraTimeout: DispatchWorkItem?
    private var receivedFrame = false

    init(store: PrinterStore, serial: String, onBack: @escaping () -> Void,
         onOpenAutomations: @escaping () -> Void, onOpenAdvanced: @escaping () -> Void) {
        self.store = store
        self.serial = serial
        self.onBack = onBack
        self.onOpenAutomations = onOpenAutomations
        self.onOpenAdvanced = onOpenAdvanced
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
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 14, right: 12)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(contentStack)
        NSLayoutConstraint.activate([
            flipped.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            flipped.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor)
        ])

        // Bambu (MQTT) and Klipper (Moonraker) both support control + camera; Prusa/Snapmaker later.
        let kind = store.printers.first(where: { $0.serial == serial })?.kind
        let supportsControlCamera = kind == .bambu || kind == .klipper
        cardViews = [
            "status": makeStatusCard(),
            "temps": makeTemperatureCard(),
            "fans": makeFansCard(),
            "ams": makeAMSCard()
        ]
        if supportsControlCamera {
            // The control + automations tile only appears in developer mode.
            if AppSettings.shared.developerMode { cardViews["control"] = makeControlCard() }
            cardViews["camera"] = makeCameraCard()
        }
        rebuildCards()
        view = root
    }

    // MARK: Card ordering (drag to reorder, persisted)

    private func orderedCardIDs() -> [String] {
        let available = Set(cardViews.keys)
        var result = savedCardOrder().filter { available.contains($0) }
        for id in Self.defaultCardOrder where available.contains(id) && !result.contains(id) { result.append(id) }
        return result
    }

    private func savedCardOrder() -> [String] {
        guard let data = BambuDefaults.shared.data(forKey: Self.cardOrderKey),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    // Movable/hideable sections (Status + Camera stay fixed, per the contract).
    private static let hideableModules = ["camera", "ams", "temps", "fans", "control"]
    private static let moduleTitles = ["camera": ("Kamera", "Camera"),
                                       "ams": ("Filamenty / AMS", "Filaments / AMS"),
                                       "temps": ("Temperatury", "Temperatures"),
                                       "fans": ("Wentylatory i prędkość", "Fans & speed"),
                                       "control": ("Sterowanie i automatyzacje", "Control & automations")]
    private static let hiddenKey = "gantry.detail.hidden.v1"

    private func hiddenModules() -> Set<String> {
        guard let data = BambuDefaults.shared.data(forKey: Self.hiddenKey),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }
    private func setHiddenModules(_ set: Set<String>) {
        if let data = try? JSONEncoder().encode(Array(set)) { BambuDefaults.shared.set(data, forKey: Self.hiddenKey) }
    }

    private func rebuildCards() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hidden = hiddenModules()
        for id in orderedCardIDs() where !hidden.contains(id) {
            guard let content = cardViews[id] else { continue }
            let container = DetailCardContainer(id: id, content: content) { [weak self] dragged, target, after in
                self?.reorderCard(dragged: dragged, target: target, after: after)
            }
            contentStack.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
        }
        let customize = makeCustomizeButton()
        contentStack.addArrangedSubview(customize)
        customize.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
    }

    private func makeCustomizeButton() -> NSView {
        let button = NSButton(title: AppSettings.shared.text("Dostosuj", "Customize"), target: self, action: #selector(customizePressed(_:)))
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = GantryTheme.tileRadius
        button.layer?.borderWidth = 1
        button.layer?.borderColor = GantryTheme.line.cgColor
        button.layer?.backgroundColor = GantryTheme.surface.cgColor
        button.contentTintColor = GantryTheme.secondary
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    @objc private func customizePressed(_ sender: NSButton) {
        let pl = AppSettings.shared.language == .pl
        let hidden = hiddenModules()
        let menu = NSMenu()
        for id in Self.hideableModules where cardViews[id] != nil {
            let titles = Self.moduleTitles[id]
            let item = NSMenuItem(title: pl ? (titles?.0 ?? id) : (titles?.1 ?? id),
                                  action: #selector(toggleModule(_:)), keyEquivalent: "")
            item.state = hidden.contains(id) ? .off : .on
            item.representedObject = id
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reset = NSMenuItem(title: AppSettings.shared.text("Przywróć domyślny układ", "Restore default layout"),
                               action: #selector(resetLayout), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func toggleModule(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        var hidden = hiddenModules()
        let nowHidden = !hidden.contains(id)
        if nowHidden { hidden.insert(id) } else { hidden.remove(id) }
        setHiddenModules(hidden)
        if id == "camera" { nowHidden ? stopCamera() : startCamera() }
        rebuildCards()
    }

    @objc private func resetLayout() {
        setHiddenModules([])
        BambuDefaults.shared.removeObject(forKey: Self.cardOrderKey)
        rebuildCards()
    }

    private func reorderCard(dragged: String, target: String, after: Bool) {
        guard dragged != target else { return }
        var order = orderedCardIDs()
        order.removeAll { $0 == dragged }
        guard let idx = order.firstIndex(of: target) else { return }
        order.insert(dragged, at: idx + (after ? 1 : 0))
        if let data = try? JSONEncoder().encode(order) { BambuDefaults.shared.set(data, forKey: Self.cardOrderKey) }
        rebuildCards()
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
        box.layer?.cornerRadius = GantryTheme.cardRadius
        box.layer?.borderWidth = 1
        box.layer?.borderColor = GantryTheme.line.cgColor
        box.layer?.backgroundColor = GantryTheme.card.withAlphaComponent(0.55).cgColor
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
        fileLabel.font = .systemFont(ofSize: 13, weight: .medium)
        fileLabel.textColor = GantryTheme.secondary
        fileLabel.lineBreakMode = .byTruncatingTail
        // Same segmented indicator as the dashboard cards.
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 11).isActive = true
        phaseStepper.translatesAutoresizingMaskIntoConstraints = false
        phaseStepper.heightAnchor.constraint(equalToConstant: 34).isActive = true

        layerLabel.setContentHuggingPriority(.required, for: .horizontal)
        let topRow = NSStackView(views: [nameLabel, NSView(), percentLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        // File name and layers share one line (name left, layers right).
        let fileRow = NSStackView(views: [fileLabel, NSView(), layerLabel])
        fileRow.orientation = .horizontal
        fileRow.alignment = .centerY
        fileRow.spacing = 8

        // A phase stepper (prep → printing → done) replaces the segmented bar here: the detail view has
        // room for the nicer "transit line" with the glowing current node.
        let stack = NSStackView(views: [topRow, fileRow, phaseStepper, remainingLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        pin(stack, in: box, inset: 11)
        topRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        fileRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        phaseStepper.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func makeTemperatureCard() -> NSView {
        let box = card()
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 104).isActive = true
        let chips = NSStackView(views: [nozzleChip, bedChip, chamberChip])
        chips.orientation = .horizontal
        chips.distribution = .fillEqually
        chips.spacing = 8
        let stack = NSStackView(views: [sectionTitle("Temperatury"), graph, chips])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: box, inset: 11)
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
        pin(stack, in: box, inset: 11)
        gauges.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        infoRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func makeAMSCard() -> NSView {
        let box = card()
        let stack = NSStackView(views: [sectionTitle("Filamenty / AMS"), filamentDock])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: box, inset: 11)
        filamentDock.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func makeControlCard() -> NSView {
        let box = card()
        let onButton = NSButton(title: AppSettings.shared.text("Światło wł.", "Light on"),
                                target: self, action: #selector(lightOn))
        let offButton = NSButton(title: AppSettings.shared.text("Światło wył.", "Light off"),
                                 target: self, action: #selector(lightOff))
        let automationsButton = NSButton(title: AppSettings.shared.text("Automatyzacje…", "Automations…"),
                                         target: self, action: #selector(openAutomations))
        for b in [onButton, offButton, automationsButton] { b.bezelStyle = .rounded; b.controlSize = .regular }
        let buttons = NSStackView(views: [onButton, offButton, NSView(), automationsButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [sectionTitle("Sterowanie i automatyzacje"), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: box, inset: 11)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    @objc private func lightOn() { setChamberLight(true) }
    @objc private func lightOff() { setChamberLight(false) }
    @objc private func openAutomations() { onOpenAutomations() }

    private func setChamberLight(_ on: Bool) {
        store.setChamberLight(on, serial: serial)
    }

    private func makeCameraCard() -> NSView {
        let box = card()
        cameraCard = box
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        cameraView.heightAnchor.constraint(equalToConstant: 230).isActive = true
        let advancedButton = NSButton(title: AppSettings.shared.text("Zaawansowane…", "Advanced…"),
                                      target: self, action: #selector(openAdvanced))
        advancedButton.isBordered = false
        advancedButton.font = .systemFont(ofSize: 10, weight: .medium)
        advancedButton.contentTintColor = .controlAccentColor
        let header = NSStackView(views: [sectionTitle("Kamera"), NSView(), advancedButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        let stack = NSStackView(views: [header, cameraView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: box, inset: 11)
        cameraView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    @objc private func openAdvanced() { onOpenAdvanced() }

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
        progress.value = t.progress
        phaseStepper.update(progress: t.progress, state: t.state, settings: AppSettings.shared)
        let file = t.jobName ?? ""
        fileLabel.stringValue = file
        fileLabel.isHidden = file.isEmpty

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
        } else if let mag = t.speedPercent {
            speedLabel.stringValue = settings.text("Prędkość: \(mag)%", "Speed: \(mag)%")
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
        filamentDock.isHidden = groups.isEmpty
        filamentDock.setGroups(groups, settings: AppSettings.shared, showRemaining: true)
    }

    // MARK: Camera

    private func startCamera() {
        guard !hiddenModules().contains("camera") else { return }   // don't stream a hidden camera
        guard let printer = store.printers.first(where: { $0.serial == serial }) else { return }
        receivedFrame = false
        switch printer.kind {
        case .bambu: startBambuCamera(printer)
        case .klipper: startKlipperCamera(printer)
        default: return
        }
        // If no frame arrives in time, show a helpful fallback.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.receivedFrame else { return }
            self.cameraView.showStatus(Self.cameraUnavailableText)
        }
        cameraTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    /// Camera reachable on a separate IP (per-printer override) or the printer's own host.
    private func cameraHost(for printer: SavedPrinter) -> String {
        let override = PrinterOverridesStore.shared.overrides(for: serial).cameraHost
        return (override?.isEmpty == false) ? override! : printer.host
    }

    private func startBambuCamera(_ printer: SavedPrinter) {
        guard stream == nil, let code = store.accessCode(for: serial), !code.isEmpty else {
            cameraView.showStatus(AppSettings.shared.text("Kamera niedostępna (brak kodu dostępu)",
                                                          "Camera unavailable (no access code)"))
            return
        }
        cameraView.showStatus(AppSettings.shared.text("Łączenie z kamerą…", "Connecting to camera…"))
        let stream = RTSPCameraStream(
            host: cameraHost(for: printer),
            accessCode: code,
            onState: { state in Task { @MainActor [weak self] in self?.handleCameraState(state) } },
            onParameterSets: { sps, pps in Task { @MainActor [weak self] in self?.cameraView.setParameterSets(sps: sps, pps: pps) } },
            onAccessUnit: { avcc, keyframe in Task { @MainActor [weak self] in self?.handleAccessUnit(avcc, keyframe: keyframe) } }
        )
        self.stream = stream
        stream.start()
    }

    private func startKlipperCamera(_ printer: SavedPrinter) {
        guard klipperStream == nil else { return }
        cameraView.showStatus(AppSettings.shared.text("Łączenie z kamerą…", "Connecting to camera…"))
        let stream = KlipperCameraStream(
            host: cameraHost(for: printer),
            port: printer.port ?? 7125,
            apiKey: store.accessCode(for: serial),
            onFrame: { data in Task { @MainActor [weak self] in self?.handleKlipperFrame(data) } },
            onState: { state in Task { @MainActor [weak self] in self?.handleKlipperState(state) } }
        )
        klipperStream = stream
        stream.start()
    }

    private func stopCamera() {
        cameraTimeout?.cancel()
        cameraTimeout = nil
        stream?.stop()
        stream = nil
        klipperStream?.stop()
        klipperStream = nil
    }

    private func handleAccessUnit(_ avcc: Data, keyframe: Bool) {
        receivedFrame = true
        cameraTimeout?.cancel()
        cameraView.enqueue(avcc, keyframe: keyframe)
    }

    private func handleKlipperFrame(_ data: Data) {
        receivedFrame = true
        cameraTimeout?.cancel()
        if let image = NSImage(data: data) { cameraView.show(image) }
    }

    private func handleCameraState(_ state: RTSPCameraStream.State) {
        switch state {
        case .connecting, .playing:
            break
        case .failed:
            if !receivedFrame { cameraView.showStatus(Self.cameraUnavailableText) }
        }
    }

    private func handleKlipperState(_ state: KlipperCameraStream.State) {
        switch state {
        case .connecting, .streaming:
            break
        case .failed:
            if !receivedFrame {
                cameraView.showStatus(AppSettings.shared.text(
                    "Kamera niedostępna — sprawdź konfigurację webcam w Moonraker (Fluidd/Mainsail)",
                    "Camera unavailable — check the webcam config in Moonraker (Fluidd/Mainsail)"))
            }
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

    static let nozzleColor = GantryTheme.nozzle
    static let bedColor = GantryTheme.bed
    static let chamberColor = GantryTheme.chamber

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
        layer?.cornerRadius = GantryTheme.tileRadius
        layer?.borderWidth = 1
        layer?.borderColor = GantryTheme.line.cgColor
        layer?.backgroundColor = GantryTheme.surface.cgColor
        titleLabel.stringValue = title.uppercased()
        titleLabel.font = .systemFont(ofSize: 8, weight: .bold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        valueLabel.textColor = GantryTheme.text
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 5).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true

        let titleRow = NSStackView(views: [dot, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleRow)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func set(current: Double?, target: Double?, accent: NSColor) {
        dot.layer?.backgroundColor = accent.cgColor
        layer?.backgroundColor = accent.withAlphaComponent(0.06).cgColor
        guard let current else { valueLabel.stringValue = "—"; return }
        if let target, target > 0 {
            valueLabel.stringValue = "\(Int(current))° / \(Int(target))°"
        } else {
            valueLabel.stringValue = "\(Int(current))°"
        }
    }
}

// MARK: - Compact fan chip (icon · label · %)

@MainActor
final class FanChip: NSView {
    private let valueLabel = NSTextField(labelWithString: "—")

    init(title: String) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "wind", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

        let stack = NSStackView(views: [icon, titleLabel, valueLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func set(percent: Int?) {
        valueLabel.stringValue = percent.map { "\($0)%" } ?? "—"
        valueLabel.textColor = percent == nil ? .tertiaryLabelColor : .labelColor
    }
}


// MARK: - Camera view (H.264 via AVSampleBufferDisplayLayer)

@MainActor
final class CameraView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()   // Bambu H.264
    private let imageView = NSImageView()                     // Klipper JPEG snapshots
    private let statusLabel = NSTextField(labelWithString: "")
    private var formatDescription: CMFormatDescription?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isHidden = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .white
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    func setParameterSets(sps: Data, pps: Data) {
        var format: CMFormatDescription?
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { ptrBuf in
                    sizes.withUnsafeBufferPointer { sizeBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format)
                    }
                }
            }
        }
        if let format { formatDescription = format }
    }

    func enqueue(_ avcc: Data, keyframe: Bool) {
        guard let formatDescription else { return }
        let length = avcc.count
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer else { return }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return }

        // Live stream with no timestamps → display each frame as soon as it arrives.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sampleBuffer)
        statusLabel.isHidden = true
    }

    /// Klipper JPEG snapshot frame.
    func show(_ image: NSImage) {
        imageView.image = image
        imageView.isHidden = false
        statusLabel.isHidden = true
    }

    func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }
}

// MARK: - Reorderable card container

private let detailCardType = NSPasteboard.PasteboardType("pl.gantry.detailcard")

/// Wraps one section card, adds a drag grip (top-right), and acts as both drag source and drop
/// target so the user can reorder the Szczegóły cards.
@MainActor
final class DetailCardContainer: NSView, NSDraggingSource {
    let cardID: String
    private let onReorder: (_ dragged: String, _ target: String, _ after: Bool) -> Void

    init(id: String, content: NSView, onReorder: @escaping (String, String, Bool) -> Void) {
        self.cardID = id
        self.onReorder = onReorder
        super.init(frame: .zero)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let handle = CardDragHandle { [weak self] event in self?.beginDrag(event) }
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)
        NSLayoutConstraint.activate([
            handle.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            handle.widthAnchor.constraint(equalToConstant: 22),
            handle.heightAnchor.constraint(equalToConstant: 18)
        ])

        registerForDraggedTypes([detailCardType])
    }

    required init?(coder: NSCoder) { nil }

    private func beginDrag(_ event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(cardID, forType: detailCardType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    private func snapshot() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage(size: bounds.size) }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: detailCardType) != nil ? .move : []
    }

    // Without draggingUpdated + prepareForDragOperation the drop is silently rejected on many macOS
    // versions, so reordering never happens.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: detailCardType) != nil ? .move : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.string(forType: detailCardType) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dragged = sender.draggingPasteboard.string(forType: detailCardType) else { return false }
        // Non-flipped container coords: lower y = visually lower half → insert after (below).
        let point = convert(sender.draggingLocation, from: nil)
        onReorder(dragged, cardID, point.y < bounds.midY)
        return true
    }
}

/// A small grip (top-right of a card) that starts the card drag on drag.
@MainActor
final class CardDragHandle: NSView {
    private let onDrag: (NSEvent) -> Void

    init(onDrag: @escaping (NSEvent) -> Void) {
        self.onDrag = onDrag
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Przenieś") ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        toolTip = AppSettings.shared.text("Przeciągnij, aby zmienić kolejność", "Drag to reorder")
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDragged(with event: NSEvent) { onDrag(event) }
}

/// A "transit line" progress: a neutral rail with named phase stops (prep → printing → done) and a
/// glowing current node that glides along by print progress. Colour stays neutral (accent), matching
/// the calm card palette rather than the vivid green of the inspiration.
@MainActor
final class PhaseStepperView: NSView {
    private var fraction: CGFloat = 0
    private var activeIndex = 0
    private let labels = (0..<3).map { _ in NSTextField(labelWithString: "") }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for label in labels {
            label.font = .systemFont(ofSize: 8, weight: .medium)
            label.textColor = GantryTheme.muted
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            label.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        }
        labels[0].alignment = .left
        labels[1].alignment = .center
        labels[2].alignment = .right
        NSLayoutConstraint.activate([
            labels[0].leadingAnchor.constraint(equalTo: leadingAnchor),
            labels[1].centerXAnchor.constraint(equalTo: centerXAnchor),
            labels[2].trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

    func update(progress: Int, state: PrinterState, settings: AppSettings) {
        fraction = max(0, min(1, CGFloat(progress) / 100))
        activeIndex = state == .finished ? 2 : (fraction < 0.02 ? 0 : (fraction >= 0.99 ? 2 : 1))
        labels[0].stringValue = settings.text("Przygotowanie", "Prep")
        labels[1].stringValue = settings.text("Drukowanie", "Printing")
        labels[2].stringValue = settings.text("Zakończono", "Done")
        for (index, label) in labels.enumerated() {
            label.textColor = index == activeIndex ? GantryTheme.text : GantryTheme.muted
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset: CGFloat = 8
        let trackY = bounds.height - 8
        let x0 = inset, x1 = bounds.width - inset
        let nodeX = x0 + fraction * (x1 - x0)

        let track = NSBezierPath(roundedRect: NSRect(x: x0, y: trackY - 1.5, width: x1 - x0, height: 3), xRadius: 1.5, yRadius: 1.5)
        GantryTheme.line.setFill(); track.fill()
        if nodeX > x0 {
            let fill = NSBezierPath(roundedRect: NSRect(x: x0, y: trackY - 1.5, width: nodeX - x0, height: 3), xRadius: 1.5, yRadius: 1.5)
            GantryTheme.accent.setFill(); fill.fill()
        }
        for stopX in [x0, (x0 + x1) / 2, x1] {
            let r: CGFloat = 2.5
            let dot = NSBezierPath(ovalIn: NSRect(x: stopX - r, y: trackY - r, width: r * 2, height: r * 2))
            (stopX <= nodeX + 0.5 ? GantryTheme.accent : GantryTheme.line).setFill(); dot.fill()
        }
        // Glowing current node: a soft ring, a solid core, and a small hole (the "donut" look).
        NSBezierPath(ovalIn: NSRect(x: nodeX - 7, y: trackY - 7, width: 14, height: 14)).fill(with: GantryTheme.accent.withAlphaComponent(0.25))
        NSBezierPath(ovalIn: NSRect(x: nodeX - 4, y: trackY - 4, width: 8, height: 8)).fill(with: GantryTheme.accent)
        NSBezierPath(ovalIn: NSRect(x: nodeX - 1.5, y: trackY - 1.5, width: 3, height: 3)).fill(with: GantryTheme.card)
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) { color.setFill(); fill() }
}
