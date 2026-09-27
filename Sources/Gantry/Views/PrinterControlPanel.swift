import AppKit
import Combine
import UniformTypeIdentifiers

/// Full printer control beside the detail view: print actions, sending a file (optionally straight to
/// print), moving the head, temperatures, fans and the socket's power draw. In the menu-bar popover it
/// slides out to the side on request; in the Gantry window it is always shown next to the details.
///
/// Every command goes through PrinterStore, which already knows each brand's dialect. Moves are only
/// offered while the printer is not printing.
@MainActor
final class PrinterControlPanelView: NSView {
    static let width: CGFloat = 420

    private let store: PrinterStore
    private let serial: String
    private let onClose: (() -> Void)?
    private var subscriptions: Set<AnyCancellable> = []
    private var farmSubscriptions: Set<AnyCancellable> = []
    private var powerTimer: Timer?
    private var refreshScheduled = false
    private lazy var farm = FarmStore.shared(printers: store)

    private let stack = NSStackView()

    // Actions
    private let pauseButton = PanelIconButton(symbol: "pause.fill")
    private let stopButton = PanelIconButton(symbol: "stop.fill", tint: GantryTheme.statusError)
    private let lightButton = PanelIconButton(symbol: "lightbulb.fill")
    private let powerButton = PanelIconButton(symbol: "power")
    private var lightOn = false

    // Send
    private let modeControl = NSSegmentedControl()
    private let dropZone = PanelDropZone()
    private let sendStatus = NSTextField(wrappingLabelWithString: "")

    // Motion
    private let jogPad = JogPadView()
    private var zButtons: [NSButton] = []
    private var homeButtons: [NSButton] = []
    private let motionNotice = NSTextField(wrappingLabelWithString: "")

    // Temperatures and fans
    private let nozzleRow = SliderRow(symbol: "flame", title: "Nozzle", range: 0...300, step: 5, suffix: "°", tint: GantryTheme.nozzle)
    private let bedRow = SliderRow(symbol: "square.stack.3d.down.forward", title: "Bed", range: 0...120, step: 5, suffix: "°", tint: GantryTheme.bed)
    private let chamberLabel = NSTextField(labelWithString: "")
    private let partFanRow = SliderRow(symbol: "fanblades", title: "Part fan", range: 0...100, step: 10, suffix: "%", tint: GantryTheme.accent)
    private let auxFanRow = SliderRow(symbol: "fanblades", title: "Aux fan", range: 0...100, step: 10, suffix: "%", tint: GantryTheme.accent)
    private let chamberFanRow = SliderRow(symbol: "fanblades", title: "Chamber fan", range: 0...100, step: 10, suffix: "%", tint: GantryTheme.accent)
    private let thermalNotice = NSTextField(wrappingLabelWithString: "")

    // Power
    private let powerChart = PowerChartView()
    private let powerLabel = NSTextField(labelWithString: "")
    private let powerSetup = NSButton()
    private var powerCard: NSView?

