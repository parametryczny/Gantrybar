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
        alert.messageText = settings.text("Znaleziono starą aplikację BambuBar", "Old BambuBar app found", "Alte BambuBar-App gefunden")
        alert.informativeText = settings.text(
            "Gantry zastępuje BambuBar. Przenieść starą aplikację do Kosza? Twoje drukarki i kody zostały już przeniesione, więc nic nie stracisz.",
            "Gantry replaces BambuBar. Move the old app to the Trash? Your printers and codes have already been migrated, so nothing is lost.",
            "Gantry ersetzt BambuBar. Möchtest du die alte App in den Papierkorb verschieben? Deine Drucker und Codes wurden bereits übernommen."
        )
        alert.addButton(withTitle: settings.text("Przenieś do Kosza", "Move to Trash", "In den Papierkorb"))
        alert.addButton(withTitle: settings.text("Zostaw", "Keep", "Behalten"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        NSWorkspace.shared.recycle([legacyURL]) { _, _ in }
    }
}
