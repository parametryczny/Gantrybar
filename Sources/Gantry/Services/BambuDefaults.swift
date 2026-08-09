import Foundation

enum BambuDefaults {
    nonisolated(unsafe) static let shared: UserDefaults = {
        let defaults = UserDefaults.standard
        migrateLegacyIfNeeded(into: defaults)
        return defaults
    }()

    /// One-time copy of settings saved by the pre-rebrand app (bundle id pl.bambubar.app) into the
    /// current domain, so an upgrade keeps saved printers, certificate pins and preferences.
    private static func migrateLegacyIfNeeded(into defaults: UserDefaults) {
        let flag = "gantry.migrated-from-bambubar"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        guard let legacy = defaults.persistentDomain(forName: "pl.bambubar.app") else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
