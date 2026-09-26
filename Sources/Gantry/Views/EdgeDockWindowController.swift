import AppKit
import Combine
import CoreImage

/// A narrow always-on-top strip that grows out of a screen edge, showing one progress ring per
/// printer. Collapsed it is 22 points wide and carries only colour and fill; hovering expands it into
/// a list with names, percentages and remaining time, and clicking a row opens that printer's details.
///
/// Issue #34 added two things to that. Pinning keeps the list unfolded without the pointer, and the
/// pin on the strip itself both pins and releases it. Separately, any printer can be given a live
/// picture that hangs directly under its own row, so a print is watched at a glance instead of
/// through a window that has to stay open. The two are independent: a picture works on a strip that
/// still folds, it is simply hidden until the strip opens.
///
/// The "grows out of the edge" look comes from the two concave fillets where the strip meets the
/// screen: the window is taller than the visible body by one fillet radius at each end, and the extra
/// area is filled with everything *except* a quarter disc. Nothing is drawn as a background colour —
/// `drawShape` fills the silhouette itself, so the window can stay fully transparent.
enum EdgeDockEdge: String, CaseIterable, Sendable {
    case left
    case right
}

@MainActor
final class EdgeDockWindowController {
    private let store: PrinterStore
    private let panel: EdgeDockPanel
    private let dockView: EdgeDockView
    private let backdrop = NSVisualEffectView()
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var screenSubscription: AnyCancellable?
    /// One feed per printer the user ticked for a picture, keyed by serial.
    private var cameraFeeds: [String: CameraFeedController] = [:]
    /// When the running unfold animation is due to finish, so a routine refresh can keep its hands off.
    private var unfoldingUntil: Date?