    init(store: PrinterStore, serial: String, onClose: (() -> Void)?) {
        self.store = store
        self.serial = serial
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 600))
        build()
        store.$telemetry.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        store.$printers.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        powerTimer?.invalidate()
        powerTimer = nil
        farmSubscriptions.removeAll()
        guard window != nil, !isHidden else { return }
        watchFarm()
        guard SmartPlugStore.shared.plug(for: serial)?.meters == true else { return }
        samplePower()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePower() }
        }
        RunLoop.main.add(timer, forMode: .common)
        powerTimer = timer
    }

    override var isHidden: Bool {
        didSet { if isHidden != oldValue { viewDidMoveToWindow() } }
    }

    private var printer: SavedPrinter? { store.printers.first { $0.serial == serial } }
    private var t: PrinterTelemetry { store.telemetry[serial] ?? PrinterTelemetry() }

    // MARK: Build

    private func build() {
        wantsLayer = true
        let s = AppSettings.shared
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let document = PanelFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 14, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        // Header
        let title = NSTextField(labelWithString: s.t("Control").uppercased())
        title.font = .systemFont(ofSize: 11, weight: .bold)
        title.textColor = GantryTheme.secondary
        var headerViews: [NSView] = [title, NSView()]
        if onClose != nil {
            let close = NSButton(title: s.t("Hide"), target: self, action: #selector(closePressed))
            close.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
            close.imagePosition = .imageLeading
            close.bezelStyle = .accessoryBar
            close.controlSize = .small
            headerViews.append(close)
        }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        add(header)

        add(card(s.t("PRINT"), actionsRow()))
        add(card(s.t("SEND FILE"), sendSection()))
        add(card(s.t("MOTION"), motionSection()))
        add(card(s.t("TEMPERATURES AND FANS"), thermalSection()))
        let power = card(s.t("POWER"), powerSection())
        powerCard = power
        add(power)
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    }

    private func card(_ title: String, _ content: NSView) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = GantryTheme.cardRadius
        box.layer?.borderWidth = 1
        box.layer?.borderColor = GantryTheme.line.cgColor
        box.layer?.backgroundColor = GantryTheme.card.withAlphaComponent(0.55).cgColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let inner = NSStackView(views: [label, content])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 11),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -11),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11),
            content.widthAnchor.constraint(equalTo: inner.widthAnchor)
        ])
        return box
    }

    private func notice(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .systemOrange
        label.isHidden = true
    }

    private func actionsRow() -> NSView {
        let s = AppSettings.shared
        pauseButton.caption = s.t("Pause")
        stopButton.caption = s.t("Stop")
        lightButton.caption = s.t("Light")
        powerButton.caption = s.t("Power")
        pauseButton.onPress = { [weak self] in self?.pauseOrResume() }
        stopButton.onPress = { [weak self] in self?.confirmStop() }
        lightButton.onPress = { [weak self] in self?.toggleLight() }
        powerButton.onPress = { [weak self] in self?.togglePower() }
        let row = NSStackView(views: [pauseButton, stopButton, lightButton, powerButton])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        return row
    }

    private func sendSection() -> NSView {
        let s = AppSettings.shared
        modeControl.segmentCount = 2
        modeControl.setLabel(s.t("Upload only"), forSegment: 0)
        modeControl.setLabel(s.t("Upload & print"), forSegment: 1)
        modeControl.setImage(NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil), forSegment: 0)
        modeControl.setImage(NSImage(systemSymbolName: "printer", accessibilityDescription: nil), forSegment: 1)
        modeControl.trackingMode = .selectOne
        modeControl.selectedSegment = 0
        modeControl.segmentDistribution = .fillEqually
        dropZone.onDrop = { [weak self] url in self?.send(url) }
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.heightAnchor.constraint(equalToConstant: 74).isActive = true
        let choose = NSButton(title: s.t("Choose file…"), target: self, action: #selector(chooseFile))
        choose.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        choose.imagePosition = .imageLeading
        choose.bezelStyle = .rounded
        let library = NSButton(title: s.t("Farm…"), target: self, action: #selector(openFarm))
        library.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: nil)
        library.imagePosition = .imageLeading
        library.bezelStyle = .rounded
        let buttons = NSStackView(views: [choose, NSView(), library])
        buttons.orientation = .horizontal
        sendStatus.font = .systemFont(ofSize: 11)
        sendStatus.textColor = GantryTheme.secondary
        let column = NSStackView(views: [modeControl, dropZone, buttons, sendStatus])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        for view in [modeControl, dropZone, buttons, sendStatus] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return column
    }

    private func motionSection() -> NSView {
        let s = AppSettings.shared
        jogPad.onJog = { [weak self] dx, dy in
            guard let self else { return }
            self.store.jog(serial: self.serial, x: dx, y: dy)
        }
        jogPad.onHome = { [weak self] in
            guard let self else { return }
            self.store.home(serial: self.serial, axes: "XY")
        }
        jogPad.translatesAutoresizingMaskIntoConstraints = false
        jogPad.widthAnchor.constraint(equalToConstant: 180).isActive = true
        jogPad.heightAnchor.constraint(equalToConstant: 180).isActive = true

        func zButton(_ title: String, _ distance: Double) -> NSButton {
            let button = PanelActionButton(title: title) { [weak self] in
                guard let self else { return }
                self.store.jog(serial: self.serial, z: distance)
            }
            zButtons.append(button)
            return button
        }
        let zColumn = NSStackView(views: [zButton("Z +10", 10), zButton("Z +1", 1), zButton("Z −1", -1), zButton("Z −10", -10)])
        zColumn.orientation = .vertical
        zColumn.spacing = 6
        func homeButton(_ title: String, _ axes: String) -> NSButton {
            let button = PanelActionButton(title: title, symbol: "house") { [weak self] in
                guard let self else { return }
                self.store.home(serial: self.serial, axes: axes)
            }
            homeButtons.append(button)
            return button
        }
        let homeColumn = NSStackView(views: [homeButton(s.t("All"), ""), homeButton("X", "X"), homeButton("Y", "Y"), homeButton("Z", "Z")])
        homeColumn.orientation = .vertical
        homeColumn.spacing = 6
        for button in zButtons + homeButtons { button.widthAnchor.constraint(equalToConstant: 72).isActive = true }
        let row = NSStackView(views: [jogPad, zColumn, homeColumn])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        notice(motionNotice)
        let column = NSStackView(views: [row, motionNotice])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        motionNotice.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func thermalSection() -> NSView {
        nozzleRow.onCommit = { [weak self] value in
            guard let self else { return }
            self.store.setNozzleTemperature(serial: self.serial, celsius: value)
        }
        bedRow.onCommit = { [weak self] value in
            guard let self else { return }
            self.store.setBedTemperature(serial: self.serial, celsius: value)
        }
        partFanRow.onCommit = { [weak self] value in
            guard let self else { return }
            self.store.setFan(serial: self.serial, index: 1, percent: value)
        }
        auxFanRow.onCommit = { [weak self] value in
            guard let self else { return }
            self.store.setFan(serial: self.serial, index: 2, percent: value)
        }
        chamberFanRow.onCommit = { [weak self] value in
            guard let self else { return }
            self.store.setFan(serial: self.serial, index: 3, percent: value)
        }
        chamberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        chamberLabel.textColor = GantryTheme.chamber
        notice(thermalNotice)
        let rows: [NSView] = [nozzleRow, bedRow, chamberLabel, partFanRow, auxFanRow, chamberFanRow, thermalNotice]
        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        for view in rows { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }

    private func powerSection() -> NSView {
        let s = AppSettings.shared
        powerChart.translatesAutoresizingMaskIntoConstraints = false
        powerChart.heightAnchor.constraint(equalToConstant: 90).isActive = true
        powerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        powerLabel.textColor = GantryTheme.text
        powerSetup.title = s.t("Set up socket…")
        powerSetup.bezelStyle = .rounded
        powerSetup.controlSize = .small
        powerSetup.target = self
        powerSetup.action = #selector(setUpSocket)
        let row = NSStackView(views: [powerLabel, NSView(), powerSetup])
        row.orientation = .horizontal
        row.alignment = .centerY
        let column = NSStackView(views: [row, powerChart])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        powerChart.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    // MARK: Refresh

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        let s = AppSettings.shared
        guard let printer else { return }
        let t = self.t
        let busy = t.state == .printing || t.state == .paused
        let online = t.state != .offline

        pauseButton.symbol = t.state == .paused ? "play.fill" : "pause.fill"
        pauseButton.caption = t.state == .paused ? s.t("Resume") : s.t("Pause")
        pauseButton.isEnabled = busy
        stopButton.isEnabled = busy
        lightButton.isEnabled = online
        lightButton.active = lightOn
        let plug = SmartPlugStore.shared.plug(for: serial)
        powerButton.isEnabled = plug != nil
        powerButton.active = SmartPlugController.shared.knownState[serial] == true
        powerButton.toolTip = plug == nil ? s.t("No smart socket is set up for this printer.") : nil

        let extensions = ["3mf", "gcode", "bgcode"].filter { PrinterFileTransfer.accepts(printer.kind, fileExtension: $0) }
        dropZone.caption = extensions.isEmpty
            ? s.t("This printer cannot receive files from Gantry.")
            : s.t("Drop a file here") + "\n" + s.t("Supported: {0}", extensions.map { "." + $0 }.joined(separator: ", "))
        dropZone.enabled = !extensions.isEmpty
        modeControl.isEnabled = !extensions.isEmpty

        let gcode = store.acceptsGcode(serial: serial)
        let motion = gcode && store.isMotionSafe(serial: serial)
        jogPad.enabled = motion
        (zButtons + homeButtons).forEach { $0.isEnabled = motion }
        motionNotice.isHidden = motion
        motionNotice.stringValue = !gcode
            ? s.t("This printer does not take motion commands from Gantry.")
            : s.t("Moving the head is available while the printer is not printing.")

        let bambu = printer.kind == .bambu
        nozzleRow.update(actual: t.nozzleTemperature, target: t.nozzleTargetTemperature)
        bedRow.update(actual: t.bedTemperature, target: t.bedTargetTemperature)
        chamberLabel.isHidden = t.chamberTemperature == nil
        chamberLabel.stringValue = s.t("Chamber") + ": " + (t.chamberTemperature.map { String(format: "%.0f°", $0) } ?? "—")
        partFanRow.update(actual: t.partFanPercent.map(Double.init), target: nil)
        auxFanRow.update(actual: t.auxFanPercent.map(Double.init), target: nil)
        chamberFanRow.update(actual: t.chamberFanPercent.map(Double.init), target: nil)
        auxFanRow.isHidden = !bambu
        chamberFanRow.isHidden = !bambu
        for row in [nozzleRow, bedRow, partFanRow, auxFanRow, chamberFanRow] { row.enabled = gcode && online }
        thermalNotice.isHidden = gcode
        thermalNotice.stringValue = bambu && store.requiresSignedCommands(serial: serial)
            ? s.t("Controls are off: the printer only accepts commands signed by Bambu Connect. Turn on LAN Only mode and Developer Mode on the printer.")
            : s.t("This printer does not take temperature or fan commands from Gantry.")

        powerSetup.isHidden = plug != nil && plug?.meters == true
        powerSetup.title = plug == nil ? s.t("Set up socket…") : s.t("Socket settings…")
        powerChart.isHidden = plug?.meters != true
        if plug == nil {
            powerLabel.stringValue = s.t("No smart socket")
        } else if plug?.meters != true {
            powerLabel.stringValue = s.t("This socket does not measure power.")
        } else {
            powerLabel.stringValue = powerChart.samples.last.map { String(format: "%.0f W · ", $0) + s.t("live") } ?? s.t("Reading…")
        }
    }

    // MARK: Actions

    @objc private func closePressed() { onClose?() }

    private func pauseOrResume() {
        store.sendPrintAction(t.state == .paused ? .resume : .pause, serial: serial)
    }

    private func confirmStop() {
        let s = AppSettings.shared
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = s.t("Stop the print on {0}?", printer?.name ?? serial)
        alert.informativeText = s.t("A stopped print cannot be resumed.")
        alert.addButton(withTitle: s.t("Stop"))
        alert.addButton(withTitle: s.t("Cancel"))
        guard ModalHost.run(alert) == .alertFirstButtonReturn else { return }
        store.sendPrintAction(.stop, serial: serial)
    }

    private func toggleLight() {
        lightOn.toggle()
        store.setChamberLight(lightOn, serial: serial)
        lightButton.active = lightOn
    }

    private func togglePower() {
        let on = SmartPlugController.shared.knownState[serial] != true
        SmartPlugController.shared.power(on, serial: serial)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.scheduleRefresh() }
    }

    @objc private func setUpSocket() { SmartPlugController.shared.showSetup(serial: serial) }

    @objc private func openFarm() { FarmWindowController.show(store: store) }

    @objc private func chooseFile() {
        guard let printer else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["3mf", "gcode", "bgcode"]
            .filter { PrinterFileTransfer.accepts(printer.kind, fileExtension: $0) }
            .compactMap { UTType(filenameExtension: $0) }
        guard ModalHost.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        send(url)
    }

    /// Imports the file into the Farm library and sends it to this printer. "Upload & print" asks
    /// about the bed first and then lets the Farm's own start rules decide when to start.
    private func send(_ url: URL) {
        let s = AppSettings.shared
        guard let printer else { return }
        guard PrinterFileTransfer.accepts(printer.kind, fileExtension: url.pathExtension) else {
            sendStatus.stringValue = s.t("{0} cannot print .{1} files.", printer.name, url.pathExtension.lowercased())
            return
        }
        let andPrint = modeControl.selectedSegment == 1
        if andPrint {
            let alert = NSAlert()
            alert.messageText = s.t("Send and print on {0}?", printer.name)
            alert.informativeText = s.t("{0}\nThe print starts as soon as the file is on the printer. Check that the file was sliced for this printer and nozzle.", url.lastPathComponent)
            let bed = NSButton(checkboxWithTitle: s.t("The bed is empty and ready"), target: nil, action: nil)
            bed.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
            alert.accessoryView = bed
            alert.addButton(withTitle: s.t("Send and print"))
            alert.addButton(withTitle: s.t("Cancel"))
            guard ModalHost.run(alert) == .alertFirstButtonReturn else { return }
            guard bed.state == .on else {
                sendStatus.stringValue = s.t("Confirm that the bed is empty to start the print.")
                return
            }
        }
        sendStatus.stringValue = s.t("Preparing {0}…", url.lastPathComponent)
        let farm = self.farm
        let serial = self.serial
        Task { @MainActor [weak self] in
            guard let file = await farm.importFile(url), let plate = file.plates.first else {
                self?.sendStatus.stringValue = farm.notice
                return
            }
            var mapping: [Int] = []
            if !file.isGcode {
                let slots = self?.store.telemetry[serial]?.amsSlots ?? []
                if let auto = FarmRules.autoMapping(plate, slots: slots) {
                    mapping = auto
                } else if plate.filaments.count > 1 {
                    self?.sendStatus.stringValue = AppSettings.shared.t("The AMS has no matching filament for every colour. Assign the slots in the Farm.")
                    return
                }
            }
            do {
                if andPrint { try farm.arm(serial) }
                try farm.upload(file: file, plate: plate, printer: printer, mapping: mapping, autoStart: andPrint)
            } catch {
                farm.disarm(serial)
                self?.sendStatus.stringValue = error.localizedDescription
            }
        }
    }

    private func watchFarm() {
        let serial = self.serial
        farm.$jobs.combineLatest(farm.$progress)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] jobs, progress in
                guard let self, let job = jobs.first(where: { $0.serial == serial }) else { return }
                if let value = progress[job.id] {
                    self.sendStatus.stringValue = AppSettings.shared.t("Sending {0}: {1}%", job.fileName, Int(value * 100))
                } else {
                    self.sendStatus.stringValue = "\(job.fileName) · \(job.message)"
                }
            }
            .store(in: &farmSubscriptions)
    }

    private func samplePower() {
        let serial = self.serial
        Task { @MainActor [weak self] in
            guard let client = SmartPlugStore.shared.client(for: serial) else { return }
            let watts = try? await client.power()
            guard let self, let watts else { return }
            self.powerChart.append(watts)
            self.refresh()
        }
    }
}

