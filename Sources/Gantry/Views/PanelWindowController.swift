import AppKit

/// Escape closes the panel, the way clicking the dimmed backdrop closed it when it was an overlay.
private final class PanelWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

/// The header strip in the unified title bar. It stays a handle for dragging the window; the buttons
/// placed in it still take their own clicks.
private final class PanelHeaderView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// One auxiliary panel in its own window, centred on the screen.
///
/// Diagnostics, fleet statistics, maintenance, slot assignment and Spoolbase used to be overlays
/// inside whichever surface opened them. Inside the menu-bar popover that cost more than it bought:
/// a panel could never be larger than the popover, it dimmed the cards the user had just come to
/// read, and making room for the roll list resized the popover, which threw the whole window across
/// the screen. Each one is a window of its own now, and the fleet panel stays lit behind it.
///
/// Every one of them wears the same frame, set by the `panelWindow` contract in
/// design/gantry-card-layout.impl.json: the fleet panel's own header, GANTRY · name, in a unified
/// title bar beside the traffic lights, a hairline under it, and the panel's content below. The
/// panels no longer draw a title or a close button of their own.
@MainActor
final class PanelWindowController: NSWindowController, NSWindowDelegate {

    typealias WorkspacePresenter = (NSView, String, NSSize, [NSView], @escaping () -> Void) -> PanelWindowController
    static var workspacePresenter: WorkspacePresenter?
    private var embeddedDismiss: (() -> Void)?

    static func embedded(onDismiss: @escaping () -> Void) -> PanelWindowController {
        PanelWindowController(embeddedDismiss: onDismiss)
    }
    private init(embeddedDismiss: @escaping () -> Void) {
        self.embeddedDismiss = embeddedDismiss
        super.init(window: nil)
    }

    // MARK: The shared contract

    /// "Gantry · Spoolbase". The Window menu, Mission Control and the Dock menu show this string; the
    /// header draws the same two parts with the wordmark. A middle dot, as in the fleet header.
    static func windowTitle(for name: String) -> String { "Gantry · \(name)" }
    /// Clears the three traffic lights, so the wordmark starts where a document title would.
    static let headerLeadingInset: CGFloat = 78
    static let headerTrailingInset: CGFloat = 12
    /// The floor for the header height. The real value is the title bar's, measured, so the traffic
    /// lights and the wordmark share one centre line whatever height the system gives the bar.
    static let minimumHeaderHeight: CGFloat = 38
    static let wordmarkHeight: CGFloat = 13

    // MARK: Keeping the fleet panel on screen

    /// AppKit closes a transient popover the moment another window of the app becomes key, so the
    /// fleet panel has to stop behaving like a menu while a panel is open over it. A count, not a
    /// flag, on purpose: closing one of two open panels must not hand the popover back to AppKit
    /// while the other is still up.
    private static var holds = 0
    /// Installed by `MenuBarController`, the only object that knows which fleet presentation is live.
    static var onHoldChanged: ((Bool) -> Void)?
    /// The window a panel borrows its level from. The popover floats at pop-up-menu level, above
    /// every ordinary window, so a panel left at `.normal` would open behind the thing that opened
    /// it. Also installed by `MenuBarController`.
    static var companionWindow: (() -> NSWindow?)?

    static func retainFleetPanel() {
        holds += 1
        if holds == 1 { onHoldChanged?(true) }
    }

    static func releaseFleetPanel() {
        guard holds > 0 else { return }
        holds -= 1
        if holds == 0 { onHoldChanged?(false) }
    }

    // MARK: Presentation

    /// A panel owns itself while it is on screen. Every caller keeps a reference so it can close the
    /// panel, but a window must not disappear because somebody reassigned the static holding it.
    private static var live: [PanelWindowController] = []

    private var onDismiss: (() -> Void)?
    private var holdsFleetPanel = false
    /// Measured title bar height, which is also the header's.
    private(set) var headerHeight: CGFloat = minimumHeaderHeight

    /// - Parameters:
    ///   - name: what the panel is, shown after the wordmark: "Spoolbase", "Fleet statistics".
    ///   - size: the content's size, below the header.
    ///   - minSize: smallest content size the user may drag the window down to. Panels that scroll
    ///     their own content take the default; one that would clip instead passes its own size.
    ///   - accessories: controls that belong to the panel as a whole (Spoolbase's add button,
    ///     maintenance instructions), placed at the trailing end of the header.
    @discardableResult
    static func present(_ content: NSView, name: String, size: NSSize, minSize: NSSize? = nil,
                        accessories: [NSView] = [],
                        onDismiss: @escaping () -> Void) -> PanelWindowController {
        if let workspacePresenter { return workspacePresenter(content, name, size, accessories, onDismiss) }
        let controller = PanelWindowController(content: content, name: name, size: size,
                                               minSize: minSize, accessories: accessories,
                                               onDismiss: onDismiss)
        controller.presentCentered()
        return controller
    }

