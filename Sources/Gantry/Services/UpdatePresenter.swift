import AppKit

/// Alert-based "check for updates" flow for entry points without their own status UI
/// (currently the status-bar menu). The Settings window keeps its inline-label variant;
/// both share the networking and install logic in ``UpdateService``.
@MainActor
enum UpdatePresenter {
    /// Checks GitHub for a newer release and, depending on the result, offers to install it,
    /// reports that the app is current, or surfaces the failure — all through modal alerts.
    static func checkAndPresent(from window: NSWindow?) {
        Task { @MainActor in
            let settings = AppSettings.shared
            do {
                let release = try await UpdateService.latestRelease()
                if UpdateService.isNewer(release.version, than: UpdateService.currentVersion) {
                    presentUpdateAvailable(release, from: window)
                } else {
                    present(
                        title: settings.text("Masz najnowszą wersję", "You have the latest version", "Du hast die neueste Version"),
                        message: settings.text("Wersja \(UpdateService.currentVersion) jest aktualna.",
                                               "Version \(UpdateService.currentVersion) is up to date.",
                                               "Version \(UpdateService.currentVersion) ist aktuell."),
                        from: window
                    )
                }
            } catch {
                present(
                    title: settings.text("Nie udało się sprawdzić aktualizacji", "Could not check for updates", "Updates konnten nicht geprüft werden"),
                    message: error.localizedDescription,
                    from: window
                )
            }
        }
    }

    private static func presentUpdateAvailable(_ release: UpdateService.Release, from window: NSWindow?) {
        let settings = AppSettings.shared
        let alert = NSAlert()
        alert.messageText = settings.text("Dostępna aktualizacja: \(release.version)", "Update available: \(release.version)", "Update verfügbar: \(release.version)")
        alert.informativeText = settings.text(
            "Masz wersję \(UpdateService.currentVersion). Zainstalować \(release.version)? Gantry pobierze aktualizację i uruchomi się ponownie.",
            "You have \(UpdateService.currentVersion). Install \(release.version)? Gantry will download the update and restart.",
            "Du hast \(UpdateService.currentVersion). Möchtest du \(release.version) installieren? Gantry lädt das Update herunter und startet neu."
        )
        alert.addButton(withTitle: settings.text("Zainstaluj", "Install", "Installieren"))
        alert.addButton(withTitle: settings.text("Otwórz stronę", "Open page", "Seite öffnen"))
        alert.addButton(withTitle: settings.text("Anuluj", "Cancel", "Abbrechen"))
        run(alert, from: window) { response in
            switch response {
            case .alertFirstButtonReturn: installUpdate(release, from: window)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(release.pageURL)
            default: break
            }
        }
    }

    private static func installUpdate(_ release: UpdateService.Release, from window: NSWindow?) {
        Task { @MainActor in
            let settings = AppSettings.shared
            do {
                try await UpdateService.downloadAndInstall(release)
                // The helper relaunches the app; this process is about to terminate.
            } catch {
                let alert = NSAlert()
                alert.messageText = settings.text("Instalacja nie powiodła się", "Installation failed", "Installation fehlgeschlagen")
                alert.informativeText = error.localizedDescription + "\n\n" + settings.text(
                    "Otwórz stronę wydania, aby pobrać ręcznie.",
                    "Open the release page to download it manually.",
                    "Öffne die Release-Seite, um das Update manuell herunterzuladen."
                )
                alert.addButton(withTitle: settings.text("Otwórz stronę", "Open page", "Seite öffnen"))
                alert.addButton(withTitle: "OK")
                run(alert, from: window) { response in
                    if response == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
                }
            }
        }
    }

    private static func present(title: String, message: String, from window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        run(alert, from: window) { _ in }
    }

    private static func run(_ alert: NSAlert, from window: NSWindow?, handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            handler(alert.runModal())
        }
    }
}