// MARK: - Pieces

@MainActor
private final class PanelFlippedView: NSView { override var isFlipped: Bool { true } }

/// A square button with an SF Symbol above a caption, lit when `active`.
@MainActor
final class PanelIconButton: NSButton {
    var onPress: (() -> Void)?
    var symbol: String { didSet { apply() } }
    var caption = "" { didSet { apply() } }
    var active = false { didSet { apply() } }
    private let tint: NSColor

    init(symbol: String, tint: NSColor = GantryTheme.text) {
        self.symbol = symbol
        self.tint = tint
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        imagePosition = .imageAbove
        target = self
        action = #selector(fire)
        heightAnchor.constraint(equalToConstant: 54).isActive = true
        apply()
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool { didSet { apply() } }

    @objc private func fire() { onPress?() }

    private func apply() {
        let color = !isEnabled ? GantryTheme.muted : active ? NSColor.systemYellow : tint
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: caption)?.withSymbolConfiguration(config)
        contentTintColor = color
        attributedTitle = NSAttributedString(string: caption, attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: 10, weight: .semibold)
        ])
        layer?.backgroundColor = (active ? NSColor.systemYellow.withAlphaComponent(0.12) : GantryTheme.surface).cgColor
        layer?.borderColor = (active ? NSColor.systemYellow.withAlphaComponent(0.4) : GantryTheme.line).cgColor
    }
}

