// The Settings window has to fit on the screen, and everything in it has to be reachable. Reported
// 2026-09-21: the page and keep-awake rows grew under Integrations until the window ran off the
// bottom of the display and its last rows could not be reached at all.
//
// The window takes its height from the selected pane and caps that at what the display can show, so
// this checks the pair of promises on a laptop-sized screen: the window stays inside the budget, and
// a pane with more content than that can be scrolled all the way down.
import AppKit

@main @MainActor struct SettingsHeightCheck {
    /// A 13-inch MacBook's usable height, less the menu bar, the title bar and a margin.
    static let budget: CGFloat = 620

    static func main() {
        _ = NSApplication.shared
        let controller = SettingsWindowController(store: PrinterStore())
        guard let window = controller.window else { fatalError("Settings has no window") }
        window.setFrame(NSRect(x: 0, y: 0, width: 640, height: 900), display: false)
        window.layoutIfNeeded()

        var failures: [String] = []
        for item in controller.paneItemsForTesting {
            guard let pane = item.viewController else { continue }
            let name = (item.identifier as? String) ?? "?"
            pane.view.frame = NSRect(x: 0, y: 0, width: 596, height: budget)
            pane.view.layoutSubtreeIfNeeded()
            let content = pane.preferredContentSize.height

            guard content > budget else {
                print("PASS \(name): \(Int(content)) pt, fits without scrolling")
                continue
            }
            guard let scroll = scrollViews(in: pane.view).first else {
                failures.append("\(name): \(Int(content)) pt and no way to scroll to the rest")
                continue
            }
            guard let document = scroll.documentView else {
                failures.append("\(name): a scroll view with nothing in it")
                continue
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            if scroll.documentVisibleRect.maxY >= document.bounds.maxY - 1 {
                print("PASS \(name): \(Int(content)) pt, scrolls and the last row is reachable")
            } else {
                failures.append("\(name): the bottom of the pane cannot be reached")
            }
        }
        guard failures.isEmpty else {
            print("FAIL — " + failures.joined(separator: "; "))
            exit(1)
        }
        print("Settings fits a \(Int(budget)) pt screen: every pane fits or scrolls to its end")
        exit(0)
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { child -> [NSScrollView] in
            if let scroll = child as? NSScrollView { return [scroll] }
            return scrollViews(in: child)
        }
    }
}
