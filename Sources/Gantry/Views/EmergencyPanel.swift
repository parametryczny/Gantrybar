import AppKit

private enum Palette {
    static let red = NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1)
    static let redDeep = NSColor(srgbRed: 0.62, green: 0.12, blue: 0.14, alpha: 1)
    static let ray = NSColor(srgbRed: 1, green: 0.33, blue: 0.29, alpha: 1)
    static let card = NSColor(srgbRed: 0.086, green: 0.078, blue: 0.082, alpha: 1)
    static let kicker = NSColor(srgbRed: 1, green: 0.42, blue: 0.384, alpha: 1)
}

/// The siren from design/emergency-siren.svg, drawn natively in its 128-point box. The rays blink,
/// the glossy dome brightens and a red halo breathes behind it: an alarm before a word is read.
@MainActor
final class SirenView: NSView {
    private let started = Date()
    private var timer: Timer?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 112, height: 112) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        // .common keeps it ticking inside NSApp.runModal.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func removeFromSuperview() {
        timer?.invalidate()
        timer = nil
        super.removeFromSuperview()
    }

    override func draw(_ dirtyRect: NSRect) {
        let phase = CGFloat(Date().timeIntervalSince(started).truncatingRemainder(dividingBy: 1))
        let on = phase < 0.5
        let scale = min(bounds.width, bounds.height) / 128
        let origin = NSPoint(x: (bounds.width - 128 * scale) / 2, y: (bounds.height - 128 * scale) / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin.x + x * scale, y: origin.y + y * scale) }

        // Halo: a soft red disc behind the dome that swells and fades once a second.
        let halo = (34 + 14 * phase) * scale
        NSGradient(colors: [Palette.red.withAlphaComponent(0.55 * (1 - phase)), Palette.red.withAlphaComponent(0)])?
            .draw(fromCenter: p(64, 72), radius: 8 * scale, toCenter: p(64, 72), radius: halo, options: [])

        let rays = NSBezierPath()
        for (a, b) in [((10, 50), (24, 56)), ((24, 18), (35, 31)), ((64, 4), (64, 19)), ((104, 18), (93, 31)), ((118, 50), (104, 56))] {
            rays.move(to: p(CGFloat(a.0), CGFloat(a.1)))
            rays.line(to: p(CGFloat(b.0), CGFloat(b.1)))
        }
        rays.lineWidth = 7 * scale
        rays.lineCapStyle = .round
        Palette.ray.withAlphaComponent(on ? 1 : 0.16).setStroke()
        rays.stroke()

        // Dome: M34 94 V70 A30 30 0 0 1 94 70 V94 Z, with a vertical gloss.
        let dome = NSBezierPath()
        dome.move(to: p(34, 94))
        dome.line(to: p(34, 70))
        dome.appendArc(withCenter: p(64, 70), radius: 30 * scale, startAngle: 180, endAngle: 0, clockwise: false)
        dome.line(to: p(94, 94))
        dome.close()
        let top = on ? NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.36, blue: 0.36, alpha: 1)
        // Flipped view: angle 90 runs from the top (small y) down.
        NSGradient(starting: top, ending: Palette.redDeep)?.draw(in: dome, angle: 90)

        let shine = NSBezierPath()
        shine.appendArc(withCenter: p(64, 70), radius: 18 * scale, startAngle: 180, endAngle: 270, clockwise: false)
        shine.lineWidth = 5 * scale
        shine.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.6).setStroke()
        shine.stroke()

        NSColor(srgbRed: 0.45, green: 0.09, blue: 0.11, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: p(24, 94), size: NSSize(width: 80 * scale, height: 14 * scale)),
                     xRadius: 4 * scale, yRadius: 4 * scale).fill()
        NSColor(srgbRed: 0.2, green: 0.2, blue: 0.21, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: p(16, 108), size: NSSize(width: 96 * scale, height: 10 * scale)),
                     xRadius: 5 * scale, yRadius: 5 * scale).fill()
    }
}

/// The card itself: dark, a red glow bleeding in from the top, a warning-stripe band, a thin red
/// outline and a red glow around it. The window is transparent, so the glow has room (``inset``).
@MainActor
private final class CardView: NSView {
    static let inset: CGFloat = 14
    private let radius: CGFloat = 24

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        for step in stride(from: 10, through: 1, by: -1) {
            let s = CGFloat(step)
            Palette.red.withAlphaComponent(0.028).setFill()
            NSBezierPath(roundedRect: card.insetBy(dx: -s, dy: -s), xRadius: radius + s, yRadius: radius + s).fill()
        }
        let shape = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
        Palette.card.setFill()
        shape.fill()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let centre = NSPoint(x: card.midX, y: card.minY - 40)
        NSGradient(colors: [Palette.red.withAlphaComponent(0.42), Palette.red.withAlphaComponent(0)])?
            .draw(fromCenter: centre, radius: 10, toCenter: centre, radius: card.height * 0.75, options: [])
        let band: CGFloat = 8
        let strip = NSRect(x: card.minX, y: card.minY, width: card.width, height: band)
        NSColor(srgbRed: 0.12, green: 0.05, blue: 0.06, alpha: 1).setFill()
        strip.fill()
        NSBezierPath(rect: strip).addClip()
        let stripes = NSBezierPath()
        var offset = -band
        while offset < card.width + band {
            let x = card.minX + offset
            stripes.move(to: NSPoint(x: x, y: card.minY + band))
            stripes.line(to: NSPoint(x: x + band, y: card.minY))
            stripes.line(to: NSPoint(x: x + band * 2, y: card.minY))
            stripes.line(to: NSPoint(x: x + band, y: card.minY + band))
            stripes.close()
            offset += band * 2.2
        }
        Palette.red.withAlphaComponent(0.95).setFill()
        stripes.fill()
        NSGraphicsContext.restoreGraphicsState()

