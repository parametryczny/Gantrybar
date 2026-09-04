import Foundation

/// Periodically asks GitHub whether a newer release exists. With auto-update off it posts one
/// notification per version (tap to install). With auto-update on it downloads, verifies the
/// signature and installs silently, then the relaunched app confirms it (announceInstalledIfPending).
@MainActor
enum UpdateChecker {
    private static let notifiedKey = "update-notified-version"
    private static let installedPendingKey = "update-installed-pending"
    private static var timer: Timer?

    /// Checks shortly after launch and every six hours thereafter.
    static func start() {
        announceInstalledIfPending()
        Task { await checkOnce() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await checkOnce() }
        }
    }

    static func checkOnce() async {
        guard let release = try? await UpdateService.latestRelease(),
              UpdateService.isNewer(release.version, than: UpdateService.currentVersion) else { return }
        let settings = AppSettings.shared

        if settings.autoUpdate {
            // Remember the target so the relaunched app can confirm the install; downloadAndInstall
            // verifies the signature and terminates this process on success.
            BambuDefaults.shared.set(release.version, forKey: installedPendingKey)
            do {
                try await UpdateService.downloadAndInstall(release)
            } catch {
                BambuDefaults.shared.removeObject(forKey: installedPendingKey)
                guard !QuietHours.isActive() else { return }
                NotificationService.post(
                    title: settings.t("Update failed"),
                    body: error.localizedDescription,
                    userInfo: ["type": "update"])
            }
            return
        }

        guard !QuietHours.isActive() else { return }   // don't notify (or mark) during quiet hours
        // Only notify once per version so we don't nag on every check.
        guard BambuDefaults.shared.string(forKey: notifiedKey) != release.version else { return }
        BambuDefaults.shared.set(release.version, forKey: notifiedKey)
        NotificationService.post(
            title: settings.t("Gantry update available"),
            body: settings.t("Version {0} is available. Click to install.", release.version),
            userInfo: ["type": "update"])
    }

    /// Called at launch: if the app was just auto-installed, confirm it's done and verified. Only
    /// fires when the running version matches the one we installed, so a failed swap stays silent.
    static func announceInstalledIfPending() {
        guard let pending = BambuDefaults.shared.string(forKey: installedPendingKey) else { return }
        BambuDefaults.shared.removeObject(forKey: installedPendingKey)
        guard pending == UpdateService.currentVersion else { return }
        let settings = AppSettings.shared
        NotificationService.post(
            title: settings.t("Gantry updated"),
            body: settings.t("Installed version {0}. Signature verified — all good.", pending),
            userInfo: ["type": "updated"])
    }
}
