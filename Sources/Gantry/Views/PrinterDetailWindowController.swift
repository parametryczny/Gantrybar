import AppKit
import Combine

/// Rich, in-popover per-printer detail view ("Szczegóły") — a HelixScreen-style read view shown by
/// swapping the popover's content, with a back button to return to the fleet. Control surfaces are
/// an explicit opt-in in Advanced settings. Bambu printers also get a live chamber-camera stream.
@MainActor
final class PrinterDetailViewController: NSViewController {
    private let store: PrinterStore
    private let serial: String
    private let onBack: () -> Void
    private let onOpenAutomations: () -> Void
    private let onOpenAdvanced: () -> Void
    private let onSkipObjects: () -> Void
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var insightsSubscription: AnyCancellable?
    private var refreshScheduled = false

    // Reorderable section cards
    private let contentStack = NSStackView()
    private var cardViews: [String: NSView] = [:]
    // Contract order (GANTRY-DESIGN-SYSTEM.md §Widok szczegółów): Status → Kamera → Filamenty/AMS →
    // Temperatury → Wentylatory → Sterowanie.
    private static let defaultCardOrder = ["status", "recent", "maintenance", "stats", "camera", "ams", "temps", "fans", "control"]
    private static let cardOrderKey = "detail-card-order"

    // Header
    private let backButton = NSButton()
    private let skipObjectsButton = NSButton()
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
    private let nozzleChip = TempChipView(title: AppSettings.shared.t("Nozzle"))
    private let bedChip = TempChipView(title: AppSettings.shared.t("Bed"))
    private let chamberChip = TempChipView(title: AppSettings.shared.t("Chamber"))
    private let nozzleControl = ControlStepperView(range: 0...300, step: 5, showsTargetCaption: true, suffix: "°")
    private let bedControl = ControlStepperView(range: 0...120, step: 5, showsTargetCaption: true, suffix: "°")

    // Fans / speed
    private let partFan = FanChip(title: "Part")
    private let auxFan = FanChip(title: "Aux")
    private let chamberFan = FanChip(title: "Chamber")
    private let fanGauges = NSStackView()
    private let speedLabel = NSTextField(labelWithString: "")
    private let diameterLabel = NSTextField(labelWithString: "")
    private let partFanControl = ControlStepperView(range: 0...100, step: 10, showsTargetCaption: false, suffix: "%")
    private let auxFanControl = ControlStepperView(range: 0...100, step: 10, showsTargetCaption: false, suffix: "%")
    private let chamberFanControl = ControlStepperView(range: 0...100, step: 10, showsTargetCaption: false, suffix: "%")
    private let speedControl = ControlStepperView(range: 10...166, step: 10, showsTargetCaption: false, suffix: "%")
    private let speedLevelControl = ControlStepperView(range: 1...4, step: 1, showsTargetCaption: false, suffix: "")
    private let fanInfoRow = NSStackView()
    private let temperatureNotice = NSTextField(wrappingLabelWithString: "")
    private let fanNotice = NSTextField(wrappingLabelWithString: "")
    private lazy var partFanTile = ControlTileView(title: AppSettings.shared.t("Part"), symbol: "wind", stepper: partFanControl)
    private lazy var auxFanTile = ControlTileView(title: AppSettings.shared.t("Aux"), symbol: "wind", stepper: auxFanControl)
    private lazy var chamberFanTile = ControlTileView(title: AppSettings.shared.t("Chamber"), symbol: "wind", stepper: chamberFanControl)
    private lazy var speedTile = ControlTileView(title: AppSettings.shared.t("Speed"), symbol: "speedometer", stepper: speedControl)
    private lazy var speedLevelTile = ControlTileView(title: AppSettings.shared.t("Speed"), symbol: "speedometer", stepper: speedLevelControl)
    private let fanControls = NSStackView()
    private var fanTilesSignature = ""

    // AMS / filaments — reuse the fleet card's dock so the layout logic stays identical.
    private let filamentDock = FilamentDockView()
    private var renderedInsightsSignature = ""
    private var renderedFilamentGroups: [FilamentGroup]?
    private var renderedFilamentShowsGrams: Bool?
    private var renderedFilamentMonochrome: Bool?

    // Local history / maintenance / statistics
    private let recentPrintsStack = NSStackView()
    private let maintenanceStack = NSStackView()
    private let statisticsStack = NSStackView()

    // Camera. The feed itself lives in CameraFeedController; this view only hosts it.
    private lazy var cameraFeed = CameraFeedController(store: store, serial: serial)
    private var cameraCard: NSView?
    private let presentation: DashboardPresentation
    /// Reported whenever the cards change the height the panel needs, so the popover can follow.
    var onPreferredContentSize: ((NSSize) -> Void)?
    private var popoverHeightConstraint: NSLayoutConstraint?
    private var hasReportedSize = false
    private weak var headerRow: NSView?
    /// The height the panel used to be nailed to. It survives as a floor, so a short detail view
    /// looks the way it always did, and only a taller one is allowed past it.
    private static let minimumPopoverHeight: CGFloat = 700
    /// The one width the detail view has.
    ///
    /// There used to be two. The root view was pinned to 480 while the host was told 600, both for
    /// the initial `swapPopoverContent` and for every size reported afterwards, so the popover was
    /// 120 points wider than anything drawn in it and the surplus showed as an empty strip down the
    /// right-hand side. It surfaced with an error because the report only went out when the height
    /// changed, and an error changes the height: 0%, a different layer line, different rows.
    static let popoverContentWidth: CGFloat = 480

