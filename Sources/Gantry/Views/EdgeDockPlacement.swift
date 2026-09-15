import AppKit

/// Where along the chosen edge the strip sits. Top and bottom keep clear of the corner by
/// `EdgeDockPlacement.rowMargin` of the usable height, below the menu bar and above the Dock.
enum EdgeDockRow: String, CaseIterable, Sendable {
    case top
    case middle
    case bottom
}

/// One connected display as the strip sees it. `frame` is the whole display, which the strip touches
/// on its side; `visibleFrame` leaves out the menu bar and the Dock, and bounds the strip vertically.
struct EdgeDockDisplay: Equatable, Sendable {
    let id: String
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let frame: CGRect
    let visibleFrame: CGRect
    let isPrimary: Bool
}

/// Which display the strip lives on and where on it. Pure geometry apart from `connectedDisplays()`,
/// so every rule below is covered by tests on simulated desktops. The same rules on Windows and
/// GNU/Linux (contract edgeDock.placement).
enum EdgeDockPlacement {
    static let rowMargin: CGFloat = 0.2
    static let displayTolerance: CGFloat = 8
    static let innerEdgeDwell: TimeInterval = 0.25
    static let displayChangeDebounceMilliseconds = 600

    /// The display the strip belongs on, and whether that is the one the user chose rather than the
    /// fallback. A display that is missing never clears the choice: the strip waits on the main
    /// display and goes back as soon as its own display returns.
    ///
    /// 1. The saved id with the saved size. 2. The saved frame within `displayTolerance`, for an id
    /// that changed; twins with the same frame resolve to the main display. 3. The saved id alone,
    /// for a display whose resolution changed. 4. The main display.
    static func resolve(displays: [EdgeDockDisplay], savedID: String,
                        savedFrame: CGRect?) -> (display: EdgeDockDisplay, matched: Bool)? {
        guard let primary = displays.first(where: \.isPrimary) ?? displays.first else { return nil }
        guard !savedID.isEmpty else { return (primary, false) }
        let byID = displays.first { $0.id == savedID }
        if let savedFrame {
            if let byID, sameSize(byID.frame, savedFrame) { return (byID, true) }
            let near = displays.filter { sameFrame($0.frame, savedFrame) }
            if let twin = near.first(where: \.isPrimary) ?? near.first { return (twin, true) }
        }
        if let byID { return (byID, true) }
        return (primary, false)
    }

    /// Bottom-left origin for a strip of `size` in AppKit's y-up coordinates. Flush against the
    /// display's side; vertically placed in the visible frame and kept inside it, so a strip taller
    /// than the space left below a top anchor slides up instead of running off the screen.
    static func origin(size: CGSize, frame: CGRect, visibleFrame: CGRect,
                       edge: EdgeDockEdge, row: EdgeDockRow) -> CGPoint {
        let x = edge == .right ? frame.maxX - size.width : frame.minX
        let margin = visibleFrame.height * rowMargin
        var y: CGFloat
        switch row {
        case .top: y = visibleFrame.maxY - margin - size.height
        case .middle: y = visibleFrame.midY - size.height / 2
        case .bottom: y = visibleFrame.minY + margin
        }
        if size.height >= visibleFrame.height {
            y = visibleFrame.maxY - size.height
        } else {
            y = min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height)
        }
        return CGPoint(x: x, y: y)
    }

    /// True when another display continues past this edge. There the pointer crosses the strip on its
    /// way to the neighbour, so the strip must not unfold on a mere pass.
    static func isInnerEdge(_ display: EdgeDockDisplay, edge: EdgeDockEdge, among displays: [EdgeDockDisplay]) -> Bool {
        displays.contains { other in
            guard other.id != display.id || other.frame != display.frame else { return false }
            let overlaps = other.frame.minY < display.frame.maxY && other.frame.maxY > display.frame.minY
            let touches = edge == .right ? abs(other.frame.minX - display.frame.maxX) <= 2
                                         : abs(other.frame.maxX - display.frame.minX) <= 2
            return overlaps && touches
        }
    }

    static func formatFrame(_ frame: CGRect) -> String {
        [frame.minX, frame.minY, frame.width, frame.height].map { String(Int($0.rounded())) }.joined(separator: ",")
    }

    static func parseFrame(_ text: String) -> CGRect? {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    static func title(for display: EdgeDockDisplay) -> String {
        let base = "\(display.name) · \(display.pixelWidth)×\(display.pixelHeight)"
        return display.isPrimary ? Localization.t("{0} (main)", base) : base
    }

    static func positionTitle(edge: EdgeDockEdge, row: EdgeDockRow) -> String {
        let side = Localization.t(edge == .left ? "Left edge" : "Right edge")
        let place = switch row {
        case .top: Localization.t("at the top")
        case .middle: Localization.t("in the middle")
        case .bottom: Localization.t("at the bottom")
        }
        return "\(side), \(place)"
    }

    /// The monitor list for Settings and the menu: the main display first, every connected display, and
    /// the chosen one kept on the list while it is unplugged, so the choice stays visible.
    static func choices(displays: [EdgeDockDisplay], savedID: String,
                        savedName: String) -> [(id: String, title: String, selected: Bool)] {
        var result: [(id: String, title: String, selected: Bool)] = [("", Localization.t("Main display"), savedID.isEmpty)]
        for display in displays {
            result.append((display.id, title(for: display), display.id == savedID))
        }
        if !savedID.isEmpty, !displays.contains(where: { $0.id == savedID }) {
            let name = savedName.isEmpty ? savedID : savedName
            result.append((savedID, Localization.t("{0} (disconnected)", name), true))
        }
        return result
    }

    @MainActor
    static func connectedDisplays() -> [EdgeDockDisplay] {
        NSScreen.screens.enumerated().map { index, screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            // The UUID survives restarts and a change of port, unlike the display number.
            let id = CGDisplayCreateUUIDFromDisplayID(number).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            } ?? "display-\(number)"
            return EdgeDockDisplay(id: id, name: screen.localizedName,
                                   pixelWidth: Int((screen.frame.width * screen.backingScaleFactor).rounded()),
                                   pixelHeight: Int((screen.frame.height * screen.backingScaleFactor).rounded()),
                                   frame: screen.frame, visibleFrame: screen.visibleFrame,
                                   isPrimary: index == 0)
        }
    }

    private static func sameSize(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.width - b.width) <= displayTolerance && abs(a.height - b.height) <= displayTolerance
    }

    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= displayTolerance && abs(a.minY - b.minY) <= displayTolerance && sameSize(a, b)
    }
}
