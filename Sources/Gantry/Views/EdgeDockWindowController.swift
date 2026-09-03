import AppKit
import Combine

/// A narrow always-on-top strip that grows out of a screen edge, showing one progress ring per
/// printer. Collapsed it is 22 points wide and carries only colour and fill; hovering expands it into
/// a list with names, percentages and remaining time, and clicking a row opens that printer's details.
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
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var screenSubscription: AnyCancellable?

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
        panel.contentView = dockView

        dockView.onSelect = onSelect
        dockView.onLayoutChange = { [weak self] in self?.reposition() }

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
            panel.orderOut(nil)
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
            panel.orderOut(nil)
            return
        }
        dockView.edge = settings.edgeDockEdge
        dockView.entries = entries
        reposition()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Pins the panel flush to the chosen edge of the screen holding the menu bar, vertically centred.
    /// Uses `frame` rather than `visibleFrame` so it really touches the edge instead of stopping at the
    /// Dock; being at `.statusBar` level it simply floats over anything in the way.
    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = dockView.preferredSize()
        let y = screen.frame.midY - size.height / 2
        let x = dockView.edge == .right ? screen.frame.maxX - size.width : screen.frame.minX
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
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
    var entries: [EdgeDockEntry] = [] { didSet { needsDisplay = true } }
    var edge: EdgeDockEdge = .right { didSet { needsDisplay = true } }
    var onSelect: ((String) -> Void)?
    var onLayoutChange: (() -> Void)?

    private var isExpanded = false
    private var trackingArea: NSTrackingArea?

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

    private static let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let shapeColor = NSColor(srgbRed: 0.031, green: 0.035, blue: 0.043, alpha: 0.96)

    /// Window size for the current state. Height always includes one fillet radius above and below the
    /// visible body, because that is where the concave transitions are drawn.
    func preferredSize() -> NSSize {
        let count = max(entries.count, 1)
        if isExpanded {
            let body = Self.padY * 2 + CGFloat(count) * Self.rowHeight + CGFloat(count - 1) * Self.rowGap
            return NSSize(width: expandedWidth(), height: body + Self.notch * 2)
        }
        let body = Self.padY * 2 + CGFloat(count) * Self.ring + CGFloat(count - 1) * Self.collapsedGap
        return NSSize(width: Self.collapsedWidth, height: body + Self.notch * 2)
    }

    private func expandedWidth() -> CGFloat {
        var widest: CGFloat = 0
        for entry in entries {
            let name = (entry.name as NSString).size(withAttributes: [.font: Self.nameFont]).width
            let value = (valueText(entry) as NSString).size(withAttributes: [.font: Self.valueFont]).width
            widest = max(widest, name + value)
        }
        let content = Self.expandedPadX * 2 + Self.ring + Self.expandedTextGap + widest + 14
        return min(max(content, 150), 260)
    }

    private func valueText(_ entry: EdgeDockEntry) -> String {
        let settings = AppSettings.shared
        switch entry.state {
        case .printing, .paused:
            if let minutes = entry.remainingMinutes, minutes > 0 {
                return "\(entry.progress)% · \(minutes / 60):\(String(format: "%02d", minutes % 60))"
            }
            return "\(entry.progress)%"
        case .finished: return settings.text("gotowe", "done")
        case .idle: return settings.text("bezcz.", "idle")
        case .error: return settings.text("błąd", "error")
        case .offline: return settings.text("brak", "offline")
        }
    }

    // MARK: Shape

    /// The silhouette: a rounded body flush against the screen edge, plus a concave fillet at each end
    /// so the strip appears to flow out of the edge rather than sit next to it.
    private func shapePath() -> NSBezierPath {
        let w = bounds.width, h = bounds.height
        let r = min(Self.notch, w)
        let bodyRadius = min(w / 2, 12)
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
        Self.shapeColor.setFill()
        shapePath().fill()
        guard !entries.isEmpty else { return }
        if isExpanded { drawExpanded() } else { drawCollapsed() }
    }

    private func drawCollapsed() {
        var y = bounds.height - Self.notch - Self.padY - Self.ring / 2
        for entry in entries {
            drawRing(center: NSPoint(x: bounds.midX, y: y), entry: entry)
            y -= Self.ring + Self.collapsedGap
        }
    }

    private func drawExpanded() {
        var top = bounds.height - Self.notch - Self.padY
        let ringX = edge == .right ? Self.expandedPadX + Self.ring / 2 : bounds.width - Self.expandedPadX - Self.ring / 2
        for entry in entries {
            let centerY = top - Self.rowHeight / 2
            drawRing(center: NSPoint(x: ringX, y: centerY), entry: entry)

            let dim = entry.state == .idle || entry.state == .offline || entry.state == .finished
            let nameColor = entry.state == .error || entry.state == .offline ? GantryTheme.statusError
                          : (dim ? GantryTheme.secondary : GantryTheme.text)
            let name = NSAttributedString(string: entry.name,
                                          attributes: [.font: Self.nameFont, .foregroundColor: nameColor])
            let value = NSAttributedString(string: valueText(entry),
                                           attributes: [.font: Self.valueFont,
                                                        .foregroundColor: GantryTheme.muted])
            let textLeft = ringX + Self.ring / 2 + Self.expandedTextGap
            let textRight = bounds.width - Self.expandedPadX
            let valueSize = value.size()
            // Clip the name so a long one never runs under the value on the right.
            let nameBox = NSRect(x: textLeft, y: centerY - name.size().height / 2,
                                 width: max(0, textRight - valueSize.width - 8 - textLeft),
                                 height: name.size().height)
            name.draw(with: nameBox, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            value.draw(at: NSPoint(x: textRight - valueSize.width, y: centerY - valueSize.height / 2))

            top -= Self.rowHeight + Self.rowGap
        }
    }

    /// One progress ring: a dim track plus an arc that starts at twelve o'clock and runs clockwise.
    /// Offline and error draw a broken ring instead, so a dead printer never looks like a stalled one.
    private func drawRing(center: NSPoint, entry: EdgeDockEntry) {
        let radius = (Self.ring - Self.ringStroke) / 2
        let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
        track.lineWidth = Self.ringStroke

        switch entry.state {
        case .error, .offline:
            GantryTheme.statusError.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
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
        arc.lineWidth = Self.ringStroke
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
        guard !isExpanded else { return }
        isExpanded = true
        onLayoutChange?()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard isExpanded else { return }
        isExpanded = false
        onLayoutChange?()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point), index < entries.count else { return }
        onSelect?(entries[index].serial)
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        let step = isExpanded ? Self.rowHeight + Self.rowGap : Self.ring + Self.collapsedGap
        let top = bounds.height - Self.notch - Self.padY
        let offset = top - point.y
        guard offset >= 0 else { return nil }
        let index = Int(offset / step)
        return index >= 0 && index < entries.count ? index : nil
    }
}
