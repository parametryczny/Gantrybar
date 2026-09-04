import AppKit

/// After the BambuBar → Gantry rename the old app can linger in /Applications as a duplicate. On the
/// first launch this offers to move it to the Trash — once, and only with the user's consent (never
/// deletes another app silently). Saved printers and codes are migrated separately, so removing the
/// old bundle loses nothing.
enum LegacyAppCleanup {
    private static let legacyBundleID = "pl.bambubar.app"
    private static let promptedKey = "gantry.offered-legacy-cleanup"

    @MainActor
    static func offerRemovalIfNeeded() {
        let defaults = BambuDefaults.shared
        guard !defaults.bool(forKey: promptedKey) else { return }

        guard let legacyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: legacyBundleID),
              legacyURL.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        // Ask at most once, whatever the answer.
        defaults.set(true, forKey: promptedKey)

        let settings = AppSettings.shared
        let alert = NSAlert()
        alert.messageText = settings.t("Old BambuBar app found")
        alert.informativeText = settings.t("Gantry replaces BambuBar. Move the old app to the Trash? Your printers and codes have already been migrated, so nothing is lost.")
        alert.addButton(withTitle: settings.t("Move to Trash"))
        alert.addButton(withTitle: settings.t("Keep"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        NSWorkspace.shared.recycle([legacyURL]) { _, _ in }
    }
}
