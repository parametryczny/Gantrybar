import AppKit

/// A centered, bounded modal card over a live, blurred dashboard. Frame-based outer geometry keeps
/// the modal's preferred size from becoming a minimum size for the user's resizable window.
@MainActor
final class EmbeddedPanelView: NSView {
    private let onDismiss: () -> Void
    private let preferredSize: NSSize
    private let fillsViewport: Bool
    private let showsCloseButton: Bool
    private let surface = EmbeddedPanelSurface()
    private let scroll = NSScrollView()
    private let document: NSView
    private let close = NSButton()

    static func show(_ panel: NSView, in host: NSView, size: NSSize,
                     fillsViewport: Bool = false, showsCloseButton: Bool = true,
                     onDismiss: @escaping () -> Void) -> EmbeddedPanelView {
        let backdrop = EmbeddedPanelView(host: host, panel: panel, size: size,
            fillsViewport: fillsViewport, showsCloseButton: showsCloseButton, onDismiss: onDismiss)
        host.addSubview(backdrop)
        backdrop.needsLayout = true
        return backdrop
    }

    private init(host: NSView, panel: NSView, size: NSSize, fillsViewport: Bool,
                 showsCloseButton: Bool, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        self.preferredSize = size
        self.fillsViewport = fillsViewport
        self.showsCloseButton = showsCloseButton
        document = EmbeddedPanelDocument(frame: NSRect(origin: .zero, size: size))
        super.init(frame: host.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true

        let blur = EmbeddedPanelBlur(frame: bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        addSubview(blur)
        let dim = EmbeddedPanelTint(frame: bounds)
        dim.autoresizingMask = [.width, .height]
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        addSubview(dim)

        surface.wantsLayer = true
        surface.layer?.backgroundColor = GantryTheme.card.cgColor
        surface.layer?.cornerRadius = GantryTheme.cardRadius
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        surface.layer?.masksToBounds = true
        addSubview(surface)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: AppSettings.shared.t("Close"))
        close.target = self
        close.action = #selector(dismissPanel)
        close.isBordered = false
        close.contentTintColor = GantryTheme.text
        close.toolTip = AppSettings.shared.t("Close")
        close.isHidden = !showsCloseButton
        surface.addSubview(close)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = !fillsViewport
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        surface.addSubview(scroll)
        scroll.documentView = document
        panel.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            panel.topAnchor.constraint(equalTo: document.topAnchor),
            panel.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Leave the native title controls unobstructed, with breathing room around the card.
        let available = NSRect(x: 12, y: 12, width: max(1, bounds.width - 24),
                               height: max(1, bounds.height - 52))
        let headerHeight: CGFloat = showsCloseButton ? 32 : 0
        let width = min(preferredSize.width, available.width)
        let height = min(preferredSize.height + headerHeight, available.height)
        surface.frame = NSRect(x: floor(available.midX - width / 2),
                               y: floor(available.midY - height / 2), width: width, height: height)
        close.frame = NSRect(x: max(0, width - 32), y: max(0, height - 28), width: 24, height: 24)
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: max(1, height - headerHeight))
        scroll.tile()
        let viewport = scroll.contentSize
        // Small windows can scroll horizontally when a legacy panel needs more room. Controllers
        // with an internal scroll own vertical scrolling and exactly match the viewport's height.
        let documentSize = NSSize(width: preferredSize.width,
            height: fillsViewport ? max(1, viewport.height) : preferredSize.height)
        if document.frame.size != documentSize { document.setFrameSize(documentSize) }
        document.layoutSubtreeIfNeeded()
    }

    @objc private func dismissPanel() { onDismiss() }
    override func mouseDown(with event: NSEvent) { onDismiss() }
}

private final class EmbeddedPanelDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class EmbeddedPanelSurface: NSView {
    override func mouseDown(with event: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class EmbeddedPanelBlur: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class EmbeddedPanelTint: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
