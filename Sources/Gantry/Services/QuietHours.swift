import Foundation

/// A daily window during which notifications are suppressed. Configured in Settings and toggled
/// quickly from the menu-bar right-click menu. Times are stored as minutes since midnight.
enum QuietHours {
    static var isEnabled: Bool {
        get { BambuDefaults.shared.bool(forKey: "quiet-hours-enabled") }
        set { BambuDefaults.shared.set(newValue, forKey: "quiet-hours-enabled") }
    }

    static var startMinutes: Int {
        get { BambuDefaults.shared.object(forKey: "quiet-hours-start") as? Int ?? 22 * 60 }
        set { BambuDefaults.shared.set(newValue, forKey: "quiet-hours-start") }
    }

    static var endMinutes: Int {
        get { BambuDefaults.shared.object(forKey: "quiet-hours-end") as? Int ?? 7 * 60 }
        set { BambuDefaults.shared.set(newValue, forKey: "quiet-hours-end") }
    }

    /// True when notifications should currently be silenced.
    static func isActive(at date: Date = Date()) -> Bool {
        guard isEnabled else { return false }
        let start = startMinutes, end = endMinutes
        guard start != end else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return start < end ? (now >= start && now < end) : (now >= start || now < end)
    }

    /// "22:00–07:00" for display in menus/labels.
    static func rangeLabel() -> String {
        func hhmm(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
        return "\(hhmm(startMinutes))–\(hhmm(endMinutes))"
    }
}
