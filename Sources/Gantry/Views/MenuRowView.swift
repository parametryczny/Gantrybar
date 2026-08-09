import AppKit

/// A tall, spacious row used as an `NSMenuItem.view` so the status-bar menu can look larger and
/// more breathable than a stock `NSMenu`. Each row draws its own icon, label, right-aligned
/// accessory and optional trailing action buttons, and handles hover highlighting and clicks —
/// a custom view is fully responsible for its own drawing and event handling.
@MainActor
final class MenuRowView: NSView {
    /// Right-aligned content following the label.
    enum Accessory {
        case none
        case detail(String)          // muted text: a shortcut hint, version, current value
        case value(String)           // value + a trailing chevron (e.g. the language toggle)
    }

    /// A tappable icon drawn at the trailing edge (e.g. reconnect / copy IP on a printer row).
    struct Action {
        let symbol: String
        let accessibility: String
        let run: () -> Void
    }

    static let rowWidth: CGFloat = 262
    static let rowHeight: CGFloat = 34

    private let iconName: String
    private let iconTint: NSColor
    private let title: String
    private let accessory: Accessory
    private let enabled: Bool
    private let onSelect: (() -> Void)?
    private let actions: [Action]

    private var isHovered = false
    private var actionHitRects: [(rect: NSRect, run: () -> Void)] = []

    init(icon: String,
         tint: NSColor = .secondaryLabelColor,
         title: String,
         accessory: Accessory = .none,
         enabled: Bool = true,
         actions: [Action] = [],
         onSelect: (() -> Void)? = nil) {
        self.iconName = icon
        self.iconTint = tint
        self.title = title
        self.accessory = accessory
        self.enabled = enabled
        self.actions = actions
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    // MARK: Selection

    override func mouseUp(with event: NSEvent) {
        guard enabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = actionHitRects.first(where: { $0.rect.contains(point) }) {
            dismiss(then: hit.run)
            return
        }
        if let onSelect { dismiss(then: onSelect) }
    }

    /// Closes the menu the way a normal item selection would, then runs the action on the next
    /// run-loop pass so any UI it presents doesn't fight the closing menu.
    private func dismiss(then action: () -> Void) {
        // Close the menu first, then run the action. The update check and settings window both
        // defer their own presentation (a Task / a separate window), so a synchronous call here
        // doesn't fight the closing menu.
        enclosingMenuItem?.menu?.cancelTracking()
        action()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let mutedText = NSColor.secondaryLabelColor
        let labelColor: NSColor = enabled ? .labelColor : .tertiaryLabelColor

        if isHovered && enabled {
            let highlight = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 7, yRadius: 7)
            NSColor.white.withAlphaComponent(0.10).setFill()
            highlight.fill()
        }

        let midY = bounds.midY
        if let icon = Self.tintedSymbol(iconName, color: enabled ? iconTint : .tertiaryLabelColor, pointSize: 15) {
            let size = icon.size
            icon.draw(at: NSPoint(x: 14, y: midY - size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: labelColor
        ]
        let titleString = NSAttributedString(string: title, attributes: titleAttrs)
        let titleSize = titleString.size()
        titleString.draw(at: NSPoint(x: 40, y: midY - titleSize.height / 2))

        actionHitRects.removeAll()
        var rightEdge = bounds.maxX - 14

        switch accessory {
        case .none:
            break
        case .detail(let text):
            rightEdge = drawTrailingText(text, color: mutedText, size: 11.5, rightEdge: rightEdge, midY: midY)
        case .value(let text):
            if let chevron = Self.tintedSymbol("chevron.right", color: mutedText, pointSize: 10) {
                let size = chevron.size
                chevron.draw(at: NSPoint(x: rightEdge - size.width, y: midY - size.height / 2),
                             from: .zero, operation: .sourceOver, fraction: 1)
                rightEdge -= size.width + 5
            }
            rightEdge = drawTrailingText(text, color: mutedText, size: 11.5, rightEdge: rightEdge, midY: midY)
        }

        // Trailing action buttons, laid out right-to-left.
        for action in actions.reversed() {
            guard let image = Self.tintedSymbol(action.symbol, color: .labelColor, pointSize: 15) else { continue }
            let size = image.size
            let box = NSRect(x: rightEdge - size.width - 8, y: midY - 13, width: size.width + 16, height: 26)
            image.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
                       from: .zero, operation: .sourceOver, fraction: 1)
            actionHitRects.append((box, action.run))
            rightEdge = box.minX - 4
        }
    }

    private func drawTrailingText(_ text: String, color: NSColor, size: CGFloat, rightEdge: CGFloat, midY: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: color
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let textSize = string.size()
        string.draw(at: NSPoint(x: rightEdge - textSize.width, y: midY - textSize.height / 2))
        return rightEdge - textSize.width - 8
    }

    /// Renders an SF Symbol into a flat, single-colour image so it can be drawn tinted in the row.
    private static func tintedSymbol(_ name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configured = base.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        ) ?? base
        let image = NSImage(size: configured.size)
        image.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: configured.size)
        configured.draw(in: rect, from: rect, operation: .sourceOver, fraction: 1)
        rect.fill(using: .sourceIn)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
