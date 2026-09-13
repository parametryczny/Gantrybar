import AppKit
import Combine
import CoreImage

/// A narrow always-on-top strip that grows out of a screen edge, showing one progress ring per
/// printer. Collapsed it is 22 points wide and carries only colour and fill; hovering expands it into
/// a list with names, percentages and remaining time, and clicking a row opens that printer's details.
///
/// Issue #34 added two things to that. Pinning keeps the list unfolded without the pointer, and a
/// pinned strip can be released from the strip itself. Separately, any printer can be given a live
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

    init(store: PrinterStore, onSelect: @escaping (String) -> Void) {
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
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Frosted glass under the silhouette. `.behindWindow` blurs the desktop, and the strip's own
        // fill sits on top of it as a dark floor, so the blur is visible without the rows losing
        // their contrast to whatever happens to be behind the strip.
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.material = .hudWindow
        backdrop.wantsLayer = true
        panel.contentView = backdrop
        dockView.frame = backdrop.bounds
        dockView.autoresizingMask = [.width, .height]
        backdrop.addSubview(dockView)
        // The view that knows the silhouette also keeps the blur clipped to it, on every layout pass,
        // so the frost follows the shape while the panel is still animating open.
        dockView.backdrop = backdrop

        dockView.onSelect = onSelect
        dockView.onLayoutChange = { [weak self] animated in self?.reposition(animated: animated) }
        // Releasing the strip belongs on the strip: reaching Settings to undo something you can see
        // is the long way round. Writing the setting is enough to drive the rest, because the
        // settings subscription below brings us straight back into refresh().
        dockView.onUnpin = { AppSettings.shared.edgeDockPinned = false }

        // The store publishes on every telemetry packet; throttling keeps the strip from redrawing
        // several times a second for a bar that moves once a minute.
        subscription = store.objectWillChange
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }
        settingsSubscription = AppSettings.shared.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        // Resolution changes and display hot-plugs move the edge, so the strip has to be re-pinned.
        screenSubscription = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } }
        refresh()
    }

    func refresh() {
        let settings = AppSettings.shared
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
        dockView.entries = entries
        syncCameras(entries: entries, settings: settings)
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
            feed.view.cornerRadius = 8
            cameraFeeds[serial] = feed
            feed.start()
        }
        dockView.cameraViews = cameraFeeds.mapValues(\.view)
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

    /// Pins the panel flush to the chosen edge of the screen holding the menu bar, vertically centred.
    /// Uses `frame` rather than `visibleFrame` so it really touches the edge instead of stopping at the
    /// Dock; being at `.statusBar` level it simply floats over anything in the way.
    private func reposition(animated: Bool = false) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = dockView.preferredSize()
        let y = screen.frame.midY - size.height / 2
        let x = dockView.edge == .right ? screen.frame.maxX - size.width : screen.frame.minX
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
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
            invalidateMeasurements()
            onLayoutChange?(false)
            needsLayout = true
            needsDisplay = true
        }
    }
    var onSelect: ((String) -> Void)?
    /// `true` asks the host to animate the size change rather than snap to it.
    var onLayoutChange: ((Bool) -> Void)?
    var onUnpin: (() -> Void)?
    /// The frosted backdrop this strip clips to its own silhouette.
    weak var backdrop: NSVisualEffectView?

    private var isHovering = false
    private var isExpanded: Bool { pinned || isHovering }
    private var trackingArea: NSTrackingArea?
    private var collapseTimer: Timer?
    /// 0 folded, 1 unfolded. Read off the window's own width rather than kept on a clock of its own.
    /// There used to be a second animation here, a 60 Hz timer running the same curve alongside the
    /// window's resize, and the two disagreed: the window is driven by the display link, so on a
    /// 120 Hz panel it stepped twice as often and the floor, the labels and the blur trailed it by up
    /// to a frame. The strip was also redrawn 71 times for 42 real width changes. Derived, they cannot
    /// drift, the drawing happens once per change, and the transition literally follows the scale.
    private var unfoldProgress: CGFloat = 0 {
        didSet { updateTransitionBlur() }
    }
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
    private static let rowHeight: CGFloat = 20
    private static let rowGap: CGFloat = 2
    private static let padY: CGFloat = 8
    private static let notch: CGFloat = 11
    private static let expandedTextGap: CGFloat = 8
    private static let expandedPadX: CGFloat = 11
    /// Band above the rows holding the release control. Present only while pinned, so the hover
    /// silhouette keeps exactly the height it always had.
    private static let pinRow: CGFloat = 14
    private static let pinGap: CGFloat = 4
    private static let pinGlyph: CGFloat = 10
    /// One number for both halves of the gesture: the window's own resize and the fade of the rows
    /// inside it. They have to agree, or the text would settle before the strip stops moving.
    static let unfoldDuration: TimeInterval = 0.42
    /// Grace period before folding, long enough to outlast the unfold animation's own leave event.
    private static let collapseDelay: TimeInterval = 0.44
    private static let cameraGap: CGFloat = 8
    /// A 16:9 picture this narrow is already a squint; below this the strip is not worth the pixels.
    private static let cameraMinStripWidth: CGFloat = 236
    private static let cameraMaxStripWidth: CGFloat = 300

    private var nameFont: NSFont { .systemFont(ofSize: 11 * scale, weight: .semibold) }
    private var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 11 * scale, weight: .regular) }
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
                          height: Self.padY * 2 * scale + pinBandHeight
                                  + expandedContentHeight(stripWidth: width)
                                  + Self.notch * 2 * scale)
        }
        let body = (Self.padY * 2 + CGFloat(count) * Self.ring
                    + CGFloat(count - 1) * Self.collapsedGap) * scale
        return NSSize(width: Self.collapsedWidth * scale, height: body + Self.notch * 2 * scale)
    }

    /// Measuring text is the one genuinely slow thing the strip does, and the unfold now asks for this
    /// width on every frame to know how far along it is. Everything feeding it changes only when the
    /// fleet, the pictures or the size setting do, so it is computed then and not 120 times a second.
    private var expandedWidthCache: CGFloat?
    private var shadowCache: (scale: CGFloat, shadow: NSShadow)?
    private var pinGlyphCache: (scale: CGFloat, glyph: NSImage)?

    /// The silhouette cache is deliberately not cleared here: its key already carries everything the
    /// shape depends on, so it invalidates itself and a language change never re-rasterises a mask.
    fileprivate func invalidateMeasurements() {
        expandedWidthCache = nil
        shadowCache = nil
        pinGlyphCache = nil
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
            let name = (entry.name as NSString).size(withAttributes: [.font: nameFont]).width
            let value = (valueText(entry) as NSString).size(withAttributes: [.font: valueFont]).width
            widest = max(widest, name + value)
        }
        let content = (Self.expandedPadX * 2 + Self.ring + Self.expandedTextGap + 14) * scale + widest
        // With a picture the strip stops being sized by its longest printer name: the image needs a
        // usable width of its own, so it raises the floor and lifts the ceiling.
        let showsAny = entries.contains { cameraViews[$0.serial] != nil }
        let minimum = (showsAny ? Self.cameraMinStripWidth : 150) * scale
        let maximum = (showsAny ? Self.cameraMaxStripWidth : 260) * scale
        return min(max(content, minimum), maximum)
    }

    /// One place that decides the expanded silhouette, so measuring it, drawing it, framing the
    /// pictures and hit-testing clicks cannot drift apart. Offsets run downward from the content top.
    private struct RowMetric {
        let entry: EdgeDockEntry
        let top: CGFloat            // distance from the content top to the top of the text row
        let height: CGFloat         // the text row itself
        let cameraHeight: CGFloat   // 0 when this printer has no picture
    }

    private func rowMetrics(stripWidth: CGFloat) -> (rows: [RowMetric], height: CGFloat) {
        let pictureWidth = cameraWidth(stripWidth: stripWidth)
        let pictureHeight = (pictureWidth * 9 / 16).rounded()
        var rows: [RowMetric] = []
        var offset: CGFloat = 0
        for (index, entry) in entries.enumerated() {
            let camera = cameraViews[entry.serial] != nil && pictureWidth > 0 ? pictureHeight : 0
            rows.append(RowMetric(entry: entry, top: offset, height: Self.rowHeight * scale,
                                  cameraHeight: camera))
            offset += Self.rowHeight * scale
            if camera > 0 { offset += Self.cameraGap * scale + camera }
            if index < entries.count - 1 { offset += Self.rowGap * scale }
        }
        return (rows, offset)
    }

    private func expandedContentHeight(stripWidth: CGFloat) -> CGFloat {
        guard !entries.isEmpty else { return Self.rowHeight * scale }
        return rowMetrics(stripWidth: stripWidth).height
    }

    /// y of the top of the first text row, in view coordinates.
    private var contentTop: CGFloat {
        bounds.height - (Self.notch + Self.padY) * scale - pinBandHeight
    }

    /// Height the release control and its gap add to the body, or zero when the strip is not pinned.
    private var pinBandHeight: CGFloat {
        pinned ? (Self.pinRow + Self.pinGap) * scale : 0
    }

    /// The release control: a faint disc with a pin on it, sitting in the ring column so it can never
    /// collide with a printer name, whatever the name's length.
    private func pinButtonRect() -> NSRect? {
        guard pinned, isExpanded else { return nil }
        let side = Self.pinRow * scale
        let centerX = edge == .right
            ? bounds.width - (Self.expandedPadX + Self.ring / 2) * scale
            : (Self.expandedPadX + Self.ring / 2) * scale
        let centerY = bounds.height - (Self.notch + Self.padY) * scale - side / 2
        return NSRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side)
    }

    private func drawPinButton() {
        guard let rect = pinButtonRect() else { return }
        let fade = max(0, min(1, unfoldProgress))
        NSColor.white.withAlphaComponent(0.1 * fade).setFill()
        NSBezierPath(ovalIn: rect).fill()
        // Rendering an SF Symbol means looking it up and rasterising it, which is far too much work to
        // repeat on every frame of the unfold. The colour is baked in at full strength and the fade is
        // applied to the draw instead, so one glyph per size serves the whole gesture.
        guard let glyph = pinGlyph() else { return }
        let size = glyph.size
        glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: fade)
    }

    private func pinGlyph() -> NSImage? {
        if let pinGlyphCache, abs(pinGlyphCache.scale - scale) < 0.001 { return pinGlyphCache.glyph }
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.pinGlyph * scale, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [GantryTheme.secondary]))
        guard let glyph = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        pinGlyphCache = (scale, glyph)
        return glyph
    }

    private func cameraWidth(stripWidth: CGFloat) -> CGFloat {
        max(0, stripWidth - Self.expandedPadX * 2 * scale)
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
        guard !cameraViews.isEmpty else { return }
        guard isExpanded else {
            cameraViews.values.forEach { $0.isHidden = true }
            return
        }
        let width = cameraWidth(stripWidth: bounds.width)
        let x = ((bounds.width - width) / 2).rounded()
        var placed: Set<String> = []
        for metric in rowMetrics(stripWidth: bounds.width).rows {
            guard let view = cameraViews[metric.entry.serial] else { continue }
            guard metric.cameraHeight > 0, width > 0 else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            let frame = NSRect(x: x,
                               y: contentTop - metric.top - metric.height
                                  - Self.cameraGap * scale - metric.cameraHeight,
                               width: width, height: metric.cameraHeight)
            // A live picture is a layer that reflows when its frame is set, so setting the same frame
            // again on every layout pass is pure cost. Most passes during an unfold move it, but the
            // ones telemetry and camera frames cause do not.
            if view.frame != frame { view.frame = frame }
            placed.insert(metric.entry.serial)
        }
        // A picture whose printer dropped out of the strip this refresh has no row to sit under.
        for (serial, view) in cameraViews where !placed.contains(serial) { view.isHidden = true }
    }

    private func valueText(_ entry: EdgeDockEntry) -> String {
        let settings = AppSettings.shared
        switch entry.state {
        case .printing, .paused:
            if let minutes = entry.remainingMinutes, minutes > 0 {
                return "\(entry.progress)% · \(minutes / 60):\(String(format: "%02d", minutes % 60))"
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

    private func shapePath(in size: NSSize) -> NSBezierPath {
        let w = size.width, h = size.height
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
        // Keep the ring beside the physical screen edge while the text unfolds inward.
        let ringX = edge == .right
            ? bounds.width - (Self.expandedPadX + Self.ring / 2) * scale
            : (Self.expandedPadX + Self.ring / 2) * scale
        for metric in rowMetrics(stripWidth: bounds.width).rows {
            let entry = metric.entry
            let centerY = contentTop - metric.top - metric.height / 2
            drawRing(center: NSPoint(x: ringX, y: centerY), entry: entry)

            let dim = entry.state == .idle || entry.state == .offline || entry.state == .finished
            let nameColor = entry.state == .error || entry.state == .offline ? GantryTheme.statusError
                          : (dim ? GantryTheme.secondary : GantryTheme.text)
            let halo = labelShadow
            // The labels arrive with the strip rather than before it.
            let fade = max(0, min(1, unfoldProgress))
            let name = NSAttributedString(string: entry.name,
                                          attributes: [.font: nameFont,
                                                       .foregroundColor: nameColor.withAlphaComponent(fade),
                                                       .shadow: halo])
            let value = NSAttributedString(string: valueText(entry),
                                           attributes: [.font: valueFont,
                                                        .foregroundColor: GantryTheme.secondary.withAlphaComponent(fade),
                                                        .shadow: halo])
            let textLeft = edge == .right
                ? Self.expandedPadX * scale
                : ringX + (Self.ring / 2 + Self.expandedTextGap) * scale
            let textRight = edge == .right
                ? ringX - (Self.ring / 2 + Self.expandedTextGap) * scale
                : bounds.width - Self.expandedPadX * scale
            let valueSize = value.size()
            // Clip the name so a long one never runs under the value on the right.
            let nameBox = NSRect(x: textLeft, y: centerY - name.size().height / 2,
                                 width: max(0, textRight - valueSize.width - 8 * scale - textLeft),
                                 height: name.size().height)
            name.draw(with: nameBox, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            value.draw(at: NSPoint(x: textRight - valueSize.width, y: centerY - valueSize.height / 2))
        }
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
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeAlways` matters: the strip must react while another app is frontmost.
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        collapseTimer?.invalidate()
        collapseTimer = nil
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
    override func mouseExited(with event: NSEvent) {
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
        // The release control wins over the row beneath it.
        if let pin = pinButtonRect(), pin.contains(point) {
            onUnpin?()
            return
        }
        guard let index = rowIndex(at: point), index < entries.count else { return }
        onSelect?(entries[index].serial)
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        // A click on a picture is not a click on the row above it.
        for view in cameraViews.values where !view.isHidden && view.frame.contains(point) { return nil }
        guard isExpanded else {
            let step = (Self.ring + Self.collapsedGap) * scale
            let offset = bounds.height - (Self.notch + Self.padY) * scale - point.y
            guard offset >= 0 else { return nil }
            let index = Int(offset / step)
            return index >= 0 && index < entries.count ? index : nil
        }
        // Expanded rows are no longer a fixed pitch, because a picture may sit between two of them.
        // Walk the same metrics the drawing uses, and let each row own the gap below it so a click
        // between rows still lands somewhere sensible.
        let rows = rowMetrics(stripWidth: bounds.width).rows
        for (index, metric) in rows.enumerated() {
            let rowTop = contentTop - metric.top
            let claimed = metric.height + (metric.cameraHeight > 0
                ? Self.cameraGap * scale + metric.cameraHeight : 0) + Self.rowGap * scale
            if point.y <= rowTop && point.y > rowTop - claimed { return index }
        }
        return nil
    }
}

/// The strip's contents on their own layer. Split from `EdgeDockView` for one reason: the transition
/// blur has to apply to the rings, labels and pin without touching the silhouette, whose edges would
/// otherwise soften and bleed outside the shape. It draws nothing of its own and takes no clicks.
private final class EdgeDockRowsView: NSView {
    weak var owner: EdgeDockView?

    override func draw(_ dirtyRect: NSRect) { owner?.drawRows() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}