    init(store: PrinterStore, serial: String, onBack: @escaping () -> Void,
         onOpenAutomations: @escaping () -> Void, onOpenAdvanced: @escaping () -> Void,
         onSkipObjects: @escaping () -> Void = {},
         presentation: DashboardPresentation = .popover) {
        self.store = store
        self.serial = serial
        self.onBack = onBack
        self.onOpenAutomations = onOpenAutomations
        self.onOpenAdvanced = onOpenAdvanced
        self.onSkipObjects = onSkipObjects
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.popoverContentWidth,
                                        height: Self.minimumPopoverHeight))
        // The popover needs a definite fitting size, but the height is no longer a constant: it
        // follows the cards and stops at the screen, so a tall detail view on a tall display is not
        // forced to scroll inside a number picked by hand. In the detached window the host controls
        // both dimensions, keeping the header visible and the entire vertical scroll within it.
        root.translatesAutoresizingMaskIntoConstraints = false
        if presentation == .popover {
            let height = root.heightAnchor.constraint(equalToConstant: Self.minimumPopoverHeight)
            popoverHeightConstraint = height
            NSLayoutConstraint.activate([
                root.widthAnchor.constraint(equalToConstant: Self.popoverContentWidth),
                height
            ])
        }
        let header = makeHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        headerRow = header
        root.addSubview(header)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // Not autohiding, on purpose. A legacy scroller (the system setting "Show scroll bars:
        // Always") takes 15 points out of the clip view, and the cards are laid out against that clip
        // view: measured, they were 437 points wide while printing, when the content needs scrolling,
        // and 452 in an error state, when it happens to fit. The whole column therefore shifted
        // sideways as the state changed. Always asking for the scroller makes the lane constant, and
        // with overlay scrollers, the usual case, it costs nothing because they never take space.
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .overlay
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            // Tied to the clip view, not to the root, so the header and the cards keep one right
            // edge. Pinned to the root it sat 15 points further out whenever a scroller was taking
            // its lane, which is why "Back" and the state dot did not line up with the cards.
            header.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -14),
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
            // The clip view, always. Reserving a fixed lane for the scroller instead was tried and
            // was worse: the lane has to be known when the view is built, and the effective scroller
            // style is not, so the document came out wider than the clip view and the right edge of
            // every card was clipped away. Tracking the clip view can never do that.
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor)
        ])

        // Bambu (MQTT) and Klipper (Moonraker) both support control + camera; Prusa/Snapmaker later.
        let kind = store.printers.first(where: { $0.serial == serial })?.kind
        let supportsControlCamera = CameraFeedController.supportsCamera(kind)
        cardViews = [
            "status": makeStatusCard(),
            "recent": makeRecentPrintsCard(),
            "maintenance": makeMaintenanceCard(),
            "stats": makeStatisticsCard(),
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
    private static let hideableModules = ["recent", "maintenance", "stats", "camera", "ams", "temps", "fans", "control"]
    private static let moduleTitles = ["camera": ("Kamera", "Camera"),
                                       "recent": ("Ostatnie wydruki", "Recent prints"),
                                       "maintenance": ("Konserwacja", "Maintenance"),
                                       "stats": ("Statystyki", "Statistics"),
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
        updatePreferredHeight()
    }

    /// Height the cards actually need, capped by the screen. Hiding or showing a module changes it, so
    /// this runs from `rebuildCards` rather than once at load.
    private func updatePreferredHeight() {
        guard presentation == .popover, popoverHeightConstraint != nil else { return }
        // Measure after the new cards have their constraints, otherwise fittingSize is the old stack.
        DispatchQueue.main.async { [weak self] in
            guard let self, let constraint = self.popoverHeightConstraint else { return }
            self.view.layoutSubtreeIfNeeded()
            let header = (self.headerRow?.fittingSize.height ?? 24) + 16   // 8 above, 8 below
            let content = self.contentStack.fittingSize.height
            let screen = self.view.window?.screen ?? NSScreen.main
            let available = (screen?.visibleFrame.height ?? 900) - 40
            let target = min(max(Self.minimumPopoverHeight, header + content), max(320, available))
            // The first report always goes out, even when the height happens to match the floor.
            // Reporting only on a change meant the popover could keep whatever width the panel it
            // replaced had, which is its own version of the same gap.
            let changed = abs(constraint.constant - target) >= 1
            guard changed || !self.hasReportedSize else { return }
            self.hasReportedSize = true
            constraint.constant = target
            self.onPreferredContentSize?(NSSize(width: Self.popoverContentWidth, height: target))
        }
    }

    private func makeCustomizeButton() -> NSView {
        let button = NSButton(title: AppSettings.shared.t("Customize"), target: self, action: #selector(customizePressed(_:)))
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
        let pl = AppSettings.shared.isPolish
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
        let reset = NSMenuItem(title: AppSettings.shared.t("Restore default layout"),
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
        insightsSubscription = NotificationCenter.default.publisher(for: PrinterInsightsStore.didChange)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Telemetry that arrived while the popover was dismissed was not drawn. Catch up before it
        // is on screen, so the first frame is already current instead of settling afterwards.
        if refreshStale {
            refreshStale = false
            refresh()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startCamera()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopCamera()
    }

    // MARK: Camera

    /// Only the "is this module even visible" rule stays here; the feed itself is CameraFeedController's.
    private func startCamera() {
        guard !hiddenModules().contains("camera") else { return }   // don't stream a hidden camera
        cameraFeed.start()
    }

    private func stopCamera() { cameraFeed.stop() }

    /// Set when telemetry arrives at a dismissed popover; cleared by the catch-up in viewWillAppear.
    private var refreshStale = false

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            // Sibling of the dashboard's own gate. A dismissed popover keeps its window, so the
            // window alone says nothing — only isVisible does. Sampling the live app found this
            // refresh spending most of the main thread's busy time behind a closed popover.
            guard self.view.window?.isVisible == true else {
                self.refreshStale = true
                return
            }
            self.refresh()
        }
    }

    // MARK: Header

    private func makeHeader() -> NSView {
        backButton.title = AppSettings.shared.t(" Back")
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.bezelStyle = .accessoryBar
        backButton.controlSize = .small
        backButton.target = self
        backButton.action = #selector(backPressed)

        skipObjectsButton.title = AppSettings.shared.t("Skip object…")
        skipObjectsButton.target = self
        skipObjectsButton.action = #selector(skipObjectsPressed)
        skipObjectsButton.image = NSImage(systemSymbolName: "rectangle.stack.badge.minus", accessibilityDescription: nil)
        skipObjectsButton.imagePosition = .imageLeading
        skipObjectsButton.bezelStyle = .accessoryBar
        skipObjectsButton.controlSize = .small
        skipObjectsButton.isHidden = true

        // The state used to sit at the far right of this row, a whole row away from the printer it
        // described. It now rides next to the name inside the status card, which is where the eye
        // already is, so this row carries only navigation.
        let row = NSStackView(views: [backButton, skipObjectsButton, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        return row
    }

    @objc private func backPressed() { onBack() }
    @objc private func skipObjectsPressed() { onSkipObjects() }

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

        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 5
        stateDot.translatesAutoresizingMaskIntoConstraints = false
        stateDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        stateDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        stateLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        // A long printer name gives way before the state does: the state is the shorter string and
        // the one worth reading first when something is wrong.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [stateDot, stateLabel] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        layerLabel.setContentHuggingPriority(.required, for: .horizontal)
        let topRow = NSStackView(views: [nameLabel, stateDot, stateLabel, NSView(), percentLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 7
        topRow.setCustomSpacing(4, after: stateDot)
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
        graph.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let chips = NSStackView(views: [nozzleChip, bedChip, chamberChip])
        chips.orientation = .horizontal
        chips.distribution = .fillEqually
        chips.spacing = 8
        chips.alignment = .top
        // The setpoint lives inside the tile it changes. The chamber has none, so it is held to the
        // same height and its reading stays on the nozzle's and bed's line.
        nozzleChip.attach(nozzleControl)
        bedChip.attach(bedControl)
        NSLayoutConstraint.activate([
            bedChip.heightAnchor.constraint(equalTo: nozzleChip.heightAnchor),
            chamberChip.heightAnchor.constraint(equalTo: nozzleChip.heightAnchor)
        ])
        nozzleControl.onCommit = { [weak self] value in self?.store.setNozzleTemperature(serial: self?.serial ?? "", celsius: value) }
        bedControl.onCommit = { [weak self] value in self?.store.setBedTemperature(serial: self?.serial ?? "", celsius: value) }
        styleNotice(temperatureNotice)
        let stack = NSStackView(views: [sectionTitle(AppSettings.shared.t("TEMPERATURES")), graph, chips, temperatureNotice])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: box, inset: 11)
        graph.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        chips.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        temperatureNotice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func makeFansCard() -> NSView {
        let box = card()
        fanGauges.setViews([partFan, auxFan, chamberFan], in: .leading)
        fanGauges.orientation = .horizontal
        fanGauges.distribution = .fillEqually
        fanGauges.spacing = 8
        speedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        diameterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        diameterLabel.textColor = .secondaryLabelColor
        let infoRow = fanInfoRow
        infoRow.setViews([speedLabel, NSView(), diameterLabel], in: .leading)
        infoRow.orientation = .horizontal
        infoRow.alignment = .centerY
        fanControls.orientation = .vertical
        fanControls.spacing = 8
        partFanControl.onCommit = { [weak self] value in self?.store.setFan(serial: self?.serial ?? "", index: 1, percent: value) }
        auxFanControl.onCommit = { [weak self] value in self?.store.setFan(serial: self?.serial ?? "", index: 2, percent: value) }
        chamberFanControl.onCommit = { [weak self] value in self?.store.setFan(serial: self?.serial ?? "", index: 3, percent: value) }
        speedControl.onCommit = { [weak self] value in self?.store.setPrintSpeed(serial: self?.serial ?? "", percent: value) }
        speedLevelControl.onCommit = { [weak self] level in self?.store.setPrintSpeedLevel(serial: self?.serial ?? "", level: level) }
        speedLevelControl.format = { [weak self] level in self?.speedName(level) ?? "\(level)" }
        // Bambu reports fans in fifteenths of full speed, so 70% comes back as 67%.
        for fan in [partFanControl, auxFanControl, chamberFanControl] { fan.echoTolerance = 7 }
        styleNotice(fanNotice)
        // Controls on: the tiles carry the live value, so the read-only gauges would only repeat it.
        let stack = NSStackView(views: [sectionTitle(AppSettings.shared.t("FANS AND SPEED")), fanGauges, fanControls, infoRow, fanNotice])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: box, inset: 11)
        fanGauges.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        infoRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        fanControls.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        fanNotice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func styleNotice(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .systemOrange
        label.isHidden = true
    }

    /// Two tiles to a row. Klipper only drives the part fan, so there the grid is part fan and speed
    /// instead of two live tiles beside two greyed-out ones.
    private func layoutFanTiles(bambu: Bool) {
        let signature = bambu ? "bambu" : "other"
        guard signature != fanTilesSignature else { return }
        fanTilesSignature = signature
        // Bambu takes a speed mode, Klipper a percentage.
        let tiles = bambu ? [partFanTile, auxFanTile, chamberFanTile, speedLevelTile] : [partFanTile, speedTile]
        let rows = stride(from: 0, to: tiles.count, by: 2).map { start -> NSStackView in
            let row = NSStackView(views: Array(tiles[start..<min(start + 2, tiles.count)]))
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 8
            return row
        }
        fanControls.setViews(rows, in: .top)
        for row in rows { row.widthAnchor.constraint(equalTo: fanControls.widthAnchor).isActive = true }
    }

    private func makeAMSCard() -> NSView {
        let box = card()
        let stack = NSStackView(views: [sectionTitle(AppSettings.shared.t("FILAMENTS / AMS")), filamentDock])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pin(stack, in: box, inset: 11)
        filamentDock.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func makeRecentPrintsCard() -> NSView {
        let box = card()
        recentPrintsStack.orientation = .vertical
        recentPrintsStack.alignment = .leading
        recentPrintsStack.spacing = 6
        let showAll = NSButton(title: AppSettings.shared.t("Show all"), target: self, action: #selector(showPrintHistory))
        showAll.bezelStyle = .rounded; showAll.controlSize = .small
        let stack = NSStackView(views: [sectionTitle(AppSettings.shared.t("Recent prints")), recentPrintsStack, showAll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        pin(stack, in: box, inset: 11)
        recentPrintsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func makeMaintenanceCard() -> NSView {
        let box = card()
        maintenanceStack.orientation = .vertical
        maintenanceStack.alignment = .leading
        maintenanceStack.spacing = 6
        let open = NSButton(title: AppSettings.shared.t("Open maintenance…"),
                            target: self, action: #selector(openMaintenance))
        open.bezelStyle = .rounded; open.controlSize = .small
        let stack = NSStackView(views: [sectionTitle(AppSettings.shared.t("Maintenance")), maintenanceStack, open])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        pin(stack, in: box, inset: 11)
        maintenanceStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    private func makeStatisticsCard() -> NSView {
        let box = card()
        statisticsStack.orientation = .horizontal
        statisticsStack.distribution = .fillEqually
        statisticsStack.spacing = 8
        let stack = NSStackView(views: [sectionTitle(AppSettings.shared.t("Statistics")), statisticsStack])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        pin(stack, in: box, inset: 11)
        statisticsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return box
    }

    @objc private func openMaintenance() {
        guard let printer = store.printers.first(where: { $0.serial == serial }) else { return }
        MaintenancePanelViewController.show(
            printer: printer,
            telemetry: store.telemetry[serial] ?? PrinterTelemetry()
        )
    }

    @objc private func showPrintHistory() {
        let settings = AppSettings.shared
        let entries = PrinterInsightsStore.shared.snapshot(serial: serial, polish: settings.isPolish).history
        let rows = entries.map { entry -> String in
            let minutes = Int(entry.durationSeconds / 60)
            let duration = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
            return "\(entry.endedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.job.isEmpty ? "—" : entry.job) · \(duration)"
        }
        let alert = NSAlert()
        alert.messageText = settings.t("Full history")
        alert.informativeText = rows.isEmpty ? settings.t("No history.") : rows.joined(separator: "\n")
        if let window = view.window, window.windowController is FloatingDashboardWindowController {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func makeControlCard() -> NSView {
        let box = card()
        let onButton = NSButton(title: AppSettings.shared.t("Light on"),
                                target: self, action: #selector(lightOn))
        let offButton = NSButton(title: AppSettings.shared.t("Light off"),
                                 target: self, action: #selector(lightOff))
        let automationsButton = NSButton(title: AppSettings.shared.t("Automations…"),
                                         target: self, action: #selector(openAutomations))
        for b in [onButton, offButton, automationsButton] { b.bezelStyle = .rounded; b.controlSize = .regular }
        let buttons = NSStackView(views: [onButton, offButton, NSView(), automationsButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [sectionTitle(AppSettings.shared.t("CONTROL AND AUTOMATIONS")), buttons])
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
        let cameraView = cameraFeed.view
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        cameraView.heightAnchor.constraint(equalToConstant: 230).isActive = true
        let advancedButton = NSButton(title: AppSettings.shared.t("Advanced…"),
                                      target: self, action: #selector(openAdvanced))
        advancedButton.isBordered = false
        advancedButton.font = .systemFont(ofSize: 10, weight: .medium)
        advancedButton.contentTintColor = .controlAccentColor
        let header = NSStackView(views: [sectionTitle(AppSettings.shared.t("CAMERA")), NSView(), advancedButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        // The card's drag grip sits in the top-right corner (8 pt in, 22 wide); the button used to
        // run underneath it.
        header.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 24)
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
        let kind = printer?.kind
        // A Bambu printer that only takes commands signed by Bambu Connect refuses every capsule and
        // every skip, so it keeps the read-only view and gets one notice saying what to switch on.
        let signingBlocked = kind == .bambu && store.requiresSignedCommands(serial: serial)
        let supportsSkipping = kind.map {
            ObjectSkipping.isOffered(kind: $0, signedCommandsRequired: signingBlocked)
        } ?? false
        skipObjectsButton.isHidden = !supportsSkipping || (t.state != .printing && t.state != .paused)

        stateDot.layer?.backgroundColor = Self.color(for: t.state).cgColor
        stateLabel.stringValue = settings.t(englishState(t.state))
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
            layerLabel.stringValue = settings.t("Layer {0} / {1}", cur, total)
            layerLabel.isHidden = false
        } else {
            layerLabel.isHidden = true
        }

        graph.samples = store.temperatureHistory[serial] ?? []
        let controlEnabled = settings.printerControlEnabled && (kind == .bambu || kind == .klipper) && !signingBlocked
        for chip in [nozzleChip, bedChip, chamberChip] { chip.largeReading = controlEnabled }
        nozzleChip.showsControl = controlEnabled
        bedChip.showsControl = controlEnabled
        nozzleChip.set(current: t.nozzleTemperature, target: t.nozzleTargetTemperature, accent: Self.nozzleColor)
        bedChip.set(current: t.bedTemperature, target: t.bedTargetTemperature, accent: Self.bedColor)
        chamberChip.set(current: t.chamberTemperature,
                        target: (t.chamberTargetTemperature ?? 0) > 0 ? t.chamberTargetTemperature : nil,
                        accent: Self.chamberColor)
        // A heater that is off reports target 0; that is the setpoint, not the current reading.
        nozzleControl.show(reported: Int((t.nozzleTargetTemperature ?? 0).rounded()))
        bedControl.show(reported: Int((t.bedTargetTemperature ?? 0).rounded()))

        fanGauges.isHidden = controlEnabled
        fanControls.isHidden = !controlEnabled
        if controlEnabled { layoutFanTiles(bambu: kind == .bambu) }
        partFan.set(percent: t.partFanPercent)
        auxFan.set(percent: t.auxFanPercent)
        chamberFan.set(percent: t.chamberFanPercent)
        partFanControl.show(reported: t.partFanPercent ?? 0)
        auxFanControl.show(reported: t.auxFanPercent ?? 0)
        chamberFanControl.show(reported: t.chamberFanPercent ?? 0)
        speedControl.show(reported: t.speedPercent ?? 100)
        speedLevelControl.show(reported: t.speedLevel ?? 2)
        // With controls on, the speed tile already shows the mode or the percentage.
        if controlEnabled {
            speedLabel.isHidden = true
        } else if let level = t.speedLevel {
            var text = settings.t("Speed: ") + speedName(level)
            if let mag = t.speedPercent { text += " · \(mag)%" }
            speedLabel.stringValue = text
            speedLabel.isHidden = false
        } else if let mag = t.speedPercent {
            speedLabel.stringValue = settings.t("Speed: {0}%%", mag)
            speedLabel.isHidden = false
        } else {
            speedLabel.isHidden = true
        }
        // A refused command shows as the printer's reason on the card that sent it, not only as the
        // value sliding back.
        let rejection = store.commandRejections[serial].flatMap { Date().timeIntervalSince($0.date) < 120 ? $0 : nil }
        for (notice, area) in [(temperatureNotice, PrinterStore.CommandRejection.Area.temperature), (fanNotice, .fans)] {
            let shown = controlEnabled && rejection?.area == area
            notice.stringValue = shown ? Self.rejectionText(rejection?.reason ?? "", settings: settings) : ""
            notice.isHidden = !shown
        }
        if settings.printerControlEnabled && signingBlocked {
            temperatureNotice.stringValue = settings.t("Controls are off: the printer only accepts commands signed by Bambu Connect. Turn on LAN Only mode and then Developer Mode on the printer to control it from Gantry.")
            temperatureNotice.isHidden = false
        }
        if let d = t.nozzleDiameter {
            diameterLabel.stringValue = String(format: "⌀ %.1f mm", d)
            diameterLabel.isHidden = false
        } else {
            diameterLabel.isHidden = true
        }
        // An empty row still took its line and two gaps, which left a hole above the notice.
        fanInfoRow.isHidden = speedLabel.isHidden && diameterLabel.isHidden

        renderAMS(t.filamentGroups)
        refreshInsights(settings: settings)
    }

    private func refreshInsights(settings: AppSettings) {
        let snapshot = PrinterInsightsStore.shared.snapshot(serial: serial, polish: settings.isPolish)
        let recentEntries = Array(snapshot.history.prefix(3))
        let dueTasks = Array(snapshot.tasks.sorted { a, b in
            if a.isUrgent != b.isUrgent { return a.isUrgent }
            if a.isDue != b.isDue { return a.isDue }
            return a.remainingHours < b.remainingHours
        }.prefix(2))
        // History, maintenance and statistics change on the scale of whole prints, but telemetry
        // arrives several times a second, and each rebuild made three stacks of fresh NSTextFields
        // and measured every one of them. Sampling the live app found this alone taking most of the
        // main thread's busy time. Same guard as renderAMS below: rebuild only on a real change.
        let signature = recentEntries.map { "\($0.result)|\($0.job)|\(Int($0.durationSeconds))" }
            .joined(separator: ";")
            + "#" + dueTasks.map { "\($0.title)|\($0.isUrgent)|\($0.isDue)|"
                + "\(Int($0.remainingHours))|\(Int($0.overdueHours))" }.joined(separator: ";")
            + "#\(Int(snapshot.totalPrintHours * 10))|\(snapshot.successPercent ?? -1)"
            + "|\(Int(snapshot.consumedGrams))|\(settings.isPolish)"
        guard signature != renderedInsightsSignature else { return }
        renderedInsightsSignature = signature

        func clear(_ stack: NSStackView) {
            stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        }
        func line(_ text: String, color: NSColor = GantryTheme.secondary, weight: NSFont.Weight = .regular) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11.5, weight: weight)
            label.textColor = color
            label.lineBreakMode = .byTruncatingTail
            return label
        }

        clear(recentPrintsStack)
        let recent = recentEntries
        if recent.isEmpty {
            recentPrintsStack.addArrangedSubview(line(settings.t("No recorded history.")))
        } else {
            for entry in recent {
                let icon = entry.result == .completed ? "✓" : entry.result == .failed ? "!" : "×"
                let minutes = Int(entry.durationSeconds / 60)
                let duration = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
                let job = entry.job.isEmpty ? settings.t("Untitled") : entry.job
                recentPrintsStack.addArrangedSubview(line("\(icon)  \(job)  ·  \(duration)",
                    color: entry.result == .completed ? GantryTheme.secondary : .systemOrange,
                    weight: .medium))
            }
        }

        clear(maintenanceStack)
        for task in dueTasks {
            let timing = task.isDue
                ? settings.t("overdue by {0} h", String(format: "%.0f", task.overdueHours))
                : settings.t("in {0} print h", String(format: "%.0f", task.remainingHours))
            maintenanceStack.addArrangedSubview(line("\(task.isUrgent ? "!" : task.isDue ? "⚠" : "○")  \(task.title) · \(timing)",
                color: task.isUrgent ? .systemRed : task.isDue ? .systemYellow : GantryTheme.secondary,
                weight: task.isDue ? .semibold : .regular))
        }

        clear(statisticsStack)
        func metric(_ value: String, _ title: String) -> NSView {
            let valueLabel = line(value, color: GantryTheme.text, weight: .semibold)
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
            let titleLabel = line(title.uppercased(), color: GantryTheme.muted, weight: .bold)
            titleLabel.font = .systemFont(ofSize: 8, weight: .bold)
            let stack = NSStackView(views: [titleLabel, valueLabel])
            stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 3
            return stack
        }
        statisticsStack.addArrangedSubview(metric(String(format: "%.1f h", snapshot.totalPrintHours), settings.t("Print time")))
        statisticsStack.addArrangedSubview(metric(snapshot.successPercent.map { "\($0)%" } ?? "—", settings.t("Success")))
        statisticsStack.addArrangedSubview(metric(String(format: "%.0f g", snapshot.consumedGrams), settings.t("Filament")))
    }

    private func renderAMS(_ groups: [FilamentGroup]) {
        filamentDock.isHidden = groups.isEmpty
        // Telemetry lands several times a second. Rebuilding the dock every time made the card change
        // height and spring back, so rebuild only when the data or the settings it bakes in changed.
        let showsGrams = AppSettings.shared.cardShowSpoolGrams
        let monochrome = AppSettings.shared.monochrome
        guard renderedFilamentGroups != groups
            || renderedFilamentShowsGrams != showsGrams
            || renderedFilamentMonochrome != monochrome else { return }
        renderedFilamentGroups = groups
        renderedFilamentShowsGrams = showsGrams
        renderedFilamentMonochrome = monochrome
        filamentDock.setGroups(groups, settings: AppSettings.shared, showRemaining: true)
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

    /// Bambu firmware with authorization control answers "mqtt message verify failed" to any command
    /// not signed by Bambu Connect. Gantry does not sign, so the notice says what the printer needs.
    private static func rejectionText(_ reason: String, settings: AppSettings) -> String {
        if reason.localizedCaseInsensitiveContains("verify failed") {
            return settings.t("The printer only accepts commands signed by Bambu Connect. To control it from Gantry, turn on LAN Only mode and then Developer Mode on the printer.")
        }
        return settings.t("The printer rejected the command: {0}", reason)
    }

    private func speedName(_ level: Int) -> String {
        switch level {
        case 1: AppSettings.shared.t("Silent")
        case 2: "Standard"
        case 3: "Sport"
        case 4: AppSettings.shared.t("Ludicrous")
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

// MARK: - Opt-in control: a setpoint capsule inside its tile

/// A setpoint the user nudges, drawn as one inset capsule [ − | value | + ] that belongs to the tile
/// it sits in, instead of two loose squares on the card. Holding a button repeats. The command goes
/// out once the value settles, and for a few seconds telemetry still carrying the old setpoint is
/// ignored, so the number does not jump back under the pointer while the printer catches up.
@MainActor
final class ControlStepperView: NSView {
    static let height: CGFloat = 28
    private static let buttonWidth: CGFloat = 26
    private static let settleDelay: TimeInterval = 0.6
    private static let echoWindow: TimeInterval = 6

    var onCommit: ((Int) -> Void)?
    /// Reads the value as something other than a number and suffix, e.g. a Bambu speed mode's name.
    var format: ((Int) -> String)? { didSet { setValue(value) } }
    /// How far a reported value may sit from the one sent and still count as the printer's echo.
    var echoTolerance = 0
    private let range: ClosedRange<Int>
    private let step: Int
    private let suffix: String
    private let showsTargetCaption: Bool
    private let minusButton = StepButton(symbol: "minus", label: AppSettings.shared.t("Decrease"))
    private let plusButton = StepButton(symbol: "plus", label: AppSettings.shared.t("Increase"))
    private let valueLabel = NSTextField(labelWithString: "")
    private var value: Int
    private var commitTimer: Timer?
    private var ignoreReportsUntil = Date.distantPast

    init(range: ClosedRange<Int>, step: Int, showsTargetCaption: Bool, suffix: String) {
        self.range = range
        self.step = step
        self.suffix = suffix
        self.showsTargetCaption = showsTargetCaption
        self.value = range.lowerBound
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = GantryTheme.line.cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor

        valueLabel.alignment = .center
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        minusButton.onStep = { [weak self] in self?.nudge(-1) }
        plusButton.onStep = { [weak self] in self?.nudge(1) }
        let leftRule = Self.rule()
        let rightRule = Self.rule()
        for view in [minusButton, plusButton, valueLabel, leftRule, rightRule] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            minusButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            minusButton.topAnchor.constraint(equalTo: topAnchor),
            minusButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            minusButton.widthAnchor.constraint(equalToConstant: Self.buttonWidth),
            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            plusButton.topAnchor.constraint(equalTo: topAnchor),
            plusButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: Self.buttonWidth),
            leftRule.leadingAnchor.constraint(equalTo: minusButton.trailingAnchor),
            rightRule.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: leftRule.trailingAnchor, constant: 2),
            valueLabel.trailingAnchor.constraint(equalTo: rightRule.leadingAnchor, constant: -2),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        for rule in [leftRule, rightRule] {
            NSLayoutConstraint.activate([
                rule.widthAnchor.constraint(equalToConstant: 1),
                rule.topAnchor.constraint(equalTo: topAnchor, constant: 7),
                rule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
            ])
        }
        setValue(range.lowerBound)
    }

    required init?(coder: NSCoder) { nil }

    private static func rule() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = GantryTheme.line.cgColor
        return view
    }

    /// The printer's own setpoint. Held back while the user is still stepping and just after a
    /// command, unless the printer already reports the value that was sent.
    func show(reported: Int) {
        guard commitTimer == nil else { return }
        if Date() < ignoreReportsUntil {
            guard abs(clamp(reported) - value) <= echoTolerance else { return }
            ignoreReportsUntil = .distantPast
        }
        setValue(reported)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Closing the details right after a click must not swallow the change.
        if newWindow == nil, commitTimer != nil { commit() }
    }

    private func nudge(_ direction: Int) {
        // Onto the step grid first, so 223° goes to 225° and 220°, not 228° and 218°.
        let next = direction > 0 ? (value / step + 1) * step : ((value + step - 1) / step - 1) * step
        setValue(next)
        commitTimer?.invalidate()
        commitTimer = Timer.scheduledTimer(withTimeInterval: Self.settleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
    }

    private func commit() {
        commitTimer?.invalidate()
        commitTimer = nil
        ignoreReportsUntil = Date().addingTimeInterval(Self.echoWindow)
        onCommit?(value)
    }

    private func clamp(_ candidate: Int) -> Int { min(range.upperBound, max(range.lowerBound, candidate)) }

    private func setValue(_ candidate: Int) {
        value = clamp(candidate)
        minusButton.isEnabled = value > range.lowerBound
        plusButton.isEnabled = value < range.upperBound
        let settings = AppSettings.shared
        let text = NSMutableAttributedString()
        if showsTargetCaption {
            text.append(NSAttributedString(string: settings.t("Target").lowercased() + " ", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: GantryTheme.secondary
            ]))
        }
        let off = showsTargetCaption && value == 0
        text.append(NSAttributedString(string: off ? settings.t("Off").lowercased() : format?(value) ?? "\(value)\(suffix)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: off ? GantryTheme.secondary : GantryTheme.text
        ]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        valueLabel.attributedStringValue = text
        setAccessibilityValue(text.string)
    }
}

/// One end of the capsule. A plain view rather than an NSButton so the hover and pressed fills can
/// run edge to edge and follow the capsule's rounded corners.
@MainActor
private final class StepButton: NSView {
    var onStep: (() -> Void)?
    var isEnabled = true { didSet { if !isEnabled { stopRepeating() }; refresh() } }
    private let imageView = NSImageView()
    private var hovering = false
    private var pressed = false
    private var repeatTimer: Timer?

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onStep?()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        refresh()
        onStep?()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startRepeating() }
        }
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        stopRepeating()
        refresh()
    }

    private func startRepeating() {
        guard pressed else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pressed, self.isEnabled else { self?.stopRepeating(); return }
                self.onStep?()
            }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func refresh() {
        let fill: CGFloat = !isEnabled ? 0 : pressed ? 0.16 : hovering ? 0.08 : 0
        layer?.backgroundColor = NSColor.white.withAlphaComponent(fill).cgColor
        imageView.contentTintColor = isEnabled ? GantryTheme.text : GantryTheme.muted.withAlphaComponent(0.55)
        window?.invalidateCursorRects(for: self)
    }
}

/// A fan or the print speed as a tile: what it is on top, its setpoint capsule below. Same surface,
/// border and radius as the temperature tiles, so the two cards read as one set.
@MainActor
final class ControlTileView: NSView {
    init(title: String, symbol: String, stepper: ControlStepperView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = GantryTheme.tileRadius
        layer?.borderWidth = 1
        layer?.borderColor = GantryTheme.line.cgColor
        layer?.backgroundColor = GantryTheme.surface.cgColor
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "wind", accessibilityDescription: nil) ?? NSImage()
        let icon = NSImageView(image: image)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .systemFont(ofSize: 8, weight: .bold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        titleLabel.lineBreakMode = .byTruncatingTail
        let titleRow = NSStackView(views: [icon, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        for view in [titleRow, stepper] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),
            stepper.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 7),
            stepper.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stepper.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stepper.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { nil }
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
            drawCentered(AppSettings.shared.t("Collecting data…"))
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
    private var stepper: ControlStepperView?
    private var controlConstraints: [NSLayoutConstraint] = []

    /// With a setpoint capsule shown, the tile reads the live temperature large above it; the capsule
    /// carries the target. Without one it keeps the compact "current / target" reading.
    var showsControl = false {
        didSet {
            guard showsControl != oldValue, let stepper else { return }
            stepper.isHidden = !showsControl
            if showsControl { NSLayoutConstraint.activate(controlConstraints) }
            else { NSLayoutConstraint.deactivate(controlConstraints) }
        }
    }

    /// The larger reading used while the card shows controls. Set on every tile in the row, the
    /// chamber included, so the three readings stay one size.
    var largeReading = false {
        didSet {
            guard largeReading != oldValue else { return }
            valueLabel.font = .monospacedDigitSystemFont(ofSize: largeReading ? 18 : 15, weight: .medium)
        }
    }

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
        // Only a floor otherwise; this settles the height when nothing inside asks for more.
        let resting = heightAnchor.constraint(equalToConstant: 46)
        resting.priority = .defaultLow
        resting.isActive = true

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
            // Hung from the title, not the bottom edge, so a taller neighbour does not push this
            // reading off the line the others sit on.
            valueLabel.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 3),
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func attach(_ stepper: ControlStepperView) {
        self.stepper = stepper
        stepper.translatesAutoresizingMaskIntoConstraints = false
        stepper.isHidden = !showsControl
        addSubview(stepper)
        controlConstraints = [
            stepper.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 6),
            stepper.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stepper.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stepper.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ]
        if showsControl { NSLayoutConstraint.activate(controlConstraints) }
    }

    func set(current: Double?, target: Double?, accent: NSColor) {
        dot.layer?.backgroundColor = accent.cgColor
        layer?.backgroundColor = accent.withAlphaComponent(0.06).cgColor
        guard let current else { valueLabel.stringValue = "—"; return }
        if showsControl, stepper != nil {
            valueLabel.stringValue = "\(Int(current))°"
        } else if let target, target > 0 {
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
        let icon = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: AppSettings.shared.t("Move")) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        toolTip = AppSettings.shared.t("Drag to reorder")
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
        labels[0].stringValue = settings.t("Prep")
        labels[1].stringValue = settings.t("Printing")
        labels[2].stringValue = settings.t("Finished")
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
