import AppKit

/// Escape closes the panel, the way clicking the dimmed backdrop closed it when it was an overlay.
private final class PanelWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

/// One auxiliary panel in its own window, centred on the screen.
///
/// Diagnostics, fleet statistics, maintenance, slot assignment and Spoolbase used to be overlays
/// inside whichever surface opened them. Inside the menu-bar popover that cost more than it bought:
/// a panel could never be larger than the popover, it dimmed the cards the user had just come to
/// read, and making room for the roll list resized the popover, which threw the whole window across
/// the screen. Each one is a window of its own now, and the fleet panel stays lit behind it.
@MainActor
final class PanelWindowController: NSWindowController, NSWindowDelegate {

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

    /// - Parameter minSize: smallest content size the user may drag the window down to. Panels that
    ///   scroll their own content take the default; one that would clip instead passes its own size.
    @discardableResult
    static func present(_ content: NSView, title: String, size: NSSize, minSize: NSSize? = nil,
                        onDismiss: @escaping () -> Void) -> PanelWindowController {
        let controller = PanelWindowController(content: content, title: title, size: size,
                                               minSize: minSize, onDismiss: onDismiss)
        controller.presentCentered()
        return controller
    }

    private init(content: NSView, title: String, size: NSSize, minSize: NSSize?,
                 onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        // Never larger than the screen it opens on: a panel asking for 640 points on a laptop still
        // has to leave the menu bar and the Dock alone.
        let room = (NSScreen.main?.visibleFrame.size) ?? NSSize(width: 1280, height: 800)
        let fitted = NSSize(width: min(size.width, room.width - 40),
                            height: min(size.height, room.height - 40))
        let window = PanelWindow(contentRect: NSRect(origin: .zero, size: fitted),
                                 styleMask: [.titled, .closable, .resizable],
                                 backing: .buffered, defer: false)
        window.title = title
        // The same frame as Gantry's other windows: traffic lights on a transparent strip and no
        // title text, because every panel already names itself in its own header.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = AppSettings.shared.appearance
        // The window carries the card colour so it and the panel read as one surface. Without it the
        // panel's rounded corners would show the default window grey in all four of them.
        window.backgroundColor = GantryTheme.card
        let smallest = minSize ?? NSSize(width: min(360, fitted.width), height: min(240, fitted.height))
        window.contentMinSize = NSSize(width: min(smallest.width, fitted.width),
                                       height: min(smallest.height, fitted.height))
        super.init(window: window)
        window.delegate = self
        install(content, in: window)
    }

    required init?(coder: NSCoder) { nil }

    private func install(_ content: NSView, in window: NSWindow) {
        guard let host = window.contentView else { return }
        // Flattened for the same reason the window took the card colour: a rounded, bordered card
        // inset in a square window traces a visible outline just inside the window's own edge.
        content.layer?.cornerRadius = 0
        content.layer?.borderWidth = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
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
        window.level = PanelWindowController.companionWindow?()?.level ?? .normal
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the panel from code. The dismissal callback is deliberately dropped: it exists to tell
    /// the owner that the *user* closed the window, and running it back into a dismissal the owner
    /// itself started is how you get a recursion.
    func dismiss() {
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