    init(store: PrinterStore, onSelect: @escaping (String) -> Void, onSettings: @escaping () -> Void) {
        self.store = store
        dockView = EdgeDockView()
        panel = EdgeDockPanel(contentRect: NSRect(x: 0, y: 0, width: 22, height: 120),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        // Above ordinary windows and above a full-screen app's own space, and present on every Space
        // so it does not vanish when the user switches desktops.
        panel.level = .normal
        panel.collectionBehavior = [.managed, .ignoresCycle]
        // Frosted glass under the silhouette. `.behindWindow` blurs the desktop, and the strip's own
        // fill sits on top of it as a dark floor, so the blur is visible without the rows losing
        // their contrast to whatever happens to be behind the strip.
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.material = .hudWindow
        backdrop.wantsLayer = true
        // The backdrop's mask clips its subviews to the silhouette too, so the settings button, which
        // sits under the silhouette, is drawn by a sibling above it rather than inside it.
        let container = NSView()
        panel.contentView = container
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)
        dockView.frame = backdrop.bounds
        dockView.autoresizingMask = [.width, .height]
        backdrop.addSubview(dockView)
        dockView.settingsButtonView.frame = container.bounds
        container.addSubview(dockView.settingsButtonView)
        // The view that knows the silhouette also keeps the blur clipped to it, on every layout pass,
        // so the frost follows the shape while the panel is still animating open.
        dockView.backdrop = backdrop

        dockView.onSelect = onSelect
        dockView.onSettings = onSettings
        dockView.onLayoutChange = { [weak self] animated in self?.reposition(animated: animated) }
        // Pinning and releasing belong on the strip: reaching Settings for something you can see is
        // the long way round. It used to be release-only, and pinning meant a trip to Settings.
        // Writing the setting is enough to drive the rest, because the settings subscription below
        // brings us straight back into refresh().
        dockView.onTogglePin = { AppSettings.shared.edgeDockPinned.toggle() }

        // The store publishes on every telemetry packet; throttling keeps the strip from redrawing
        // several times a second for a bar that moves once a minute.
        subscription = store.objectWillChange
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }
        settingsSubscription = AppSettings.shared.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        // Resolution changes and display hot-plugs move the edge, so the strip has to be re-pinned.
        // A single plug or a TV waking up can post a burst of these while the display list is still
        // settling, so only the last one counts.
        screenSubscription = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(EdgeDockPlacement.displayChangeDebounceMilliseconds), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } }
        refresh()
    }

    func refresh() {
        let settings = AppSettings.shared
        panel.level = settings.edgeDockAlwaysOnTop ? .statusBar : .normal
        panel.collectionBehavior = settings.edgeDockAlwaysOnTop
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            : [.managed, .ignoresCycle]
        guard settings.edgeDockEnabled else {
            hide()
            return
        }
        let hidden = settings.edgeDockHiddenPrinters
        let entries: [EdgeDockEntry] = store.printers.compactMap { printer in
            guard !hidden.contains(printer.serial) else { return nil }
            let telemetry = store.telemetry[printer.serial] ?? PrinterTelemetry()
            if settings.edgeDockOnlyPrinting, telemetry.state != .printing, telemetry.state != .paused { return nil }
            return EdgeDockEntry(serial: printer.serial, name: printer.name, state: telemetry.state,
                                 progress: telemetry.progress, remainingMinutes: telemetry.remainingMinutes)
        }
        guard !entries.isEmpty else {
            hide()
            return
        }
        dockView.edge = settings.edgeDockEdge
        dockView.scale = CGFloat(settings.edgeDockScalePercent) / 100
        dockView.pinned = settings.edgeDockPinned
        syncCameras(entries: entries, settings: settings)
        let described = entries.map { entry in
            var entry = entry
            entry.camera = cameraState(for: entry.serial)
            return entry
        }
        // Printers with a live picture first, the rest under them, each group in fleet order. A stable
        // split rather than a sort, so two printers never swap places within a group.
        dockView.entries = described.filter { $0.camera == .live } + described.filter { $0.camera != .live }
        reposition()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Taking the strip off screen must also take the streams down; an invisible camera would keep
    /// decoding frames and holding the printer's single stream slot.
    private func hide() {
        detachCameras()
        panel.orderOut(nil)
    }

    private func detachCameras() {
        cameraFeeds.values.forEach { $0.stop() }
        cameraFeeds = [:]
        dockView.cameraViews = [:]
    }

    /// Starts and drops feeds so the running set matches what the user ticked. Membership is the only
    /// thing compared, so the 500 ms telemetry refresh never restarts a live stream, and folding the
    /// strip does not either: the pictures are merely hidden. That is why unfolding shows a live image
    /// at once instead of a reconnect, and it is also the cost: a ticked printer streams for as long
    /// as the strip is on screen, which on a Bambu machine occupies its only camera slot.
    private func syncCameras(entries: [EdgeDockEntry], settings: AppSettings) {
        var wanted: Set<String> = []
        if Build.hasExtras && settings.edgeDockCamera {
            // Brands without a stream Gantry can decode would get a black rectangle, so they are
            // never candidates; their tick is hidden in Settings for the same reason.
            let candidates = entries.map(\.serial).filter { serial in
                CameraFeedController.supportsCamera(store.printers.first(where: { $0.serial == serial })?.kind)
            }
            let chosen = candidates.filter(settings.edgeDockCameraSerials.contains)
            // Nothing ticked yet: follow the print that is actually running, so switching the camera
            // on does something instead of nothing. Ticking printers replaces this entirely.
            wanted = chosen.isEmpty ? Set(activePrint(among: candidates, in: entries).map { [$0] } ?? [])
                                    : Set(chosen)
        }
        guard wanted != Set(cameraFeeds.keys) else { return }
        for (serial, feed) in cameraFeeds where !wanted.contains(serial) {
            feed.stop()
            cameraFeeds[serial] = nil
        }
        for serial in wanted where cameraFeeds[serial] == nil {
            let feed = CameraFeedController(store: store, serial: serial)
            feed.view.cornerRadius = EdgeDockView.pictureRadius
            // The strip has room for two words on a plate, not for the detail view's instructions.
            feed.compactStatus = true
            cameraFeeds[serial] = feed
            feed.start()
        }
        dockView.cameraViews = cameraFeeds.mapValues(\.view)
    }

    private func cameraState(for serial: String) -> EdgeDockCamera {
        guard Build.hasExtras else { return .hidden }
        if cameraFeeds[serial] != nil { return .live }
        let kind = store.printers.first(where: { $0.serial == serial })?.kind
        return CameraFeedController.supportsCamera(kind) ? .previewOff : .noCamera
    }

    /// The printer worth watching when the user has not named one: printing beats paused, and with a
    /// single candidate it is simply that one. Several idle machines give nothing, because picking one
    /// of them silently would be a guess rather than an answer.
    private func activePrint(among candidates: [String], in entries: [EdgeDockEntry]) -> String? {
        let live = entries.filter { candidates.contains($0.serial) }
        if let printing = live.first(where: { $0.state == .printing }) { return printing.serial }
        if let paused = live.first(where: { $0.state == .paused }) { return paused.serial }
        return live.count == 1 ? live[0].serial : nil
    }

    /// Pins the panel flush to the chosen edge of the chosen display, at the chosen height. The side uses
    /// `frame` rather than `visibleFrame` so it really touches the edge instead of stopping at the Dock;
    /// being at `.statusBar` level it simply floats over anything in the way. It used to follow
    /// the screen holding the key window, so with two displays it wandered between them.
    private func reposition(animated: Bool = false) {
        let settings = AppSettings.shared
        let displays = EdgeDockPlacement.connectedDisplays()
        guard let resolved = EdgeDockPlacement.resolve(displays: displays, savedID: settings.edgeDockDisplayID,
                                                       savedFrame: EdgeDockPlacement.parseFrame(settings.edgeDockDisplayFrame))
        else { return }
        rememberDisplay(resolved.display, matched: resolved.matched)
        dockView.dwellBeforeUnfold = EdgeDockPlacement.isInnerEdge(resolved.display, edge: dockView.edge, among: displays)
        // The open strip fits itself to this height rather than running off the display.
        dockView.availableHeight = resolved.display.visibleFrame.height
        let size = dockView.preferredSize()
        let origin = EdgeDockPlacement.origin(size: size, frame: resolved.display.frame,
                                              visibleFrame: resolved.display.visibleFrame,
                                              edge: dockView.edge, row: settings.edgeDockRow)
        let frame = NSRect(origin: origin, size: size)
        guard panel.frame != frame else { return }
        // Unfolding and folding are the only size changes worth animating. A telemetry refresh can
        // also change the width, by a few points when a remaining time gains a digit, and animating
        // that would make the strip breathe for no reason.
        guard animated, panel.isVisible else {
            // ...but it must not land in the middle of an unfold. `panel.frame` reports the in-flight
            // frame during an animation, so an unconditional setFrame here saw a difference and
            // snapped straight to the end. With telemetry arriving every 500 ms and the unfold taking
            // 260, that cut the animation short almost every time, which is why there appeared to be
            // none. The animation is already heading for this state; the next refresh trims the width.
            if unfoldingUntil.map({ $0 > Date() }) == true { return }
            panel.setFrame(frame, display: true)
            return
        }
        unfoldingUntil = Date().addingTimeInterval(EdgeDockView.unfoldDuration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = EdgeDockView.unfoldDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// A chosen display found under a new id, or at a new size, is saved as it is now, so the next
    /// lookup finds it at once. The fallback to the main display writes nothing: the choice stays.
    private func rememberDisplay(_ display: EdgeDockDisplay, matched: Bool) {
        let settings = AppSettings.shared
        guard matched, !settings.edgeDockDisplayID.isEmpty else { return }
        let frame = EdgeDockPlacement.formatFrame(display.frame)
        if settings.edgeDockDisplayID != display.id { settings.edgeDockDisplayID = display.id }
        if settings.edgeDockDisplayFrame != frame { settings.edgeDockDisplayFrame = frame }
    }


}

/// Borderless panels refuse key status by default, which is what we want: clicking the strip must not
/// steal focus from whatever the user is typing in.
private final class EdgeDockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct EdgeDockEntry: Equatable {
    let serial: String
    let name: String
    let state: PrinterState
    let progress: Int
    let remainingMinutes: Int?
    var camera: EdgeDockCamera = .hidden
}

/// What an open printer block shows besides its caption (contract edgeDock.captions).
enum EdgeDockCamera: Equatable {
    /// A live picture, with the caption under it. A picture that stops arriving keeps its place and
    /// says so on its own plate, while the caption keeps following telemetry.
    case live
    /// The printer has a camera Gantry can show, but its preview is not on in the strip.
    case previewOff
    /// A brand without a stream Gantry can decode.
    case noCamera
    /// No camera features in this edition, so nothing to say about one.
    case hidden
}

private final class EdgeDockView: NSView {
    /// Telemetry arrives twice a second whether or not it changed anything the strip shows, so the
    /// comparison is what keeps an idle fleet from redrawing, re-measuring and re-masking for ever.
    var entries: [EdgeDockEntry] = [] {
        didSet {
            guard entries != oldValue else { return }
            invalidateMeasurements()
            needsLayout = true
            needsDisplay = true
        }
    }
    var edge: EdgeDockEdge = .right {
        didSet {
            guard edge != oldValue else { return }
            needsDisplay = true
        }
    }
    var scale: CGFloat = 1 {
        didSet {
            guard abs(scale - oldValue) > 0.001 else { return }
            invalidateMeasurements()
            onLayoutChange?(false)
            needsLayout = true
            needsDisplay = true
        }
    }
    /// Pinned means permanently unfolded: hover stops being what decides the width.
    var pinned = false {
        didSet {
            guard pinned != oldValue else { return }
            onLayoutChange?(true)
            needsLayout = true
            needsDisplay = true
        }
    }
    /// Live pictures by serial, handed in by the controller. Each one is drawn directly under its own
    /// printer's row, so which machine an image belongs to needs no caption.
    var cameraViews: [String: NSView] = [:] {
        didSet {
            guard Set(cameraViews.keys) != Set(oldValue.keys) else { return }
            for (serial, view) in oldValue where cameraViews[serial] !== view {
                view.removeFromSuperview()
            }
            for view in cameraViews.values where view.superview !== self {
                view.translatesAutoresizingMaskIntoConstraints = true
                addSubview(view)
            }
            // One frosted band per picture, directly above it and under the caption.
            for (serial, blur) in captionBlurs where cameraViews[serial] == nil {
                blur.removeFromSuperview()
                captionBlurs[serial] = nil
            }
            for (serial, view) in cameraViews where captionBlurs[serial] == nil {
                let blur = NSVisualEffectView()
                blur.blendingMode = .withinWindow
                blur.material = .hudWindow
                blur.state = .active
                blur.wantsLayer = true
                blur.layer?.masksToBounds = true
                blur.isHidden = true
                addSubview(blur, positioned: .above, relativeTo: view)
                captionBlurs[serial] = blur
            }
            // The captions over the pictures stay above every picture added since.
            overlayView.frame = bounds
            addSubview(overlayView, positioned: .above, relativeTo: nil)
            invalidateMeasurements()
            onLayoutChange?(false)
            needsLayout = true
            needsDisplay = true
        }
    }
    var onSelect: ((String) -> Void)?
    /// `true` asks the host to animate the size change rather than snap to it.
    var onLayoutChange: ((Bool) -> Void)?
    var onTogglePin: (() -> Void)?
    var onSettings: (() -> Void)?
    /// The frosted backdrop this strip clips to its own silhouette.
    weak var backdrop: NSVisualEffectView?

    private var isHovering = false
    private var isExpanded: Bool { pinned || isHovering }
    private var trackingArea: NSTrackingArea?
    private var collapseTimer: Timer?
    /// On an edge shared with another display the pointer crosses the strip on its way over, so there
    /// the strip unfolds only once the pointer has stayed a moment. An outer edge stops the pointer by
    /// itself and still unfolds at once.
    var dwellBeforeUnfold = false
    private var dwellTimer: Timer?
    /// 0 folded, 1 unfolded. Read off the window's own width rather than kept on a clock of its own.
    /// There used to be a second animation here, a 60 Hz timer running the same curve alongside the
    /// window's resize, and the two disagreed: the window is driven by the display link, so on a
    /// 120 Hz panel it stepped twice as often and the floor, the labels and the blur trailed it by up
    /// to a frame. The strip was also redrawn 71 times for 42 real width changes. Derived, they cannot
    /// drift, the drawing happens once per change, and the transition literally follows the scale.
    private var unfoldProgress: CGFloat = 0 {
        didSet { updateTransitionBlur() }
    }
    private var captionBlurs: [String: NSVisualEffectView] = [:]
    private lazy var overlayView: EdgeDockOverlayView = {
        let view = EdgeDockOverlayView()
        view.owner = self
        view.autoresizingMask = [.width, .height]
        return view
    }()
    /// Draws the settings button outside the backdrop's mask; see the controller's init.
    lazy var settingsButtonView: NSView = {
        let view = EdgeDockSettingsView()
        view.owner = self
        view.autoresizingMask = [.width, .height]
        return view
    }()
    private lazy var rowsView: EdgeDockRowsView = {
        let view = EdgeDockRowsView()
        view.owner = self
        view.autoresizingMask = [.width, .height]
        return view
    }()

    /// The window resizes the content view, which resizes us, so this is the one hook that sees every
    /// frame of the unfold without asking anybody when the next one is due.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncUnfoldProgress()
    }

    private func syncUnfoldProgress() {
        let folded = Self.collapsedWidth * scale
        let span = max(1, expandedWidth() - folded)
        let progress = min(1, max(0, (bounds.width - folded) / span))
        guard abs(progress - unfoldProgress) > 0.001 else { return }
        unfoldProgress = progress
        needsDisplay = true
    }

    // Geometry. The strip is deliberately narrow: at rest a printer is one 14 pt ring and nothing else.
    private static let ring: CGFloat = 14
    private static let ringStroke: CGFloat = 2
    private static let collapsedWidth: CGFloat = 22
    private static let collapsedGap: CGFloat = 8
    private static let padY: CGFloat = 8
    private static let notch: CGFloat = 11
    /// Band above the rows holding the pin. Present whenever the strip is open, pinned or not, because
    /// it is also where a hovering user pins it; a folded strip keeps exactly the height it had.
    private static let pinRow: CGFloat = 14
    private static let pinGap: CGFloat = 10
    /// Extra room under the last printer of an open strip, so its note clears the rounded bottom corner.
    private static let expandedBottomPad: CGFloat = 8
    private static let pinGlyph: CGFloat = 10
    /// The settings button under the strip. At rest it is only a quarter arc tucked into the pocket the
    /// bottom fillet makes, running parallel to it, so it says "there is something here" without
    /// competing with the rings. On hover the same circle fills in and takes a gear: one object waking
    /// up rather than one icon swapped for another. The circle is the fillet's own, so the disc exactly
    /// fills the pocket and, on a folded strip, the strip's whole width. (After codenotch's orb, MIT.)
    private static let orbArcGap: CGFloat = 2
    private static let orbStroke: CGFloat = 3
    private static let orbGlyph: CGFloat = 12
    /// Room under the bottom fillet for the lower half of the disc.
    private static let orbBand: CGFloat = 14
    private static let orbHoverDuration: TimeInterval = 0.18
    private static let orbSpinDuration: TimeInterval = 0.5
    /// The pin, in a 16x16 design box, upright with the needle down: a flat head, a shaft, a flared
    /// collar and the needle. The same points on Windows and Linux (contract edgeDock.pinControl).
    static let pinPoints: [(CGFloat, CGFloat)] = [
        (5, 1.5), (11, 1.5), (11, 3), (9.8, 3), (9.8, 7), (12.5, 9.5), (8.7, 9.5),
        (8, 15), (7.3, 9.5), (3.5, 9.5), (6.2, 7), (6.2, 3), (5, 3)
    ]
    /// Released, the pin leans over; pinned, it stands straight in.
    static let pinReleasedAngle: CGFloat = 45
    /// One number for both halves of the gesture: the window's own resize and the fade of the rows
    /// inside it. They have to agree, or the text would settle before the strip stops moving.
    static let unfoldDuration: TimeInterval = 0.42
    /// Grace period before folding, long enough to outlast the unfold animation's own leave event.
    private static let collapseDelay: TimeInterval = 0.44
    /// Open, every printer is one block in a single column. A printer with a picture is just the picture,
    /// with the name on the leading side and the percentage, time and ring at the end laid over its bottom
    /// edge on a soft dark fade, so a camera costs no more height than its image. A printer without one is
    /// its caption on the strip's dark floor plus one line saying why. A hairline separates neighbours
    /// (contract edgeDock.captions).
    fileprivate static let pictureRadius: CGFloat = 8
    private static let insetX: CGFloat = 10
    private static let captionMinHeight: CGFloat = 28
    private static let captionPadY: CGFloat = 4
    private static let captionInnerGap: CGFloat = 5
    private static let wrappedLineGap: CGFloat = 1
    private static let statusRow: CGFloat = 16
    private static let statusIcon: CGFloat = 12
    private static let printerGap: CGFloat = 8
    private static let overlayShade: CGFloat = 44
    private static let overlayShadeAlpha: CGFloat = 0.38
    /// A band of frosted glass under the caption that fades in from its top edge, so the text reads on a
    /// bright bed as well as a dark one while the picture above it stays uncovered.
    private static let captionBlurHeight: CGFloat = 40
    private static let overlayPadX: CGFloat = 8
    private static let separatorAlpha: CGFloat = 0.12
    /// A long name gives the strip at most this much of its width before it wraps instead.
    private static let nameWidthCap: CGFloat = 120
    /// Pictures shrink to no less than this share of the strip before they give way to a note.
    private static let minimumPictureShare: CGFloat = 0.55
    private static let pictureShareStep: CGFloat = 0.02
    /// Room kept free above and below an open strip on its display.
    private static let screenMargin: CGFloat = 16
    /// The camera glyph in a 12x12 design box, y down: body rectangle, then the lens.
    static let cameraGlyphBody = NSRect(x: 1, y: 3, width: 7.5, height: 6)
    static let cameraGlyphLens: [(CGFloat, CGFloat)] = [(8.5, 5), (11, 3.5), (11, 8.5), (8.5, 7)]
    /// A 16:9 picture this narrow is already a squint; below this the strip is not worth the pixels.
    private static let cameraMinStripWidth: CGFloat = 236
    private static let cameraMaxStripWidth: CGFloat = 300

    private var nameFont: NSFont { .systemFont(ofSize: 13 * scale, weight: .semibold) }
    private var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 11 * scale, weight: .regular) }
    private var statusFont: NSFont { .systemFont(ofSize: 11 * scale) }
    /// The dark floor over the blur, at full strength. How much of it is actually used comes from the
    /// panel-transparency setting, because that is the only honest place for this trade-off: a thick
    /// floor hides the frost, a thin one costs text contrast. The labels carry a shadow so the thin
    /// end stays readable, and the value colour moved up from `muted` to `secondary` for the same
    /// reason. Measured on a pure white desktop, the worst case: at 0.86 the value text clears 6:1,
    /// at 0.68 it is near 3:1 and leans on the shadow.
    private static let shapeColor = NSColor(srgbRed: 0.031, green: 0.035, blue: 0.043, alpha: 1)

    /// The floor thins as the strip opens, so the glass visibly clears instead of arriving already
    /// frosted. Folded it is as solid as it always was, which also keeps the bare rings crisp; fully
    /// open it reaches whatever the panel-transparency setting asks for. This is the blur actually
    /// animating: there is no blur radius to tune on a `.behindWindow` effect view, so what changes
    /// is how much of it is allowed through.
    private var currentFloorAlpha: CGFloat {
        let open = AppSettings.shared.panelTransparency.edgeDockFloorAlpha
        let fade = max(0, min(1, unfoldProgress))
        return Self.foldedFloorAlpha + (open - Self.foldedFloorAlpha) * fade
    }
    private static let foldedFloorAlpha: CGFloat = 0.96

    /// A soft dark halo under the labels. This is what lets the floor be thin enough to see the blur
    /// through; without it the names would smear into a bright desktop showing through the frost.
    /// One object per size rather than a new one per label per frame: the attributed strings only read
    /// it, and it changes with nothing but `scale`.
    private var labelShadow: NSShadow {
        if let shadowCache, abs(shadowCache.scale - scale) < 0.001 { return shadowCache.shadow }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
        shadow.shadowBlurRadius = 3 * scale
        shadow.shadowOffset = .zero
        shadowCache = (scale, shadow)
        return shadow
    }

    /// Window size for the current state. Height always includes one fillet radius above and below the
    /// visible body, because that is where the concave transitions are drawn.
    func preferredSize() -> NSSize {
        let count = max(entries.count, 1)
        if isExpanded {
            let width = expandedWidth()
            return NSSize(width: width,
                          height: (Self.padY * 2 + Self.expandedBottomPad) * scale + pinBandHeight
                                  + expandedContentHeight(stripWidth: width)
                                  + Self.notch * 2 * scale + orbBandHeight)
        }
        let body = (Self.padY * 2 + CGFloat(count) * Self.ring
                    + CGFloat(count - 1) * Self.collapsedGap) * scale
        return NSSize(width: Self.collapsedWidth * scale, height: body + Self.notch * 2 * scale + orbBandHeight)
    }

    /// Measuring text is the one genuinely slow thing the strip does, and the unfold now asks for this
    /// width on every frame to know how far along it is. Everything feeding it changes only when the
    /// fleet, the pictures or the size setting do, so it is computed then and not 120 times a second.
    private var expandedWidthCache: CGFloat?
    private var shadowCache: (scale: CGFloat, shadow: NSShadow)?
    private var pinHovered = false

    /// The silhouette cache is deliberately not cleared here: its key already carries everything the
    /// shape depends on, so it invalidates itself and a language change never re-rasterises a mask.
    fileprivate func invalidateMeasurements() {
        expandedWidthCache = nil
        shadowCache = nil
        planCache = nil
    }

    private func expandedWidth() -> CGFloat {
        if let expandedWidthCache { return expandedWidthCache }
        let width = measureExpandedWidth()
        expandedWidthCache = width
        return width
    }

    private func measureExpandedWidth() -> CGFloat {
        var widest: CGFloat = 0
        let nameFont = self.nameFont, valueFont = self.valueFont
        for entry in entries {
            // A long name wraps rather than widening the strip, so only its first stretch counts.
            let name = min((entry.name as NSString).size(withAttributes: [.font: nameFont]).width,
                           Self.nameWidthCap * scale)
            let value = (valueText(entry) as NSString).size(withAttributes: [.font: valueFont]).width
            widest = max(widest, name + value)
        }
        let content = (Self.insetX * 2 + Self.captionInnerGap * 2 + Self.ring) * scale + widest
        // With a picture the strip stops being sized by its printer names: the image needs a usable
        // width of its own, so it raises the floor and lifts the ceiling. Without one it still keeps
        // room for a one-line note such as "Preview off".
        let showsAny = entries.contains { cameraViews[$0.serial] != nil }
        let minimum = (showsAny ? Self.cameraMinStripWidth : 180) * scale
        let maximum = (showsAny ? Self.cameraMaxStripWidth : 260) * scale
        return min(max(content, minimum), maximum)
    }

    /// One place that decides the expanded silhouette, so measuring it, drawing it, framing the
    /// pictures and hit-testing clicks cannot drift apart. Offsets run downward from the content top.
    private struct RowMetric {
        let entry: EdgeDockEntry
        let blockTop: CGFloat
        let blockHeight: CGFloat
        let pictureWidth: CGFloat     // 0 when no picture is shown
        let pictureHeight: CGFloat
        let captionTop: CGFloat
        let captionHeight: CGFloat
        let wraps: Bool               // name on its own lines, the metrics under it
        let overlay: Bool             // the caption is laid over the bottom of the picture
        let nameHeight: CGFloat
        let note: String?             // the line under the caption, when there is no picture
    }

    private struct Plan {
        let rows: [RowMetric]
        let height: CGFloat
    }

    /// Height of the display the strip sits on, set by the controller before it asks for a size.
    var availableHeight: CGFloat = .greatestFiniteMagnitude {
        didSet { if abs(availableHeight - oldValue) > 0.5 { planCache = nil } }
    }
    private var planCache: (key: PlanKey, plan: Plan)?
    private struct PlanKey: Equatable {
        let entries: [EdgeDockEntry], cameras: Set<String>, width: CGFloat, scale: CGFloat,
            available: CGFloat, edge: EdgeDockEdge
    }

    private func rowMetrics(stripWidth: CGFloat) -> (rows: [RowMetric], height: CGFloat) {
        let key = PlanKey(entries: entries, cameras: Set(cameraViews.keys), width: stripWidth, scale: scale,
                          available: availableHeight, edge: edge)
        if let planCache, planCache.key == key { return (planCache.plan.rows, planCache.plan.height) }
        let plan = fittedPlan(stripWidth: stripWidth)
        planCache = (key, plan)
        return (plan.rows, plan.height)
    }

    /// The column at full size when it fits the display; otherwise, in this order, smaller pictures,
    /// pictures replaced by a note, the notes dropped, and last the strip cut at the display's height.
    /// The order of the printers never changes.
    private func fittedPlan(stripWidth: CGFloat) -> Plan {
        let chrome = (Self.notch * 2 + Self.padY * 2 + Self.expandedBottomPad + Self.pinRow + Self.pinGap
                      + Self.orbBand + Self.screenMargin * 2) * scale
        let limit = max(Self.captionMinHeight * scale, availableHeight - chrome)
        let full = plan(stripWidth: stripWidth, pictureShare: 1, pictures: true, notes: true)
        guard full.height > limit else { return full }
        let pictureTotal = full.rows.reduce(0) { $0 + $1.pictureHeight }
        if pictureTotal > 0 {
            // Pictures are whole points, so the first estimate can land a point or two over; step down.
            var share = 1 - (full.height - limit) / pictureTotal
            while share >= Self.minimumPictureShare {
                let smaller = plan(stripWidth: stripWidth, pictureShare: share, pictures: true, notes: true)
                if smaller.height <= limit { return smaller }
                share -= Self.pictureShareStep
            }
        }
        let noPictures = plan(stripWidth: stripWidth, pictureShare: 1, pictures: false, notes: true)
        if noPictures.height <= limit { return noPictures }
        let bare = plan(stripWidth: stripWidth, pictureShare: 1, pictures: false, notes: false)
        return Plan(rows: bare.rows, height: min(bare.height, limit))
    }

    private func plan(stripWidth: CGFloat, pictureShare: CGFloat, pictures: Bool, notes: Bool) -> Plan {
        let content = max(0, stripWidth - Self.insetX * 2 * scale)
        let pictureWidth = (content * pictureShare).rounded()
        let pictureHeight = (pictureWidth * 9 / 16).rounded()
        let textWidth = max(0, content - (Self.ring + Self.captionInnerGap) * scale)
        let nameLine = lineHeight(nameFont), valueLine = lineHeight(valueFont)
        var rows: [RowMetric] = []
        var offset: CGFloat = 0
        for (index, entry) in entries.enumerated() {
            let showsPicture = pictures && entry.camera == .live && cameraViews[entry.serial] != nil && content > 0
            var note: String?
            if notes, !showsPicture {
                switch entry.camera {
                case .live: note = AppSettings.shared.t("Not enough room for the preview")
                case .previewOff: note = AppSettings.shared.t("Preview off")
                case .noCamera: note = AppSettings.shared.t("No camera")
                case .hidden: note = nil
                }
            }
            if showsPicture {
                // Over a picture the caption is one line: a long name is cut with an ellipsis instead.
                let caption = Self.captionMinHeight * scale
                rows.append(RowMetric(entry: entry, blockTop: offset, blockHeight: pictureHeight,
                                      pictureWidth: pictureWidth, pictureHeight: pictureHeight,
                                      captionTop: offset + pictureHeight - caption, captionHeight: caption,
                                      wraps: false, overlay: true, nameHeight: nameLine, note: nil))
                offset += pictureHeight
                if index < entries.count - 1 { offset += (Self.printerGap * 2 * scale + 1) }
                continue
            }
            let nameWidth = (entry.name as NSString).size(withAttributes: [.font: nameFont]).width
            let valueWidth = (valueText(entry) as NSString).size(withAttributes: [.font: valueFont]).width
            let wraps = nameWidth + Self.captionInnerGap * scale + valueWidth > textWidth
            let nameHeight = wraps
                ? ceil((entry.name as NSString).boundingRect(
                    with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin], attributes: [.font: nameFont]).height)
                : nameLine
            let textHeight = wraps ? nameHeight + Self.wrappedLineGap * scale + valueLine : max(nameLine, valueLine)
            let caption = max(Self.captionMinHeight * scale, textHeight + Self.captionPadY * 2 * scale)
            let block = caption + (note != nil ? Self.statusRow * scale : 0)
            rows.append(RowMetric(entry: entry, blockTop: offset, blockHeight: block,
                                  pictureWidth: 0, pictureHeight: 0,
                                  captionTop: offset, captionHeight: caption,
                                  wraps: wraps, overlay: false, nameHeight: nameHeight, note: note))
            offset += block
            if index < entries.count - 1 { offset += (Self.printerGap * 2 * scale + 1) }
        }
        return Plan(rows: rows, height: offset)
    }

    private func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    private func expandedContentHeight(stripWidth: CGFloat) -> CGFloat {
        guard !entries.isEmpty else { return Self.captionMinHeight * scale }
        return rowMetrics(stripWidth: stripWidth).height
    }

    /// y of the top of the first text row, in view coordinates.
    private var contentTop: CGFloat {
        bounds.height - (Self.notch + Self.padY) * scale - pinBandHeight
    }

    /// Height the pin and its gap add to the body: always while open, never while folded.
    private var pinBandHeight: CGFloat {
        isExpanded ? (Self.pinRow + Self.pinGap) * scale : 0
    }

    /// Height of the band under the silhouette that holds the settings button, folded or open.
    private var orbBandHeight: CGFloat { Self.orbBand * scale }

    /// The bottom fillet's centre, on the screen edge's side: the circle the button is drawn on.
    private var orbCenter: NSPoint {
        let r = Self.notch * scale
        return NSPoint(x: edge == .right ? bounds.width - r : r, y: orbBandHeight)
    }

    private func orbContains(_ point: NSPoint) -> Bool {
        let c = orbCenter
        return hypot(point.x - c.x, point.y - c.y) <= Self.notch * scale + 2
    }

    /// Below the body: the fillet's pocket and the band under it. The pointer here is on its way to
    /// the button, so it must not unfold a folded strip.
    private func isBelowBody(_ point: NSPoint) -> Bool {
        point.y < orbBandHeight + Self.notch * scale
    }

    private var orbHover: CGFloat = 0
    private var orbHoverTarget: CGFloat = 0
    private var orbSpin: CGFloat = 0
    private var orbSpinStarted: Date?
    private var orbTimer: Timer?

    private func setOrbHovered(_ hovered: Bool) {
        let target: CGFloat = hovered ? 1 : 0
        guard target != orbHoverTarget else { return }
        orbHoverTarget = target
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            orbHover = target
            needsDisplay = true
            return
        }
        startOrbTimer()
    }

    private func spinOrb() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        orbSpinStarted = Date()
        startOrbTimer()
    }

    private func startOrbTimer() {
        guard orbTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepOrb() }
        }
        RunLoop.main.add(timer, forMode: .common)
        orbTimer = timer
    }

    private func stepOrb() {
        let step = CGFloat(1.0 / 60 / Self.orbHoverDuration)
        if orbHover < orbHoverTarget { orbHover = min(orbHoverTarget, orbHover + step) }
        else if orbHover > orbHoverTarget { orbHover = max(orbHoverTarget, orbHover - step) }
        if let started = orbSpinStarted {
            let t = min(1, Date().timeIntervalSince(started) / Self.orbSpinDuration)
            orbSpin = 360 * CGFloat(1 - pow(1 - t, 3))
            if t >= 1 { orbSpin = 0; orbSpinStarted = nil }
        }
        needsDisplay = true
        if orbHover == orbHoverTarget && orbSpinStarted == nil {
            orbTimer?.invalidate()
            orbTimer = nil
        }
    }

    /// Resting: the quarter of the circle that faces back along the strip and out to the screen edge,
    /// in the strip's own colour. Hovered: the whole disc with a gear that turns into place.
    fileprivate func drawSettingsOrb() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let center = orbCenter
        let radius = Self.notch * scale
        let eased = orbHover * orbHover * (3 - 2 * orbHover)
        let color = Self.shapeColor.withAlphaComponent(Self.foldedFloorAlpha)
        if eased < 1 {
            context.saveGState()
            context.setAlpha(1 - eased)
            let shrink = 1 - 0.14 * eased
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: shrink, y: shrink)
            let arcRadius = radius - (Self.orbArcGap + Self.orbStroke / 2) * scale
            let arc = NSBezierPath()
            // Twelve o'clock round to the screen edge.
            if edge == .right {
                arc.appendArc(withCenter: .zero, radius: arcRadius, startAngle: 90, endAngle: 0, clockwise: true)
            } else {
                arc.appendArc(withCenter: .zero, radius: arcRadius, startAngle: 90, endAngle: 180, clockwise: false)
            }
            arc.lineWidth = Self.orbStroke * scale
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
            context.restoreGState()
        }
        guard eased > 0 else { return }
        context.saveGState()
        context.setAlpha(eased)
        let discRadius = radius * (1.1 - 0.1 * eased)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - discRadius, y: center.y - discRadius,
                                    width: discRadius * 2, height: discRadius * 2)).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let rim = NSBezierPath(ovalIn: NSRect(x: center.x - discRadius + 0.5, y: center.y - discRadius + 0.5,
                                              width: discRadius * 2 - 1, height: discRadius * 2 - 1))
        rim.lineWidth = 1
        rim.stroke()
        // Arrives from sixty degrees back, and a click adds a full turn on top.
        let size = Self.orbGlyph * scale * (0.5 + 0.5 * eased)
        let gear = Self.gearPath(center: center, size: size, angleDegrees: -60 * (1 - eased) + orbSpin)
        gear.lineWidth = 1.2 * scale
        gear.lineJoinStyle = .round
        GantryTheme.text.setStroke()
        gear.stroke()
        context.restoreGState()
    }

    /// The gear on the settings button, in a box `size` wide: eight teeth, the root circle at 72 % of the
    /// tip, each tooth 34 % of its period wide at the tip and 60 % at the root, and a hole of 32 %. Drawn
    /// rather than an SF Symbol, so it is the same shape on Windows and GNU/Linux (contract
    /// edgeDock.settingsButton). Turned clockwise as seen on screen.
    static let gearTeeth = 8
    static let gearRoot: CGFloat = 0.72
    static let gearTipSpan: CGFloat = 0.17
    static let gearRootSpan: CGFloat = 0.30
    static let gearHole: CGFloat = 0.32

    static func gearPath(center: NSPoint, size: CGFloat, angleDegrees: CGFloat) -> NSBezierPath {
        let tip = size / 2, root = size / 2 * gearRoot
        let period = 2 * CGFloat.pi / CGFloat(gearTeeth)
        let turn = angleDegrees * .pi / 180
        let path = NSBezierPath()
        var first = true
        for tooth in 0..<gearTeeth {
            let middle = CGFloat(tooth) * period + turn
            for (radius, offset) in [(root, -gearRootSpan), (tip, -gearTipSpan), (tip, gearTipSpan), (root, gearRootSpan)] {
                let angle = middle + offset * period
                // y-down design angle, flipped onto AppKit's y-up canvas.
                let point = NSPoint(x: center.x + radius * cos(angle), y: center.y - radius * sin(angle))
                if first { path.move(to: point); first = false } else { path.line(to: point) }
            }
        }
        path.close()
        let hole = size / 2 * gearHole
        path.appendOval(in: NSRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))
        return path
    }

    /// The pin control: a disc with the pin on it, sitting in the ring column so it can never collide
    /// with a printer name, whatever the name's length.
    private func pinButtonRect() -> NSRect? {
        guard isExpanded else { return nil }
        let side = Self.pinRow * scale
        let centerX = ringX
        let centerY = bounds.height - (Self.notch + Self.padY) * scale - side / 2
        return NSRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side)
    }

    /// Released: a faint disc and a hollow pin leaning over. Pinned: a brighter disc and a solid pin
    /// standing straight in. Hover lifts the disc either way. Drawn as a path, not an SF Symbol, so it
    /// is the same shape as on Windows and Linux and costs nothing to redraw on every unfold frame.
    private func drawPinButton() {
        guard let rect = pinButtonRect() else { return }
        let fade = max(0, min(1, unfoldProgress))
        let discAlpha = (pinned ? 0.18 : 0.06) + (pinHovered ? 0.08 : 0)
        NSColor.white.withAlphaComponent(discAlpha * fade).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let glyph = Self.pinPath(center: NSPoint(x: rect.midX, y: rect.midY), size: Self.pinGlyph * scale,
                                 angleDegrees: pinned ? 0 : Self.pinReleasedAngle)
        if pinned {
            GantryTheme.text.withAlphaComponent(fade).setFill()
            glyph.fill()
        } else {
            glyph.lineWidth = 1.3 * Self.pinGlyph * scale / 16
            glyph.lineJoinStyle = .round
            GantryTheme.secondary.withAlphaComponent(fade).setStroke()
            glyph.stroke()
        }
    }

    /// The pin's points placed at `center`, `size` wide, rotated clockwise as seen on screen. The design
    /// box is y-down like Windows and cairo, so y is flipped here and only here.
    static func pinPath(center: NSPoint, size: CGFloat, angleDegrees: CGFloat) -> NSBezierPath {
        let scale = size / 16
        let theta = angleDegrees * .pi / 180
        let cosine = cos(theta), sine = sin(theta)
        let path = NSBezierPath()
        for (index, point) in pinPoints.enumerated() {
            let dx = point.0 - 8, dy = point.1 - 8
            let placed = NSPoint(x: center.x + (dx * cosine - dy * sine) * scale,
                                 y: center.y - (dx * sine + dy * cosine) * scale)
            if index == 0 { path.move(to: placed) } else { path.line(to: placed) }
        }
        path.close()
        return path
    }

    /// Ring column: at the end of the caption, on the physical screen edge's side, and the pin above it.
    private var ringX: CGFloat {
        let inset = (Self.insetX + Self.ring / 2) * scale
        return edge == .right ? bounds.width - inset : inset
    }

    /// The pictures are real subviews inside a hand-drawn silhouette, so they get framed here rather
    /// than by constraints: each one directly under its printer's row, horizontally centred. While the
    /// strip is collapsed they are hidden but their streams keep running, so unfolding it shows a live
    /// picture at once instead of a reconnect.
    /// Clips the frosted backdrop to the strip's outline. Without this the blur would be a rectangle
    /// with the silhouette merely painted inside it, and the concave fillets would sit on a frosted
    /// square. Runs on every layout pass, so the outline keeps up while the panel animates open.
    /// Everything the outline depends on. A layout pass runs for reasons that leave the shape alone
    /// too, a camera picture arriving or a row's remaining time gaining a digit, and handing the
    /// effect view a mask makes the window server recompute the whole behind-window blur region.
    private struct MaskKey: Equatable {
        let width: CGFloat, height: CGFloat, scale: CGFloat, edge: EdgeDockEdge, backing: CGFloat
    }
    private var maskKey: MaskKey?

    private func clipBackdropToSilhouette() {
        guard let backdrop, bounds.width > 0, bounds.height > 0 else { return }
        let backing = window?.backingScaleFactor ?? 2
        let key = MaskKey(width: bounds.width, height: bounds.height,
                          scale: scale, edge: edge, backing: backing)
        guard key != maskKey else { return }
        guard let mask = silhouetteMask(size: bounds.size, backing: backing) else { return }
        maskKey = key
        backdrop.maskImage = mask
    }

    /// Rasterised here and now, at the screen's own resolution. `NSImage(size:flipped:drawingHandler:)`
    /// draws lazily, which meant the effect view paid for the fill at some later point in the frame
    /// and did so again every time it needed the mask at another scale.
    private func silhouetteMask(size: NSSize, backing: CGFloat) -> NSImage? {
        let pixels = NSSize(width: (size.width * backing).rounded(.up),
                            height: (size.height * backing).rounded(.up))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The effect view reads the mask's alpha, so outside the outline has to stay genuinely empty
        // rather than merely black; a fresh bitmap starts as undefined bytes, not as transparent.
        context.cgContext.clear(CGRect(origin: .zero, size: pixels))
        context.cgContext.scaleBy(x: backing, y: backing)
        NSColor.black.setFill()
        shapePath(in: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        let mask = NSImage(size: size)
        mask.addRepresentation(rep)
        mask.capInsets = NSEdgeInsets()   // 1:1 with the window, never stretched
        return mask
    }

    override func layout() {
        super.layout()
        clipBackdropToSilhouette()
        rowsView.frame = bounds
        overlayView.frame = bounds
        removeAllToolTips()
        if let pin = pinButtonRect() {
            addToolTip(pin, owner: AppSettings.shared.t("Keep the strip open") as NSString, userData: nil)
        }
        let r = Self.notch * scale
        addToolTip(NSRect(x: orbCenter.x - r, y: orbCenter.y - r, width: r * 2, height: r * 2),
                   owner: AppSettings.shared.t("Strip settings") as NSString, userData: nil)
        guard !cameraViews.isEmpty else { return }
        guard isExpanded else {
            cameraViews.values.forEach { $0.isHidden = true }
            captionBlurs.values.forEach { $0.isHidden = true }
            return
        }
        var placed: Set<String> = []
        for metric in rowMetrics(stripWidth: bounds.width).rows {
            guard let view = cameraViews[metric.entry.serial] else { continue }
            guard metric.pictureHeight > 0, contentTop - metric.blockTop - metric.pictureHeight >= orbBandHeight else {
                view.isHidden = true
                captionBlurs[metric.entry.serial]?.isHidden = true
                continue
            }
            view.isHidden = false
            // Centred in the column, so a picture shrunk to fit a small display stays under its caption.
            let frame = NSRect(x: ((bounds.width - metric.pictureWidth) / 2).rounded(),
                               y: contentTop - metric.blockTop - metric.pictureHeight,
                               width: metric.pictureWidth, height: metric.pictureHeight)
            // A live picture is a layer that reflows when its frame is set, so setting the same frame
            // again on every layout pass is pure cost. Most passes during an unfold move it, but the
            // ones telemetry and camera frames cause do not.
            if view.frame != frame { view.frame = frame }
            if let blur = captionBlurs[metric.entry.serial] {
                let band = NSRect(x: frame.minX, y: frame.minY, width: frame.width,
                                  height: min(frame.height, Self.captionBlurHeight * scale))
                if blur.frame != band {
                    blur.frame = band
                    blur.maskImage = Self.captionBandMask(size: band.size, radius: Self.pictureRadius * scale)
                }
                blur.isHidden = false
            }
            placed.insert(metric.entry.serial)
        }
        // A picture whose printer dropped out of the strip this refresh has no row to sit under.
        for (serial, view) in cameraViews where !placed.contains(serial) {
            view.isHidden = true
            captionBlurs[serial]?.isHidden = true
        }
    }

    private static let finishTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short   // respects the system 12/24-hour setting
        formatter.dateStyle = .none
        return formatter
    }()

    private func valueText(_ entry: EdgeDockEntry) -> String {
        let settings = AppSettings.shared
        switch entry.state {
        case .printing, .paused:
            // Both halves, as on the fleet cards: how long is left and the clock time it ends. "1:16"
            // on its own read as a time of day.
            if let minutes = entry.remainingMinutes, minutes > 0 {
                let left = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
                let finish = Self.finishTimeFormatter.string(from: Date().addingTimeInterval(Double(minutes) * 60))
                return "\(entry.progress)% · \(left) · \(finish)"
            }
            return "\(entry.progress)%"
        case .finished: return settings.t("done")
        case .idle: return settings.t("idle")
        case .error: return settings.t("error")
        case .offline: return settings.t("offline")
        }
    }

    // MARK: Shape

    /// The silhouette: a rounded body flush against the screen edge, plus a concave fillet at each end
    /// so the strip appears to flow out of the edge rather than sit next to it.
    private func shapePath() -> NSBezierPath { shapePath(in: bounds.size) }
    #if GANTRY_RENDER
    func silhouetteForRender() -> NSBezierPath { shapePath() }
    func settingsHoverForRender(_ value: CGFloat) { orbHover = value; orbHoverTarget = value }
    #endif

    private func shapePath(in size: NSSize) -> NSBezierPath {
        // Drawn on the window above the settings band, then lifted onto it.
        let band = orbBandHeight
        let w = size.width, h = size.height - band
        let r = min(Self.notch * scale, w)
        let bodyRadius = min(w / 2, 12 * scale)
        let top = h - r, bottom = r
        let path = NSBezierPath()
        path.move(to: NSPoint(x: w, y: h))
        path.appendArc(withCenter: NSPoint(x: w - r, y: h), radius: r, startAngle: 0, endAngle: -90, clockwise: true)
        path.line(to: NSPoint(x: bodyRadius, y: top))
        path.appendArc(withCenter: NSPoint(x: bodyRadius, y: top - bodyRadius), radius: bodyRadius,
                       startAngle: 90, endAngle: 180, clockwise: false)
        path.line(to: NSPoint(x: 0, y: bottom + bodyRadius))
        path.appendArc(withCenter: NSPoint(x: bodyRadius, y: bottom + bodyRadius), radius: bodyRadius,
                       startAngle: 180, endAngle: 270, clockwise: false)
        path.line(to: NSPoint(x: w - r, y: bottom))
        path.appendArc(withCenter: NSPoint(x: w - r, y: 0), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        path.close()
        path.transform(using: AffineTransform(translationByX: 0, byY: band))
        if edge == .left {
            var mirror = AffineTransform(translationByX: w, byY: 0)
            mirror.scale(x: -1, y: 1)
            path.transform(using: mirror)
        }
        return path
    }

    /// Only the silhouette. Everything inside it is drawn by `rowsView`, which carries the transition
    /// blur; blurring it here would soften the strip's own edges and bleed them outside the shape.
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        Self.shapeColor.withAlphaComponent(currentFloorAlpha).setFill()
        shapePath().fill()
    }

    /// The contents of the strip, called by `rowsView` in its own drawing pass.
    fileprivate func drawRows() {
        guard !entries.isEmpty else { return }
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        if isExpanded {
            drawPinButton()
            drawExpanded()
        } else {
            drawCollapsed()
        }
    }

    /// Core Image blur on the rows, strongest halfway through the gesture and gone at both rest
    /// states, so neither the folded strip nor the open one is ever left soft. This is the part that
    /// follows the window's scale: the same progress drives the width, the labels' opacity and this.
    private func updateTransitionBlur() {
        let progress = max(0, min(1, unfoldProgress))
        let strength = sin(CGFloat.pi * progress)
        guard strength > 0.01 else {
            // Nothing to blur at either rest state, and an empty chain is what lets the layer go back
            // to being composited directly instead of through an offscreen pass.
            if !rowsView.contentFilters.isEmpty { rowsView.contentFilters = [] }
            return
        }
        let radius = strength * Self.transitionBlurRadius * scale
        guard let blur = transitionBlur else { return }
        // Assigning `contentFilters` tears the layer's filter chain down and builds it again, which is
        // not what you want 120 times a second. Named once, the radius can be poked straight into the
        // live chain instead, and the layer keeps the render target it already has.
        if rowsView.contentFilters.isEmpty {
            blur.setValue(radius, forKey: kCIInputRadiusKey)
            rowsView.contentFilters = [blur]
            return
        }
        rowsView.layer?.setValue(radius, forKeyPath: "filters.\(Self.transitionBlurName).inputRadius")
    }

    private lazy var transitionBlur: CIFilter? = {
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.name = Self.transitionBlurName
        return blur
    }()
    private static let transitionBlurName = "gantryDockUnfoldBlur"
    /// Peak radius at the middle of the gesture, in points before the strip's own scale.
    private static let transitionBlurRadius: CGFloat = 7

    private func drawCollapsed() {
        var y = bounds.height - (Self.notch + Self.padY + Self.ring / 2) * scale
        for entry in entries {
            drawRing(center: NSPoint(x: bounds.midX, y: y), entry: entry)
            y -= (Self.ring + Self.collapsedGap) * scale
        }
    }

    private func drawExpanded() {
        let fade = max(0, min(1, unfoldProgress))
        let rows = rowMetrics(stripWidth: bounds.width).rows
        let bottomLimit = (Self.notch + Self.padY) * scale + orbBandHeight
        for (index, metric) in rows.enumerated() {
            // A strip cut at the display's height draws only what is inside it.
            guard contentTop - metric.captionTop - metric.captionHeight >= bottomLimit - 1 else { break }
            // Captions over pictures are drawn by `overlayView`, above the pictures.
            if !metric.overlay { drawCaption(metric, fade: fade) }
            if let note = metric.note { drawNote(note, metric: metric, fade: fade) }
            guard index < rows.count - 1 else { continue }
            let y = (contentTop - metric.blockTop - metric.blockHeight - Self.printerGap * scale).rounded() - 0.5
            let inset = Self.insetX * scale
            NSColor.white.withAlphaComponent(Self.separatorAlpha * fade).setFill()
            NSRect(x: inset, y: y, width: max(0, bounds.width - inset * 2), height: 1).fill()
        }
    }

    /// Transparent at the top, solid at the bottom, with the picture's own rounded bottom corners.
    private static func captionBandMask(size: NSSize, radius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
            path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                           startAngle: 180, endAngle: 270)
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                           startAngle: 270, endAngle: 360)
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.close()
            path.addClip()
            NSGradient(colors: [.black, .black, NSColor.black.withAlphaComponent(0)],
                       atLocations: [0, 0.45, 1], colorSpace: .deviceRGB)?.draw(in: rect, angle: 90)
            return true
        }
    }

    /// The fade and caption over the bottom of each picture. Called by `overlayView`, which sits above
    /// the pictures.
    fileprivate func drawPictureCaptions() {
        guard isExpanded else { return }
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        let fade = max(0, min(1, unfoldProgress))
        for metric in rowMetrics(stripWidth: bounds.width).rows where metric.overlay {
            guard let view = cameraViews[metric.entry.serial], !view.isHidden else { continue }
            let picture = view.frame
            let shade = NSRect(x: picture.minX, y: picture.minY, width: picture.width,
                               height: min(picture.height, Self.overlayShade * scale))
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: picture, xRadius: Self.pictureRadius * scale,
                         yRadius: Self.pictureRadius * scale).addClip()
            NSGradient(starting: NSColor.black.withAlphaComponent(Self.overlayShadeAlpha * fade),
                       ending: NSColor.black.withAlphaComponent(0))?.draw(in: shade, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
            drawCaption(metric, fade: fade)
        }
    }

    /// Name on the leading side, then the percentage and time, then the ring at the end. A name that
    /// does not fit next to its metrics wraps onto as many lines as it needs, and the metrics move to
    /// the line under it. On a left-edge strip the order is mirrored, so the ring stays by the edge.
    private func drawCaption(_ metric: RowMetric, fade: CGFloat) {
        let entry = metric.entry
        let top = contentTop - metric.captionTop
        let centerY = top - metric.captionHeight / 2
        // Over a picture the caption keeps to the picture's own edges, which move when it shrinks to fit.
        let left: CGFloat, right: CGFloat
        if metric.overlay {
            let pictureLeft = ((bounds.width - metric.pictureWidth) / 2).rounded()
            left = pictureLeft + Self.overlayPadX * scale
            right = pictureLeft + metric.pictureWidth - Self.overlayPadX * scale
        } else {
            left = Self.insetX * scale
            right = bounds.width - Self.insetX * scale
        }
        let ringX = edge == .right ? right - Self.ring / 2 * scale : left + Self.ring / 2 * scale
        drawRing(center: NSPoint(x: ringX, y: centerY), entry: entry)

        let dim = entry.state == .idle || entry.state == .offline || entry.state == .finished
        let nameColor = entry.state == .error || entry.state == .offline ? GantryTheme.statusError
                      : (dim ? GantryTheme.secondary : GantryTheme.text)
        let halo = labelShadow
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let name = NSAttributedString(string: entry.name,
                                      attributes: [.font: nameFont, .paragraphStyle: paragraph,
                                                   .foregroundColor: nameColor.withAlphaComponent(fade),
                                                   .shadow: halo])
        let value = NSAttributedString(string: valueText(entry),
                                       attributes: [.font: valueFont,
                                                    .foregroundColor: (metric.overlay ? GantryTheme.text : GantryTheme.secondary)
                                                        .withAlphaComponent(fade),
                                                    .shadow: halo])
        let ringSpan = (Self.ring + Self.captionInnerGap) * scale
        let textLeft = edge == .right ? left : left + ringSpan
        let textRight = edge == .right ? right - ringSpan : right
        let valueSize = value.size()
        if metric.wraps {
            let valueLine = lineHeight(valueFont)
            let block = metric.nameHeight + Self.wrappedLineGap * scale + valueLine
            let blockTop = centerY + block / 2
            name.draw(with: NSRect(x: textLeft, y: blockTop - metric.nameHeight,
                                   width: max(0, textRight - textLeft), height: metric.nameHeight),
                      options: [.usesLineFragmentOrigin])
            value.draw(at: NSPoint(x: textLeft, y: blockTop - block))
        } else {
            let nameHeight = lineHeight(nameFont)
            name.draw(with: NSRect(x: textLeft, y: centerY - nameHeight / 2,
                                   width: max(0, textRight - valueSize.width - Self.captionInnerGap * scale - textLeft),
                                   height: nameHeight),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            value.draw(at: NSPoint(x: textRight - valueSize.width, y: centerY - valueSize.height / 2))
        }
    }

    /// The line under a caption that has no picture: a camera glyph, struck through when the printer
    /// has none, and a few words.
    private func drawNote(_ note: String, metric: RowMetric, fade: CGFloat) {
        let top = contentTop - metric.captionTop - metric.captionHeight
        let centerY = top - Self.statusRow * scale / 2 + 1 * scale
        let ringSpan = (Self.ring + Self.captionInnerGap) * scale
        let left = edge == .right ? Self.insetX * scale : Self.insetX * scale + ringSpan
        let color = GantryTheme.secondary.withAlphaComponent(fade)
        drawCameraGlyph(origin: NSPoint(x: left, y: centerY + Self.statusIcon * scale / 2),
                        struck: metric.entry.camera == .noCamera, color: color)
        let text = NSAttributedString(string: note, attributes: [.font: statusFont, .foregroundColor: color,
                                                                 .shadow: labelShadow])
        let size = text.size()
        text.draw(at: NSPoint(x: left + (Self.statusIcon + Self.captionInnerGap) * scale, y: centerY - size.height / 2))
    }

    /// `origin` is the glyph box's top-left corner; the design box is y-down, so y is flipped here.
    private func drawCameraGlyph(origin: NSPoint, struck: Bool, color: NSColor) {
        let unit = Self.statusIcon * scale / 12
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin.x + x * unit, y: origin.y - y * unit) }
        let body = Self.cameraGlyphBody
        let bodyRect = NSRect(x: origin.x + body.minX * unit, y: origin.y - body.maxY * unit,
                              width: body.width * unit, height: body.height * unit)
        let path = NSBezierPath(roundedRect: bodyRect, xRadius: 1.5 * unit, yRadius: 1.5 * unit)
        let lens = NSBezierPath()
        for (index, corner) in Self.cameraGlyphLens.enumerated() {
            if index == 0 { lens.move(to: point(corner.0, corner.1)) } else { lens.line(to: point(corner.0, corner.1)) }
        }
        lens.close()
        path.append(lens)
        if struck {
            path.move(to: point(1, 1.5))
            path.line(to: point(11, 10.5))
        }
        path.lineWidth = 1.1 * unit
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// One progress ring: a dim track plus an arc that starts at twelve o'clock and runs clockwise.
    /// Offline and error draw a broken ring instead, so a dead printer never looks like a stalled one.
    private func drawRing(center: NSPoint, entry: EdgeDockEntry) {
        let radius = (Self.ring - Self.ringStroke) * scale / 2
        let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
        track.lineWidth = Self.ringStroke * scale

        switch entry.state {
        case .error, .offline:
            GantryTheme.statusError.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 2 * scale, y: center.y - 2 * scale,
                                                 width: 4 * scale, height: 4 * scale))
            GantryTheme.statusError.setFill()
            dot.fill()
            return
        case .idle, .finished:
            NSColor.white.withAlphaComponent(0.16).setStroke()
            track.stroke()
            if entry.state == .finished {
                GantryTheme.statusFinished.setStroke()
                track.stroke()
            }
            return
        case .printing, .paused:
            break
        }

        NSColor.white.withAlphaComponent(0.16).setStroke()
        track.stroke()
        let fraction = min(max(Double(entry.progress) / 100, 0), 1)
        guard fraction > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
        arc.lineWidth = Self.ringStroke * scale
        arc.lineCapStyle = .round
        (entry.state == .paused ? GantryTheme.statusPaused : GantryTheme.statusPrinting).setStroke()
        arc.stroke()
    }

    // MARK: Interaction

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard rowsView.superview !== self else { return }
        rowsView.frame = bounds
        // Below everything added later, so a camera picture is never behind the rows it belongs to.
        addSubview(rowsView, positioned: .below, relativeTo: nil)
    }

    /// Every `needsDisplay = true` in this class funnels through here, so the rows redraw with the
    /// silhouette instead of needing their own invalidation at a dozen call sites.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        rowsView.needsDisplay = true
        overlayView.needsDisplay = true
        settingsButtonView.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeAlways` matters: the strip must react while another app is frontmost.
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        collapseTimer?.invalidate()
        collapseTimer = nil
        let point = convert(event.locationInWindow, from: nil)
        setOrbHovered(orbContains(point))
        guard !isBelowBody(point) else { return }
        pointerReachedBody()
    }

    private func pointerReachedBody() {
        guard !isHovering, dwellTimer == nil else { return }
        guard dwellBeforeUnfold, !pinned else {
            beginHover()
            return
        }
        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: EdgeDockPlacement.innerEdgeDwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dwellTimer = nil
                // Still here after the dwell: a stop, not a pass on the way to the next display.
                if let frame = self.window?.frame, frame.contains(NSEvent.mouseLocation) { self.beginHover() }
            }
        }
    }

    private func beginHover() {
        guard !isHovering else { return }
        isHovering = true
        guard !pinned else { return }   // already unfolded, nothing to re-lay out
        onLayoutChange?(true)
        needsDisplay = true
    }

    /// Folding waits a moment and then checks where the pointer actually is. While the strip animates
    /// open its edge travels under the cursor, and a window that moves out from under the pointer emits
    /// a leave event even though the user has not moved: acting on that immediately would fold the
    /// strip, which puts the edge back under the cursor, which opens it again. This is the same loop
    /// the Windows port hit in issue #32, where it showed up as flicker.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setOrbHovered(orbContains(point))
        if !isBelowBody(point) { pointerReachedBody() }
        let over = pinButtonRect()?.contains(point) ?? false
        guard over != pinHovered else { return }
        pinHovered = over
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        dwellTimer?.invalidate()
        dwellTimer = nil
        setOrbHovered(false)
        if pinHovered {
            pinHovered = false
            needsDisplay = true
        }
        guard isHovering else { return }
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: Self.collapseDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapseIfPointerLeft() }
        }
    }

    private func collapseIfPointerLeft() {
        collapseTimer = nil
        // NSEvent.mouseLocation is screen-absolute and therefore right even mid-animation, unlike the
        // tracking area, whose rect belongs to a size the window may have already left behind.
        if let frame = window?.frame, frame.contains(NSEvent.mouseLocation) { return }
        guard isHovering else { return }
        isHovering = false
        guard !pinned else { return }
        onLayoutChange?(true)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if orbContains(point) {
            spinOrb()
            onSettings?()
            return
        }
        // The pin wins over the row beneath it.
        if let pin = pinButtonRect(), pin.contains(point) {
            onTogglePin?()
            return
        }
        guard let index = rowIndex(at: point), index < entries.count else { return }
        onSelect?(entries[index].serial)
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        // A click on a picture is not a click on its printer, except on the caption over its bottom.
        for view in cameraViews.values where !view.isHidden && view.frame.contains(point)
            && point.y > view.frame.minY + Self.captionMinHeight * scale { return nil }
        guard isExpanded else {
            let step = (Self.ring + Self.collapsedGap) * scale
            let offset = bounds.height - (Self.notch + Self.padY) * scale - point.y
            guard offset >= 0 else { return nil }
            let index = Int(offset / step)
            return index >= 0 && index < entries.count ? index : nil
        }
        // Expanded, a printer is its block: the caption and its note open it, and so does the gap
        // around its hairline, so a click between two printers still lands somewhere sensible. Its
        // picture does not, which the check at the top already settled.
        let rows = rowMetrics(stripWidth: bounds.width).rows
        let gap = Self.printerGap * scale
        for (index, metric) in rows.enumerated() {
            let blockTop = contentTop - metric.blockTop + (index == 0 ? 0 : gap)
            let claimed = metric.blockHeight + gap * (index == 0 ? 1 : 2) + 1
            if point.y <= blockTop && point.y > blockTop - claimed { return index }
        }
        return nil
    }
}

/// The strip's contents on their own layer. Split from `EdgeDockView` for one reason: the transition
/// blur has to apply to the rings, labels and pin without touching the silhouette, whose edges would
/// otherwise soften and bleed outside the shape. It draws nothing of its own and takes no clicks.
/// The captions over the pictures: above every picture, drawing nothing else and taking no clicks.
private final class EdgeDockOverlayView: NSView {
    weak var owner: EdgeDockView?

    override func draw(_ dirtyRect: NSRect) { owner?.drawPictureCaptions() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

private final class EdgeDockSettingsView: NSView {
    weak var owner: EdgeDockView?

    override func draw(_ dirtyRect: NSRect) { owner?.drawSettingsOrb() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

private final class EdgeDockRowsView: NSView {
    weak var owner: EdgeDockView?

    override func draw(_ dirtyRect: NSRect) { owner?.drawRows() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

#if GANTRY_RENDER
/// Offscreen picture of the open strip for design review: silhouette, tiles, rows and stand-in
/// pictures over a sample desktop, at the panel-transparency setting in the defaults. The window
/// server's behind-window blur cannot be captured, so the desktop shows through unblurred.
@MainActor enum EdgeDockRender {
    static func image(entries: [EdgeDockEntry], pictures: [String: NSImage], edge: EdgeDockEdge,
                      desktop: NSImage, expanded: Bool = true, settingsHover: CGFloat = 0) -> NSImage? {
        let view = EdgeDockView(frame: .zero)
        view.edge = edge
        view.pinned = expanded
        view.settingsHoverForRender(settingsHover)
        view.entries = entries
        view.cameraViews = pictures.mapValues { _ in NSView() }
        let size = view.preferredSize()
        view.frame = NSRect(origin: .zero, size: size)
        view.viewDidMoveToSuperview()
        view.layoutSubtreeIfNeeded()
        view.layout()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let result = NSImage(size: size)
        result.lockFocus()
        NSGraphicsContext.saveGraphicsState()
        view.silhouetteForRender().addClip()   // the desktop shows through only inside the strip
        desktop.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: false, hints: nil)
        for (serial, picture) in pictures {
            guard let frame = view.cameraViews[serial]?.frame, !(view.cameraViews[serial]?.isHidden ?? true) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: EdgeDockView.pictureRadius, yRadius: EdgeDockView.pictureRadius).addClip()
            picture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        view.drawPictureCaptions()
        view.drawSettingsOrb()
        result.unlockFocus()
        return result
    }
}
#endif