/// A small bordered button that runs a closure.
@MainActor
private final class PanelActionButton: NSButton {
    private let run: () -> Void
    init(title: String, symbol: String? = nil, run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = .imageLeading }
        bezelStyle = .rounded
        controlSize = .regular
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func fire() { run() }
}

/// A labelled slider that sends its value when released, and shows "actual / target".
@MainActor
final class SliderRow: NSView {
    var onCommit: ((Int) -> Void)?
    var enabled = true { didSet { slider.isEnabled = enabled } }
    private let slider = TrackingSlider()
    private let valueLabel = NSTextField(labelWithString: "—")
    private let step: Int
    private let suffix: String
    /// After a change the printer takes a moment to echo it; until then the thumb keeps the new value.
    private var holdUntil = Date.distantPast

    init(symbol: String, title: String, range: ClosedRange<Int>, step: Int, suffix: String, tint: NSColor) {
        self.step = step
        self.suffix = suffix
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = tint
        let label = NSTextField(labelWithString: AppSettings.shared.t(title))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = GantryTheme.text
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.textColor = GantryTheme.text
        valueLabel.alignment = .right
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.trackFillColor = tint
        let top = NSStackView(views: [icon, label, NSView(), valueLabel])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 6
        let column = NSStackView(views: [top, slider])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalTo: column.widthAnchor),
            slider.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])
        slider.onRelease = { [weak self] in self?.commit() }
    }

    required init?(coder: NSCoder) { nil }

    private var snapped: Int { Int((slider.doubleValue / Double(step)).rounded()) * step }

    @objc private func changed() {
        valueLabel.stringValue = "→ \(snapped)\(suffix)"
    }

    private func commit() {
        holdUntil = Date().addingTimeInterval(4)
        slider.doubleValue = Double(snapped)
        onCommit?(snapped)
    }

    func update(actual: Double?, target: Double?) {
        guard !slider.isTracking else { return }
        let actualText = actual.map { String(format: "%.0f", $0) } ?? "—"
        if let target {
            valueLabel.stringValue = "\(actualText) / \(String(format: "%.0f", target))\(suffix)"
        } else {
            valueLabel.stringValue = "\(actualText)\(suffix)"
        }
        guard Date() > holdUntil else { return }
        slider.doubleValue = target ?? actual ?? slider.minValue
    }
}

