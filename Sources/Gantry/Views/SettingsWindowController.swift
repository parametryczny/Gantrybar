import AppKit
import Combine

@MainActor
final class SettingsWindowController: NSWindowController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let githubButton = NSButton()
    private let xButton = NSButton()
    private let languageLabel = NSTextField(labelWithString: "")
    private let appearanceLabel = NSTextField(labelWithString: "")
    private let languageControl = NSSegmentedControl(labels: ["PL", "EN"], trackingMode: .selectOne, target: nil, action: nil)
    private let themeControl = NSSegmentedControl(labels: ["LIGHT", "DARK"], trackingMode: .selectOne, target: nil, action: nil)
    private let transparencyLabel = NSTextField(labelWithString: "")
    private let transparencyControl = NSSegmentedControl(labels: ["1", "2", "3"], trackingMode: .selectOne, target: nil, action: nil)
    private let launchSwitch = NSSwitch()
    private let launchLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let supportButton = NSButton()
    private let supportSubtitle = NSTextField(wrappingLabelWithString: "")
    private let closeButton = NSButton()
    private let updateButton = NSButton()
    private let updateStatusLabel = NSTextField(labelWithString: "")
    private let notificationsLabel = NSTextField(labelWithString: "")
    private let notifyFinishedCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyErrorCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyPausedCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyLowFilamentCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyHumidityCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let quietHoursCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let quietStartPicker = NSDatePicker()
    private let quietEndPicker = NSDatePicker()
    private var settingsSubscription: AnyCancellable?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 512),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        buildInterface()
        refresh()
        settingsSubscription = AppSettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { nil }

    func presentCentered() {
        refresh()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        authorLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        authorLabel.textColor = .secondaryLabelColor

        configureProfileButton(githubButton, action: #selector(openGitHub))
        configureProfileButton(xButton, action: #selector(openX))
        let profileRow = NSStackView(views: [githubButton, xButton, NSView()])
        profileRow.orientation = .horizontal
        profileRow.alignment = .centerY
        profileRow.spacing = 14

        languageControl.target = self
        languageControl.action = #selector(languageChanged)
        languageControl.segmentStyle = .rounded
        languageControl.setWidth(70, forSegment: 0)
        languageControl.setWidth(70, forSegment: 1)

        themeControl.target = self
        themeControl.action = #selector(themeChanged)
        themeControl.segmentStyle = .rounded
        themeControl.setWidth(82, forSegment: 0)
        themeControl.setWidth(82, forSegment: 1)

        transparencyControl.target = self
        transparencyControl.action = #selector(transparencyChanged)
        transparencyControl.segmentStyle = .rounded
        for i in 0..<3 { transparencyControl.setWidth(72, forSegment: i) }

        launchSwitch.target = self
        launchSwitch.action = #selector(launchAtLoginChanged)
        let launchRow = NSStackView(views: [launchLabel, NSView(), launchSwitch])
        launchRow.orientation = .horizontal
        launchRow.alignment = .centerY

        let form = NSGridView(views: [
            [languageLabel, languageControl],
            [appearanceLabel, themeControl],
            [transparencyLabel, transparencyControl]
        ])
        languageLabel.textColor = .secondaryLabelColor
        appearanceLabel.textColor = .secondaryLabelColor
        transparencyLabel.textColor = .secondaryLabelColor
        form.rowSpacing = 12
        form.columnSpacing = 14
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .leading

        let separator = NSBox()
        separator.boxType = .separator

        versionLabel.textColor = .tertiaryLabelColor
        supportButton.target = self
        supportButton.action = #selector(openSupport)
        supportButton.bezelStyle = .rounded
        supportButton.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Support")
        supportButton.imagePosition = .imageLeading
        supportSubtitle.font = .systemFont(ofSize: 10)
        supportSubtitle.textColor = .tertiaryLabelColor
        supportSubtitle.alignment = .center
        closeButton.target = self
        closeButton.action = #selector(closeSettings)
        closeButton.keyEquivalent = "\r"
        let actionRow = NSStackView(views: [versionLabel, NSView(), closeButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        // Support lives at the very bottom, with a light-hearted one-liner beneath the button.
        let supportStack = NSStackView(views: [supportButton, supportSubtitle])
        supportStack.orientation = .vertical
        supportStack.alignment = .centerX
        supportStack.spacing = 3

        updateButton.target = self
        updateButton.action = #selector(checkForUpdates)
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Updates")
        updateButton.imagePosition = .imageLeading
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.lineBreakMode = .byTruncatingTail
        let updateRow = NSStackView(views: [updateButton, NSView(), updateStatusLabel])
        updateRow.orientation = .horizontal
        updateRow.alignment = .centerY
        updateRow.spacing = 8

        notificationsLabel.textColor = .secondaryLabelColor
        let notificationChecks = [notifyFinishedCheck, notifyErrorCheck, notifyPausedCheck, notifyLowFilamentCheck, notifyHumidityCheck]
        for check in notificationChecks {
            check.target = self
            check.action = #selector(notificationToggled)
        }
        let notificationsStack = NSStackView(views: [notificationsLabel] + notificationChecks)
        notificationsStack.orientation = .vertical
        notificationsStack.alignment = .leading
        notificationsStack.spacing = 6

        quietHoursCheck.target = self
        quietHoursCheck.action = #selector(quietHoursChanged)
        for picker in [quietStartPicker, quietEndPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinute
            picker.target = self
            picker.action = #selector(quietHoursChanged)
        }
        let quietDash = NSTextField(labelWithString: "–")
        quietDash.textColor = .secondaryLabelColor
        let quietRow = NSStackView(views: [quietHoursCheck, quietStartPicker, quietDash, quietEndPicker, NSView()])
        quietRow.orientation = .horizontal
        quietRow.alignment = .centerY
        quietRow.spacing = 6
        notificationsStack.addArrangedSubview(quietRow)

        let stack = NSStackView(views: [titleLabel, authorLabel, profileRow, form, launchRow, notificationsStack, separator, updateRow, actionRow, supportStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            profileRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            launchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notificationsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            updateRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            supportStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            supportSubtitle.widthAnchor.constraint(equalTo: supportStack.widthAnchor)
        ])
    }

    private func refresh() {
        guard let window else { return }
        let settings = AppSettings.shared
        window.appearance = settings.appearance
        window.title = settings.text("Ustawienia Gantry", "Gantry Settings")
        titleLabel.stringValue = settings.text("Ustawienia", "Settings")
        authorLabel.stringValue = "Kamil Grzegorczyk"
        githubButton.title = "@parametryczny on GitHub"
        xButton.title = "@parametryczny on X"
        languageLabel.stringValue = settings.text("Język:", "Language:")
        appearanceLabel.stringValue = settings.text("Wygląd:", "Appearance:")
        languageControl.selectedSegment = settings.language == .pl ? 0 : 1
        themeControl.setLabel(settings.text("JASNY", "LIGHT"), forSegment: 0)
        themeControl.setLabel(settings.text("CIEMNY", "DARK"), forSegment: 1)
        themeControl.selectedSegment = settings.theme == .light ? 0 : 1
        transparencyLabel.stringValue = settings.text("Przezroczystość:", "Transparency:")
        transparencyControl.setLabel(settings.text("NISKA", "LOW"), forSegment: 0)
        transparencyControl.setLabel(settings.text("ŚREDNIA", "MEDIUM"), forSegment: 1)
        transparencyControl.setLabel(settings.text("WYSOKA", "HIGH"), forSegment: 2)
        switch settings.panelTransparency {
        case .low: transparencyControl.selectedSegment = 0
        case .medium: transparencyControl.selectedSegment = 1
        case .high: transparencyControl.selectedSegment = 2
        }
        launchLabel.stringValue = settings.text("Uruchamiaj przy logowaniu", "Launch at login")
        launchSwitch.state = LaunchAtLoginManager.isEnabled ? .on : .off
        notificationsLabel.stringValue = settings.text("Powiadomienia:", "Notifications:")
        notifyFinishedCheck.title = settings.text("Druk zakończony", "Print finished")
        notifyErrorCheck.title = settings.text("Błąd drukarki", "Printer error")
        notifyPausedCheck.title = settings.text("Druk wstrzymany", "Print paused")
        notifyLowFilamentCheck.title = settings.text("Niski poziom filamentu", "Low filament")
        notifyHumidityCheck.title = settings.text("Wysoka wilgotność AMS", "High AMS humidity")
        notifyFinishedCheck.state = settings.notifyFinished ? .on : .off
        notifyErrorCheck.state = settings.notifyError ? .on : .off
        notifyPausedCheck.state = settings.notifyPaused ? .on : .off
        notifyLowFilamentCheck.state = settings.notifyLowFilament ? .on : .off
        notifyHumidityCheck.state = settings.notifyHumidity ? .on : .off
        quietHoursCheck.title = settings.text("Godziny ciszy (bez powiadomień)", "Quiet hours (no notifications)")
        quietHoursCheck.state = QuietHours.isEnabled ? .on : .off
        quietStartPicker.dateValue = date(fromMinutes: QuietHours.startMinutes)
        quietEndPicker.dateValue = date(fromMinutes: QuietHours.endMinutes)
        quietStartPicker.isEnabled = QuietHours.isEnabled
        quietEndPicker.isEnabled = QuietHours.isEnabled
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.19"
        versionLabel.stringValue = settings.text("Wersja \(version)", "Version \(version)") + " • \(AccessCodeStore.modeName)"
        supportButton.title = settings.text("Wesprzyj projekt", "Support the project")
        supportSubtitle.stringValue = settings.text(
            "Dobrą kawką nie pogardzę, a ta wirtualna daje mi kofeinowego kopa do działania nad kolejnymi projektami! 🚀 Jeśli chcesz dorzucić się do mojego kolejnego kubka i wesprzeć moje działania, kliknij „Wesprzyj projekt”.",
            "I never say no to good coffee, and this virtual one gives me a caffeine kick for my next projects! 🚀 If you'd like to chip in for my next cup and support what I do, click “Support the project”.")
        closeButton.title = settings.text("Gotowe", "Done")
        updateButton.title = settings.text("Sprawdź aktualizacje", "Check for updates")
    }

    @objc private func languageChanged() {
        AppSettings.shared.language = languageControl.selectedSegment == 0 ? .pl : .en
    }

    @objc private func quietHoursChanged() {
        QuietHours.isEnabled = quietHoursCheck.state == .on
        QuietHours.startMinutes = minutes(from: quietStartPicker.dateValue)
        QuietHours.endMinutes = minutes(from: quietEndPicker.dateValue)
        quietStartPicker.isEnabled = quietHoursCheck.state == .on
        quietEndPicker.isEnabled = quietHoursCheck.state == .on
    }

    private func date(fromMinutes total: Int) -> Date {
        Calendar.current.date(bySettingHour: total / 60, minute: total % 60, second: 0, of: Date()) ?? Date()
    }

    private func minutes(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    @objc private func themeChanged() {
        AppSettings.shared.theme = themeControl.selectedSegment == 0 ? .light : .dark
    }

    @objc private func transparencyChanged() {
        AppSettings.shared.panelTransparency = [.low, .medium, .high][transparencyControl.selectedSegment]
    }

    @objc private func launchAtLoginChanged() {
        do {
            try LaunchAtLoginManager.setEnabled(launchSwitch.state == .on)
        } catch {
            launchSwitch.state = LaunchAtLoginManager.isEnabled ? .on : .off
            NotificationService.post(title: "Gantry", body: error.localizedDescription)
        }
    }

    @objc private func notificationToggled() {
        let settings = AppSettings.shared
        settings.notifyFinished = notifyFinishedCheck.state == .on
        settings.notifyError = notifyErrorCheck.state == .on
        settings.notifyPaused = notifyPausedCheck.state == .on
        settings.notifyLowFilament = notifyLowFilamentCheck.state == .on
        settings.notifyHumidity = notifyHumidityCheck.state == .on
    }

    @objc private func checkForUpdates() {
        let settings = AppSettings.shared
        updateButton.isEnabled = false
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.stringValue = settings.text("Sprawdzam…", "Checking…")
        Task { @MainActor in
            defer { updateButton.isEnabled = true }
            do {
                let release = try await UpdateService.latestRelease()
                if UpdateService.isNewer(release.version, than: UpdateService.currentVersion) {
                    updateStatusLabel.stringValue = ""
                    presentUpdateAvailable(release)
                } else {
                    updateStatusLabel.stringValue = settings.text("Masz najnowszą wersję.", "You have the latest version.")
                }
            } catch {
                updateStatusLabel.stringValue = ""
                presentAlert(
                    title: settings.text("Nie udało się sprawdzić aktualizacji", "Could not check for updates"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func presentUpdateAvailable(_ release: UpdateService.Release) {
        let settings = AppSettings.shared
        let alert = NSAlert()
        alert.messageText = settings.text("Dostępna aktualizacja: \(release.version)", "Update available: \(release.version)")
        alert.informativeText = settings.text(
            "Masz wersję \(UpdateService.currentVersion). Zainstalować \(release.version)? Gantry pobierze aktualizację i uruchomi się ponownie.",
            "You have \(UpdateService.currentVersion). Install \(release.version)? Gantry will download the update and restart."
        )
        alert.addButton(withTitle: settings.text("Zainstaluj", "Install"))
        alert.addButton(withTitle: settings.text("Otwórz stronę", "Open page"))
        alert.addButton(withTitle: settings.text("Anuluj", "Cancel"))
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.installUpdate(release)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(release.pageURL)
            default: break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(alert.runModal()) }
    }

    private func installUpdate(_ release: UpdateService.Release) {
        let settings = AppSettings.shared
        updateButton.isEnabled = false
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.stringValue = settings.text("Pobieram i instaluję…", "Downloading and installing…")
        Task { @MainActor in
            do {
                try await UpdateService.downloadAndInstall(release)
                // The helper relaunches the app; this process is about to terminate.
            } catch {
                updateButton.isEnabled = true
                updateStatusLabel.stringValue = ""
                let alert = NSAlert()
                alert.messageText = settings.text("Instalacja nie powiodła się", "Installation failed")
                alert.informativeText = error.localizedDescription + "\n\n" + settings.text(
                    "Otwórz stronę wydania, aby pobrać ręcznie.",
                    "Open the release page to download it manually."
                )
                alert.addButton(withTitle: settings.text("Otwórz stronę", "Open page"))
                alert.addButton(withTitle: "OK")
                let openPage: (NSApplication.ModalResponse) -> Void = { response in
                    if response == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
                }
                if let window { alert.beginSheetModal(for: window, completionHandler: openPage) }
                else { openPage(alert.runModal()) }
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    @objc private func openSupport() {
        guard let url = URL(string: "https://buycoffee.to/parametryczny") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openGitHub() {
        guard let url = URL(string: "https://github.com/parametryczny") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openX() {
        guard let url = URL(string: "https://x.com/parametryczny") else { return }
        NSWorkspace.shared.open(url)
    }

    private func configureProfileButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .linkColor
    }

    @objc private func closeSettings() {
        close()
    }
}