        let outline = NSBezierPath(roundedRect: card.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        outline.lineWidth = 1.5
        NSColor(srgbRed: 1, green: 0.36, blue: 0.33, alpha: 0.85).setStroke()
        outline.stroke()
    }
}

/// A glossy red button: the one thing in the window a hand should find.
@MainActor
private final class PanicButton: NSButton {
    init(title: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = Palette.red.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        heightAnchor.constraint(equalToConstant: 56).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        let (top, bottom) = isHighlighted
            ? (NSColor(srgbRed: 0.85, green: 0.19, blue: 0.21, alpha: 1), NSColor(srgbRed: 0.70, green: 0.15, blue: 0.17, alpha: 1))
            : (NSColor(srgbRed: 1, green: 0.353, blue: 0.322, alpha: 1), NSColor(srgbRed: 0.85, green: 0.19, blue: 0.21, alpha: 1))
        NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: isFlipped ? 90 : -90)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let text = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 17, weight: .heavy)
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

/// A pill with one printer name in it.
@MainActor
private func chip(_ name: String) -> NSView {
    let label = NSTextField(labelWithString: "🖨  " + name)
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = NSColor(white: 0.95, alpha: 1)
    label.translatesAutoresizingMaskIntoConstraints = false
    let pill = NSView()
    pill.wantsLayer = true
    pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
    pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
    pill.layer?.borderWidth = 1
    pill.layer?.cornerRadius = 12
    pill.addSubview(label)
    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 11),
        label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -11),
        label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
        label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4)
    ])
    return pill
}

/// A borderless panel still has to take keys, or Return and Esc would go nowhere.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The emergency power-off question as a panic panel: glowing card, pulsing siren, the printers it
/// will hit as chips, one big red button that Return presses and a quiet Cancel that Escape presses.
@MainActor
final class EmergencyPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var confirmed = false

    static func confirm(printers: [String]) -> Bool {
        EmergencyPanel(printers: printers).run()
    }

    private init(printers: [String]) {
        let s = AppSettings.shared
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.title = s.t("Emergency power-off")
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.delegate = self
        panel.appearance = NSAppearance(named: .darkAqua)

        let card = CardView()
        panel.contentView = card

        let siren = SirenView()
        siren.translatesAutoresizingMaskIntoConstraints = false
        siren.widthAnchor.constraint(equalToConstant: 112).isActive = true
        siren.heightAnchor.constraint(equalToConstant: 112).isActive = true

        func centred(_ text: String, font: NSFont, color: NSColor, kern: CGFloat = 0) -> NSTextField {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let field = NSTextField(wrappingLabelWithString: "")
            field.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: paragraph
            ])
            return field
        }
        let kicker = centred(s.t("Emergency power-off").uppercased(), font: .systemFont(ofSize: 11, weight: .heavy),
                             color: Palette.kicker, kern: 2)
        let title = centred(s.t("Switch off every printer's power?"), font: .systemFont(ofSize: 21, weight: .heavy), color: .white)
        let detail = centred(s.t("{0} sockets are switched off at once. Running prints end and cannot be resumed.", printers.count),
                             font: .systemFont(ofSize: 13), color: NSColor.white.withAlphaComponent(0.62))

        // Chips, three to a row.
        let rows = stride(from: 0, to: printers.count, by: 3).map { start -> NSView in
            let row = NSStackView(views: printers[start..<min(start + 3, printers.count)].map(chip))
            row.orientation = .horizontal
            row.spacing = 6
            return row
        }
        let chips = NSStackView(views: rows)
        chips.orientation = .vertical
        chips.alignment = .centerX
        chips.spacing = 6

        let go = PanicButton(title: "⏻  " + s.t("Switch everything off"), target: self, action: #selector(goPressed))
        go.keyEquivalent = "\r"
        let cancel = NSButton(title: "", target: self, action: #selector(cancelPressed))
        cancel.isBordered = false
        cancel.attributedTitle = NSAttributedString(string: s.t("Cancel"), attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.72), .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ])
        cancel.keyEquivalent = "\u{1b}"
        let hint = NSTextField(labelWithString: s.t("Return — switch off · Esc — cancel"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.38)

        let stack = NSStackView(views: [siren, kicker, title, detail, chips, go, cancel, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(4, after: siren)
        stack.setCustomSpacing(12, after: detail)
        stack.setCustomSpacing(22, after: chips)
        stack.setCustomSpacing(12, after: go)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        let inset = CardView.inset
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 380),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset + 46),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -(inset + 46)),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: inset + 40),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -(inset + 30)),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            kicker.widthAnchor.constraint(equalTo: stack.widthAnchor),
            go.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        card.layoutSubtreeIfNeeded()
        panel.setContentSize(card.fittingSize)
        panel.initialFirstResponder = go
    }

    private func run() -> Bool {
        panel.center()
        ModalHost.run {
            panel.makeKeyAndOrderFront(nil)
            _ = NSApp.runModal(for: panel)
        }
        panel.orderOut(nil)
        return confirmed
    }

    @objc private func goPressed() {
        confirmed = true
        NSApp.stopModal()
    }

    @objc private func cancelPressed() {
        confirmed = false
        NSApp.stopModal()
    }
}
