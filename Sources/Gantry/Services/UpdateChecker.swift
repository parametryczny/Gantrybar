import Foundation

/// Periodically asks GitHub whether a newer release exists and, if so, posts one notification per
/// version. Tapping the notification opens the install flow (see NotificationService routing).
@MainActor
enum UpdateChecker {
    private static let notifiedKey = "update-notified-version"
    private static var timer: Timer?

    /// Checks shortly after launch and every six hours thereafter.
    static func start() {
        Task { await checkOnce() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await checkOnce() }
        }
    }

    static func checkOnce() async {
        guard !QuietHours.isActive() else { return }   // don't notify (or mark) during quiet hours
        guard let release = try? await UpdateService.latestRelease(),
              UpdateService.isNewer(release.version, than: UpdateService.currentVersion) else { return }
        // Only notify once per version so we don't nag on every check.
        guard BambuDefaults.shared.string(forKey: notifiedKey) != release.version else { return }
        BambuDefaults.shared.set(release.version, forKey: notifiedKey)

        let settings = AppSettings.shared
        NotificationService.post(
            title: settings.text("Dostępna aktualizacja Gantry", "Gantry update available", "Gantry-Update verfügbar"),
            body: settings.text("Wersja \(release.version) jest do pobrania. Kliknij, aby zainstalować.",
                                "Version \(release.version) is available. Click to install.",
                                "Version \(release.version) ist verfügbar. Klicke zum Installieren."),
            userInfo: ["type": "update"]
        )
    }
}
