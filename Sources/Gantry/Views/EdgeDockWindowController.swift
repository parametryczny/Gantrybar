import AppKit
import Combine

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
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.unfoldDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Short enough to feel like a response to the pointer rather than a transition of its own.
    private static let unfoldDuration: TimeInterval = 0.18
}

/// Borderless panels refuse key status by default, which is what we want: clicking the strip must not
/// steal focus from whatever the user is typing in.
private final class EdgeDockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct EdgeDockEntry {
    let serial: String
    let name: String
    let state: PrinterState
    let progress: Int
    let remainingMinutes: Int?
}

private final class EdgeDockView: NSView {
    var entries: [EdgeDockEntry] = [] { didSet { needsLayout = true; needsDisplay = true } }
    var edge: EdgeDockEdge = .right { didSet { needsDisplay = true } }
    var scale: CGFloat = 1 {
        didSet {
            guard abs(scale - oldValue) > 0.001 else { return }
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
    /// Grace period before folding, long enough to outlast the unfold animation's own leave event.
    private static let collapseDelay: TimeInterval = 0.2
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

    /// A soft dark halo under the labels. This is what lets the floor be thin enough to see the blur
    /// through; without it the names would smear into a bright desktop showing through the frost.
    private var labelShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
        shadow.shadowBlurRadius = 3 * scale
        shadow.shadowOffset = .zero
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

    private func expandedWidth() -> CGFloat {
        var widest: CGFloat = 0
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
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.pinGlyph * scale, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [GantryTheme.secondary]))
        guard let glyph = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = glyph.size
        glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
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
    private func clipBackdropToSilhouette() {
        guard let backdrop, bounds.width > 0, bounds.height > 0 else { return }
        let size = bounds.size
        let outline = shapePath()
        let mask = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            outline.fill()
            return true
        }
        mask.capInsets = NSEdgeInsets()   // 1:1 with the window, never stretched
        backdrop.maskImage = mask
    }

    override func layout() {
        super.layout()
        clipBackdropToSilhouette()
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
            view.frame = NSRect(x: x,
                                y: contentTop - metric.top - metric.height
                                   - Self.cameraGap * scale - metric.cameraHeight,
                                width: width, height: metric.cameraHeight)
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
    private func shapePath() -> NSBezierPath {
        let w = bounds.width, h = bounds.height
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

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        Self.shapeColor
            .withAlphaComponent(AppSettings.shared.panelTransparency.edgeDockFloorAlpha)
            .setFill()
        shapePath().fill()
        guard !entries.isEmpty else { return }
        if isExpanded {
            drawPinButton()
            drawExpanded()
        } else {
            drawCollapsed()
        }
    }

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
            let name = NSAttributedString(string: entry.name,
                                          attributes: [.font: nameFont, .foregroundColor: nameColor,
                                                       .shadow: halo])
            let value = NSAttributedString(string: valueText(entry),
                                           attributes: [.font: valueFont,
                                                        .foregroundColor: GantryTheme.secondary,
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