    private init(content: NSView, name: String, size: NSSize, minSize: NSSize?,
                 accessories: [NSView], onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        // Never larger than the screen it opens on: a panel asking for 640 points on a laptop still
        // has to leave the menu bar and the Dock alone.
        let room = (NSScreen.main?.visibleFrame.size) ?? NSSize(width: 1280, height: 800)
        let fitted = NSSize(width: min(size.width, room.width - 40),
                            height: min(size.height, room.height - 80))
        let window = PanelWindow(contentRect: NSRect(origin: .zero, size: fitted),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.title = Self.windowTitle(for: name)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty toolbar in the compact unified style is what gives the title bar room for a header
        // row with the traffic lights centred in it, like Finder or Mail. Nothing is ever added to it.
        window.toolbar = NSToolbar(identifier: "gantry.panel")
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.appearance = AppSettings.shared.appearance
        // The window carries the card colour so it and the panel read as one surface. Without it the
        // panel's rounded corners would show the default window grey in all four of them.
        window.backgroundColor = GantryTheme.card
        super.init(window: window)
        window.delegate = self

        headerHeight = max(Self.minimumHeaderHeight, window.frame.height - window.contentLayoutRect.height)
        // `size` is the content below the header, so the frame grows by exactly the header.
        let frameSize = NSSize(width: fitted.width, height: fitted.height + headerHeight)
        window.setFrame(NSRect(origin: window.frame.origin, size: frameSize), display: false)
        let smallest = minSize ?? NSSize(width: min(360, fitted.width), height: min(240, fitted.height))
        window.minSize = NSSize(width: min(smallest.width, fitted.width),
                                height: min(smallest.height, fitted.height) + headerHeight)
        install(content, name: name, accessories: accessories, in: window)
    }

    required init?(coder: NSCoder) { nil }

    private func install(_ content: NSView, name: String, accessories: [NSView], in window: NSWindow) {
        guard let host = window.contentView else { return }

        let header = PanelHeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let wordmark = NSImageView(image: GantryLogo.wordmarkImage(height: Self.wordmarkHeight))
        wordmark.setContentHuggingPriority(.required, for: .horizontal)
        wordmark.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The same dot the fleet header puts between the wordmark and its summary.
        let dot = NSTextField(labelWithString: "·")
        dot.font = .systemFont(ofSize: 12, weight: .semibold)
        dot.textColor = GantryTheme.muted
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = GantryTheme.text
        nameLabel.lineBreakMode = .byTruncatingTail
        // A long printer name gives way before the accessories do.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [wordmark, dot, nameLabel, spacer] + accessories)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = GantryTheme.line.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(rule)
        host.addSubview(header)

        // Flattened for the same reason the window took the card colour: a rounded, bordered card
        // inset in a square window traces a visible outline just inside the window's own edge.
        content.layer?.cornerRadius = 0
        content.layer?.borderWidth = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: host.topAnchor),
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Self.headerLeadingInset),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -Self.headerTrailingInset),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    private func presentCentered() {
        guard let window else { return }
        PanelWindowController.live.append(self)
        PanelWindowController.retainFleetPanel()
        holdsFleetPanel = true
        // Borrowed rather than raised to a fixed level: two windows on the same level order
        // front-to-back by when they were last made key, so the panel lands in front of the fleet
        // panel that opened it and cannot be covered by it.
        window.level = .normal
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the panel from code. The dismissal callback is deliberately dropped: it exists to tell
    /// the owner that the *user* closed the window, and running it back into a dismissal the owner
    /// itself started is how you get a recursion.
    func dismiss() {
        if let close = embeddedDismiss { embeddedDismiss = nil; close(); return }
        onDismiss = nil
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if holdsFleetPanel {
            holdsFleetPanel = false
            PanelWindowController.releaseFleetPanel()
        }
        PanelWindowController.live.removeAll { $0 === self }
        let dismiss = onDismiss
        onDismiss = nil
        dismiss?()
    }
}
