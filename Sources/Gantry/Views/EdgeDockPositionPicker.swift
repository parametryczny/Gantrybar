import AppKit

/// A small screen with the six places the strip can sit: three down each side. Clicking a square moves
/// the strip there. The same control, drawn the same way, in the Windows and GNU/Linux settings.
@MainActor
final class EdgeDockPositionPicker: NSView {
    static let size = NSSize(width: 124, height: 78)

    var onChange: ((EdgeDockEdge, EdgeDockRow) -> Void)?
    var edge: EdgeDockEdge = .right { didSet { selectionChanged() } }
    var row: EdgeDockRow = .middle { didSet { selectionChanged() } }
    var isEnabled = true { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { Self.size }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        selectionChanged()
    }

    required init?(coder: NSCoder) { nil }

    /// Centre of one square, in this view's flipped coordinates.
    static func center(edge: EdgeDockEdge, row: EdgeDockRow, in bounds: NSRect) -> NSPoint {
        let x = edge == .left ? bounds.minX + 14 : bounds.maxX - 14
        let fraction: CGFloat = switch row {
        case .top: EdgeDockPlacement.rowMargin
        case .middle: 0.5
        case .bottom: 1 - EdgeDockPlacement.rowMargin
        }
        return NSPoint(x: x, y: bounds.minY + bounds.height * fraction)
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.45
        let screen = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(alpha).setFill()
        screen.fill()
        NSColor.separatorColor.setStroke()
        screen.lineWidth = 1
        screen.stroke()

        // The strip itself, flush with the chosen side and anchored the way the real one is.
        let selected = Self.center(edge: edge, row: row, in: bounds)
        let stripHeight: CGFloat = 24
        let stripY: CGFloat = switch row {
        case .top: selected.y - 4
        case .middle: selected.y - stripHeight / 2
        case .bottom: selected.y + 4 - stripHeight
        }
        let strip = NSRect(x: edge == .left ? bounds.minX + 2 : bounds.maxX - 7, y: stripY, width: 5, height: stripHeight)
        NSColor.secondaryLabelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: strip, xRadius: 2.5, yRadius: 2.5).fill()

        for side in [EdgeDockEdge.left, .right] {
            for place in EdgeDockRow.allCases {
                let point = Self.center(edge: side, row: place, in: bounds)
                let chosen = side == edge && place == row
                let size: CGFloat = chosen ? 12 : 9
                let square = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                (chosen ? NSColor.labelColor : NSColor.tertiaryLabelColor).withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: square, xRadius: 2.5, yRadius: 2.5).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        var best: (EdgeDockEdge, EdgeDockRow, CGFloat)?
        for side in [EdgeDockEdge.left, .right] {
            for place in EdgeDockRow.allCases {
                let center = Self.center(edge: side, row: place, in: bounds)
                let distance = hypot(center.x - point.x, center.y - point.y)
                if distance <= 18, distance < (best?.2 ?? .infinity) { best = (side, place, distance) }
            }
        }
        guard let (side, place, _) = best, side != edge || place != row else { return }
        edge = side
        row = place
        onChange?(side, place)
    }

    private func selectionChanged() {
        let title = EdgeDockPlacement.positionTitle(edge: edge, row: row)
        toolTip = title
        setAccessibilityLabel(title)
        needsDisplay = true
    }
}

/// Menu items and the display choice shared by Settings and the status-item menu.
@MainActor
final class EdgeDockMenuAction: NSObject {
    private let handler: () -> Void

    private init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc private func run() { handler() }

    static func item(_ title: String, checked: Bool, handler: @escaping () -> Void) -> NSMenuItem {
        let action = EdgeDockMenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(EdgeDockMenuAction.run), keyEquivalent: "")
        item.target = action
        item.representedObject = action   // a menu item holds its target weakly; this keeps it alive
        item.state = checked ? .on : .off
        item.isEnabled = true
        return item
    }

    /// Saves a display choice with the frame and name that let it be found again and named while it is
    /// unplugged. An empty id goes back to the main display.
    static func chooseDisplay(_ id: String) {
        let settings = AppSettings.shared
        guard id != settings.edgeDockDisplayID else { return }
        if id.isEmpty {
            settings.edgeDockDisplayFrame = ""
            settings.edgeDockDisplayName = ""
            settings.edgeDockDisplayID = ""
            return
        }
        guard let display = EdgeDockPlacement.connectedDisplays().first(where: { $0.id == id }) else { return }
        settings.edgeDockDisplayFrame = EdgeDockPlacement.formatFrame(display.frame)
        settings.edgeDockDisplayName = display.name
        settings.edgeDockDisplayID = display.id
    }
}