/// NSSlider runs its own tracking loop inside mouseDown; knowing when it ends is how the row commits
/// once, on release, and ignores telemetry while a finger is still on it.
@MainActor
private final class TrackingSlider: NSSlider {
    var onRelease: (() -> Void)?
    private(set) var isTracking = false
    override func mouseDown(with event: NSEvent) {
        isTracking = true
        super.mouseDown(with: event)
        isTracking = false
        onRelease?()
    }
}

/// Where a file can be dropped (or clicked through "Choose file…").
@MainActor
private final class PanelDropZone: NSView {
    var onDrop: ((URL) -> Void)?
    var caption = "" { didSet { label.stringValue = caption } }
    var enabled = true { didSet { alphaValue = enabled ? 1 : 0.5 } }
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        label.alignment = .center
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = GantryTheme.secondary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        (hovering ? GantryTheme.accent.withAlphaComponent(0.1) : GantryTheme.surface).setFill()
        path.fill()
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.lineWidth = 1.2
        (hovering ? GantryTheme.accent : GantryTheme.muted).setStroke()
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard enabled else { return [] }
        hovering = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hovering = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovering = false
        guard enabled, let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first else { return false }
        onDrop?(url)
        return true
    }
}

/// A round XY pad: the inner ring moves 1 mm, the outer ring 10 mm, the centre homes X and Y.
@MainActor
final class JogPadView: NSView {
    var onJog: ((Double, Double) -> Void)?
    var onHome: (() -> Void)?
    var enabled = true { didSet { needsDisplay = true } }
    private var hover: (direction: Int, distance: Double)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// 0 up (+Y), 1 right (+X), 2 down (−Y), 3 left (−X); nil distance means the home button.
    private func hit(_ point: NSPoint) -> (direction: Int, distance: Double)? {
        let radius = min(bounds.width, bounds.height) / 2
        let dx = point.x - bounds.midX, dy = point.y - bounds.midY
        let r = (dx * dx + dy * dy).squareRoot()
        guard r <= radius else { return nil }
        if r < radius * 0.3 { return (-1, 0) }
        let distance: Double = r < radius * 0.64 ? 1 : 10
        let direction = abs(dx) > abs(dy) ? (dx > 0 ? 1 : 3) : (dy > 0 ? 0 : 2)
        return (direction, distance)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = hit(point)
        if next?.direction != hover?.direction || next?.distance != hover?.distance { hover = next; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard enabled, let target = hit(convert(event.locationInWindow, from: nil)) else { return }
        if target.direction == -1 { onHome?(); return }
        switch target.direction {
        case 0: onJog?(0, target.distance)
        case 1: onJog?(target.distance, 0)
        case 2: onJog?(0, -target.distance)
        default: onJog?(-target.distance, 0)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.width, bounds.height) / 2 - 1
        let centre = NSPoint(x: bounds.midX, y: bounds.midY)
        let base = enabled ? GantryTheme.surface.withAlphaComponent(0.12) : GantryTheme.surface.withAlphaComponent(0.05)
        func ring(_ outer: CGFloat, _ inner: CGFloat, _ color: NSColor) {
            let path = NSBezierPath()
            path.appendArc(withCenter: centre, radius: outer, startAngle: 0, endAngle: 360)
            path.appendArc(withCenter: centre, radius: inner, startAngle: 360, endAngle: 0, clockwise: true)
            color.setFill()
            path.fill()
        }
        ring(radius, radius * 0.64, NSColor.white.withAlphaComponent(enabled ? 0.07 : 0.03))
        ring(radius * 0.64, radius * 0.3, NSColor.white.withAlphaComponent(enabled ? 0.11 : 0.04))
        base.setFill()
        // Highlight the hovered segment: a quarter of the ring, centred on its direction.
        if enabled, let hover {
            let path = NSBezierPath()
            if hover.direction == -1 {
                path.appendArc(withCenter: centre, radius: radius * 0.3, startAngle: 0, endAngle: 360)
            } else {
                let middle = CGFloat([90, 0, 270, 180][hover.direction])
                let outer = hover.distance == 10 ? radius : radius * 0.64
                let inner = hover.distance == 10 ? radius * 0.64 : radius * 0.3
                path.appendArc(withCenter: centre, radius: outer, startAngle: middle - 45, endAngle: middle + 45)
                path.appendArc(withCenter: centre, radius: inner, startAngle: middle + 45, endAngle: middle - 45, clockwise: true)
                path.close()
            }
            GantryTheme.accent.withAlphaComponent(0.22).setFill()
            path.fill()
        }
        // The dividing diagonals.
        let lines = NSBezierPath()
        for angle in stride(from: 45.0, to: 360.0, by: 90.0) {
            let a = CGFloat(angle) * .pi / 180
            lines.move(to: NSPoint(x: centre.x + cos(a) * radius * 0.3, y: centre.y + sin(a) * radius * 0.3))
            lines.line(to: NSPoint(x: centre.x + cos(a) * radius, y: centre.y + sin(a) * radius))
        }
        lines.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        lines.stroke()
        let home = NSBezierPath()
        home.appendArc(withCenter: centre, radius: radius * 0.3 - 3, startAngle: 0, endAngle: 360)
        NSColor.black.withAlphaComponent(0.3).setFill()
        home.fill()

        let text = enabled ? GantryTheme.text : GantryTheme.muted
        func draw(_ string: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight) {
            let value = NSAttributedString(string: string, attributes: [
                .foregroundColor: text, .font: NSFont.systemFont(ofSize: size, weight: weight)
            ])
            let measured = value.size()
            value.draw(at: NSPoint(x: point.x - measured.width / 2, y: point.y - measured.height / 2))
        }
        let outerMid = radius * 0.82, innerMid = radius * 0.47
        draw("Y", at: NSPoint(x: centre.x, y: centre.y + outerMid), size: 12, weight: .bold)
        draw("−Y", at: NSPoint(x: centre.x, y: centre.y - outerMid), size: 12, weight: .bold)
        draw("X", at: NSPoint(x: centre.x + outerMid, y: centre.y), size: 12, weight: .bold)
        draw("−X", at: NSPoint(x: centre.x - outerMid, y: centre.y), size: 12, weight: .bold)
        draw("1", at: NSPoint(x: centre.x, y: centre.y + innerMid), size: 9, weight: .medium)
        draw("1", at: NSPoint(x: centre.x, y: centre.y - innerMid), size: 9, weight: .medium)
        draw("1", at: NSPoint(x: centre.x + innerMid, y: centre.y), size: 9, weight: .medium)
        draw("1", at: NSPoint(x: centre.x - innerMid, y: centre.y), size: 9, weight: .medium)
        if let image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) {
            let tinted = image.tinted(text)
            let size = tinted.size
            tinted.draw(in: NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height))
        }
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}

