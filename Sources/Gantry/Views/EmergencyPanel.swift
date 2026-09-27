import AppKit

/// The siren from design/emergency-siren.svg, drawn natively in its 128-point box. The rays blink and
/// the dome glows, so the window reads as an alarm before a word of it is read.
@MainActor
final class SirenView: NSView {
    private var raysOn = true
    private var timer: Timer?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 104, height: 104) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.raysOn.toggle()
                self.needsDisplay = true
            }
        }
    }

    override func removeFromSuperview() {
        timer?.invalidate()
        timer = nil
        super.removeFromSuperview()
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = min(bounds.width, bounds.height) / 128
        let origin = NSPoint(x: (bounds.width - 128 * scale) / 2, y: (bounds.height - 128 * scale) / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        let red = NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1)
        let ray = NSColor(srgbRed: 1, green: 0.271, blue: 0.227, alpha: raysOn ? 1 : 0.18)

        let rays = NSBezierPath()
        for (a, b) in [((10, 50), (24, 56)), ((24, 18), (35, 31)), ((64, 4), (64, 19)), ((104, 18), (93, 31)), ((118, 50), (104, 56))] {
            rays.move(to: p(CGFloat(a.0), CGFloat(a.1)))
            rays.line(to: p(CGFloat(b.0), CGFloat(b.1)))
        }
        rays.lineWidth = 7 * scale
        rays.lineCapStyle = .round
        ray.setStroke()
        rays.stroke()

        // Dome: M34 94 V70 A30 30 0 0 1 94 70 V94 Z (flipped view, so the arc runs clockwise on screen).
        let dome = NSBezierPath()
        dome.move(to: p(34, 94))
        dome.line(to: p(34, 70))
        dome.appendArc(withCenter: p(64, 70), radius: 30 * scale, startAngle: 180, endAngle: 0, clockwise: false)
        dome.line(to: p(94, 94))
        dome.close()
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = red.withAlphaComponent(raysOn ? 0.9 : 0.35)
        glow.shadowBlurRadius = 18 * scale
        glow.shadowOffset = .zero
        glow.set()
        red.setFill()
        dome.fill()
        NSGraphicsContext.restoreGraphicsState()

        let shine = NSBezierPath()
        shine.appendArc(withCenter: p(64, 70), radius: 18 * scale, startAngle: 180, endAngle: 270, clockwise: false)
        shine.lineWidth = 5 * scale
        shine.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.55).setStroke()
        shine.stroke()

        NSColor(srgbRed: 0.557, green: 0.106, blue: 0.122, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: p(24, 94), size: NSSize(width: 80 * scale, height: 14 * scale)),
                     xRadius: 4 * scale, yRadius: 4 * scale).fill()
        NSColor(srgbRed: 0.227, green: 0.227, blue: 0.235, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: p(16, 108), size: NSSize(width: 96 * scale, height: 10 * scale)),
                     xRadius: 5 * scale, yRadius: 5 * scale).fill()
    }
}

/// A button painted solid red: the one thing in the window a hand should find.
@MainActor
private final class PanicButton: NSButton {
    private let fill = NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1)

    init(title: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = fill.cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 17, weight: .heavy)
        ])
        heightAnchor.constraint(equalToConstant: 54).isActive = true
    }

    required init?(coder: NSCoder) { nil }

}

/// The emergency power-off question as a panic panel: red frame, blinking siren, the printers it will
/// hit, one big red button that Return presses and Escape to back out.
@MainActor
final class EmergencyPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var confirmed = false

    static func confirm(printers: [String]) -> Bool {
        EmergencyPanel(printers: printers).run()
    }

    private init(printers: [String]) {
        let s = AppSettings.shared
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.appearance = NSAppearance(named: .darkAqua)
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }

        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 22
        frame.layer?.backgroundColor = NSColor(srgbRed: 0.11, green: 0.07, blue: 0.075, alpha: 0.98).cgColor
        frame.layer?.borderWidth = 4
        frame.layer?.borderColor = NSColor(srgbRed: 1, green: 0.271, blue: 0.227, alpha: 1).cgColor
        panel.contentView = frame

        let siren = SirenView()
        siren.translatesAutoresizingMaskIntoConstraints = false
        siren.widthAnchor.constraint(equalToConstant: 104).isActive = true
        siren.heightAnchor.constraint(equalToConstant: 104).isActive = true

        let title = NSTextField(wrappingLabelWithString: s.t("Switch off every printer's power?").uppercased())
        title.font = .systemFont(ofSize: 19, weight: .black)
        title.textColor = NSColor(srgbRed: 1, green: 0.42, blue: 0.4, alpha: 1)
        title.alignment = .center
        let detail = NSTextField(wrappingLabelWithString:
            s.t("{0} sockets are switched off at once. Running prints end and cannot be resumed.", printers.count))
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = NSColor.white.withAlphaComponent(0.8)
        detail.alignment = .center
        let list = NSTextField(wrappingLabelWithString: printers.map { "•  \($0)" }.joined(separator: "\n"))
        list.font = .systemFont(ofSize: 12, weight: .semibold)
        list.textColor = .white
        list.alignment = .center

        let go = PanicButton(title: "⚡ " + s.t("Switch everything off").uppercased(), target: self, action: #selector(goPressed))
        go.keyEquivalent = "\r"
        let cancel = NSButton(title: s.t("Cancel"), target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let hint = NSTextField(labelWithString: s.t("Return — switch off · Esc — cancel"))
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = NSColor.white.withAlphaComponent(0.45)

        let stack = NSStackView(views: [siren, title, detail, list, go, cancel, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: list)
        stack.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: frame.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -22),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            go.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        panel.layoutIfNeeded()
        panel.setContentSize(frame.fittingSize)
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
