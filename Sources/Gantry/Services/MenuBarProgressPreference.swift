import Foundation

/// Tracks which printers the user pinned to the menu bar (a per-printer checkbox in the edit
/// window). Each pinned printer gets its own extra status item showing live progress. Stored as a
/// list of serials in defaults so it needs no change to the SavedPrinter model or its migration.
enum MenuBarProgressPreference {
    private static let key = "menu-bar-progress-serials"

    static func serials() -> [String] {
        BambuDefaults.shared.stringArray(forKey: key) ?? []
    }

    static func isEnabled(_ serial: String) -> Bool {
        serials().contains(serial)
    }

    static func setEnabled(_ enabled: Bool, for serial: String) {
        var current = serials()
        if enabled {
            guard !current.contains(serial) else { return }
            current.append(serial)
        } else {
            current.removeAll { $0 == serial }
        }
        BambuDefaults.shared.set(current, forKey: key)
    }

    /// Drops serials no longer backed by a saved printer (e.g. after removing a printer).
    static func prune(keeping validSerials: [String]) {
        let valid = Set(validSerials)
        let filtered = serials().filter { valid.contains($0) }
        if filtered.count != serials().count {
            BambuDefaults.shared.set(filtered, forKey: key)
        }
    }
}