/// The socket's draw over the last few minutes.
@MainActor
final class PowerChartView: NSView {
    private(set) var samples: [Double] = []
    static let capacity = 100

    func append(_ watts: Double) {
        samples.append(watts)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let plot = bounds.insetBy(dx: 10, dy: 10)
        guard samples.count >= 2 else {
            let text = NSAttributedString(string: AppSettings.shared.t("Collecting data…"), attributes: [
                .foregroundColor: GantryTheme.muted, .font: NSFont.systemFont(ofSize: 11)
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
            return
        }
        let top = max((samples.max() ?? 1) * 1.15, 10)
        let stepX = plot.width / CGFloat(Self.capacity - 1)
        let startX = plot.maxX - stepX * CGFloat(samples.count - 1)
        let line = NSBezierPath()
        for (index, value) in samples.enumerated() {
            let point = NSPoint(x: startX + stepX * CGFloat(index), y: plot.minY + plot.height * CGFloat(value / top))
            if index == 0 { line.move(to: point) } else { line.line(to: point) }
        }
        if let area = line.copy() as? NSBezierPath {
            area.line(to: NSPoint(x: plot.maxX, y: plot.minY))
            area.line(to: NSPoint(x: startX, y: plot.minY))
            area.close()
            NSGradient(starting: NSColor.systemTeal.withAlphaComponent(0.35), ending: NSColor.systemTeal.withAlphaComponent(0.02))?
                .draw(in: area, angle: -90)
        }
        line.lineWidth = 1.6
        NSColor.systemTeal.setStroke()
        line.stroke()
        let peak = NSAttributedString(string: String(format: "%.0f W", samples.max() ?? 0), attributes: [
            .foregroundColor: GantryTheme.muted, .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        ])
        peak.draw(at: NSPoint(x: plot.minX, y: plot.maxY - 10))
    }
}
