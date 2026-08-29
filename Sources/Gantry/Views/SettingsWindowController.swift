import AppKit
import Combine
import CoreImage

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
    private let spoolbaseSwitch = NSSwitch()
    private let spoolbaseLabel = NSTextField(labelWithString: "")
    private let developerSwitch = NSSwitch()
    private let developerLabel = NSTextField(labelWithString: "")
    private let scriptActionsSwitch = NSSwitch()
    private let scriptActionsLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let supportButton = NSButton()
    private let supportSubtitle = NSTextField(wrappingLabelWithString: "")
    private let closeButton = NSButton()
    private let updateButton = NSButton()
    private let updateStatusLabel = NSTextField(labelWithString: "")
    private let updatesTitleLabel = NSTextField(labelWithString: "")
    private let autoUpdateCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let appearanceSectionLabel = NSTextField(labelWithString: "")
    private let generalSectionLabel = NSTextField(labelWithString: "")
    private let cardsLabel = NSTextField(labelWithString: "")
    private let cardFileNameCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let cardProgressCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let cardTempsCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let cardFilamentsCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let cardSpoolGramsCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notificationsLabel = NSTextField(labelWithString: "")
    private let notifyFinishedCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyErrorCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyPausedCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyLowFilamentCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyHumidityCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let quietHoursCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let quietStartPicker = NSDatePicker()
    private let quietEndPicker = NSDatePicker()
    private let webSectionLabel = NSTextField(labelWithString: "")
    private let webEnableLabel = NSTextField(labelWithString: "")
    private let webEnableSwitch = NSSwitch()
    private let webPrimaryURL = NSTextField(labelWithString: "")
    private let webLanURL = NSTextField(labelWithString: "")
    private let webHint = NSTextField(wrappingLabelWithString: "")
    private let webQRImage = NSImageView()
    private let webContentRow = NSStackView()
    private let syncSectionLabel = NSTextField(labelWithString: "")
    private let syncTokenTitle = NSTextField(labelWithString: "")
    private let syncTokenValue = NSTextField(labelWithString: "")
    private let syncTokenRegenButton = NSButton()
    private let syncAddressTitle = NSTextField(labelWithString: "")
    private let syncAddressValue = NSTextField(labelWithString: "")
    private let syncPeerField = NSTextField()
    private let syncAddPeerButton = NSButton()
    private let syncTokenField = NSTextField()
    private let syncSetTokenButton = NSButton()
    private let syncNowButton = NSButton()
    private let syncPeersStack = NSStackView()
    private let syncHint = NSTextField(wrappingLabelWithString: "")
    private var settingsSubscription: AnyCancellable?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 440, height: 360)
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

    /// Wraps a section in a translucent card with a quiet uppercase title — the same visual language as
    /// the dashboard bento (GantryTheme.card + line border, radius 16).
    private func sectionCard(title: NSTextField, body: NSView) -> NSView {
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = GantryTheme.muted
        let inner = NSStackView(views: [title, body])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = GantryTheme.cardRadius
        card.layer?.backgroundColor = GantryTheme.card.withAlphaComponent(0.5).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = GantryTheme.line.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            body.widthAnchor.constraint(equalTo: inner.widthAnchor)
        ])
        return card
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = GantryTheme.canvas.cgColor

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = GantryTheme.text
        authorLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        authorLabel.textColor = GantryTheme.secondary

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

        spoolbaseSwitch.target = self
        spoolbaseSwitch.action = #selector(spoolbaseToggled)
        let spoolbaseRow = NSStackView(views: [spoolbaseLabel, NSView(), spoolbaseSwitch])
        spoolbaseRow.orientation = .horizontal
        spoolbaseRow.alignment = .centerY

        developerSwitch.target = self
        developerSwitch.action = #selector(developerToggled)
        developerLabel.font = .systemFont(ofSize: 12)
        let developerRow = NSStackView(views: [developerLabel, NSView(), developerSwitch])
        developerRow.orientation = .horizontal
        developerRow.alignment = .centerY

        scriptActionsSwitch.target = self
        scriptActionsSwitch.action = #selector(scriptActionsToggled)
        scriptActionsLabel.font = .systemFont(ofSize: 12)
        scriptActionsLabel.lineBreakMode = .byWordWrapping
        scriptActionsLabel.maximumNumberOfLines = 2
        let scriptActionsRow = NSStackView(views: [scriptActionsLabel, NSView(), scriptActionsSwitch])
        scriptActionsRow.orientation = .horizontal
        scriptActionsRow.alignment = .centerY

        let form = NSGridView(views: [
            [languageLabel, languageControl],
            [appearanceLabel, themeControl],
            [transparencyLabel, transparencyControl]
        ])
        languageLabel.textColor = GantryTheme.secondary
        appearanceLabel.textColor = GantryTheme.secondary
        transparencyLabel.textColor = GantryTheme.secondary
        form.rowSpacing = 12
        form.columnSpacing = 14
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .leading

        versionLabel.textColor = GantryTheme.muted
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
        updateStatusLabel.maximumNumberOfLines = 2
        updatesTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        autoUpdateCheck.target = self
        autoUpdateCheck.action = #selector(autoUpdateToggled)

        // Updates: check button + status on one row, the auto-install toggle below.
        let checkRow = NSStackView(views: [updateButton, NSView(), updateStatusLabel])
        checkRow.orientation = .horizontal
        checkRow.alignment = .centerY
        checkRow.spacing = 8
        let updatesBody = NSStackView(views: [checkRow, autoUpdateCheck])
        updatesBody.orientation = .vertical
        updatesBody.alignment = .leading
        updatesBody.spacing = 8

        let cardChecks = [cardFileNameCheck, cardProgressCheck, cardTempsCheck, cardFilamentsCheck, cardSpoolGramsCheck]
        for check in cardChecks {
            check.target = self
            check.action = #selector(cardContentToggled)
        }
        let cardsBody = NSStackView(views: cardChecks)
        cardsBody.orientation = .vertical
        cardsBody.alignment = .leading
        cardsBody.spacing = 6

        let notificationChecks = [notifyFinishedCheck, notifyErrorCheck, notifyPausedCheck, notifyLowFilamentCheck, notifyHumidityCheck]
        for check in notificationChecks {
            check.target = self
            check.action = #selector(notificationToggled)
        }
        quietHoursCheck.target = self
        quietHoursCheck.action = #selector(quietHoursChanged)
        for picker in [quietStartPicker, quietEndPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinute
            picker.target = self
            picker.action = #selector(quietHoursChanged)
        }
        let quietDash = NSTextField(labelWithString: "–")
        quietDash.textColor = GantryTheme.secondary
        let quietRow = NSStackView(views: [quietHoursCheck, quietStartPicker, quietDash, quietEndPicker, NSView()])
        quietRow.orientation = .horizontal
        quietRow.alignment = .centerY
        quietRow.spacing = 6
        let notificationsBody = NSStackView(views: notificationChecks + [quietRow])
        notificationsBody.orientation = .vertical
        notificationsBody.alignment = .leading
        notificationsBody.spacing = 6

        // General switches (launch, spoolbase, developer, scripts) grouped in one card.
        let generalBody = NSStackView(views: [launchRow, spoolbaseRow, developerRow, scriptActionsRow])
        generalBody.orientation = .vertical
        generalBody.alignment = .leading
        generalBody.spacing = 12

        // Web dashboard section: the LAN URLs to open on a phone, plus a scannable QR of the LAN URL.
        webPrimaryURL.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        webPrimaryURL.textColor = GantryTheme.text
        webPrimaryURL.isSelectable = true
        webLanURL.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        webLanURL.textColor = GantryTheme.secondary
        webLanURL.isSelectable = true
        webHint.font = .systemFont(ofSize: 11)
        webHint.textColor = GantryTheme.muted
        let webURLs = NSStackView(views: [webPrimaryURL, webLanURL, webHint])
        webURLs.orientation = .vertical
        webURLs.alignment = .leading
        webURLs.spacing = 6
        webURLs.setHuggingPriority(.defaultLow, for: .horizontal)

        webQRImage.imageScaling = .scaleProportionallyUpOrDown
        webQRImage.wantsLayer = true
        webQRImage.layer?.magnificationFilter = .nearest
        let qrHolder = NSView()
        qrHolder.wantsLayer = true
        qrHolder.layer?.backgroundColor = NSColor.white.cgColor
        qrHolder.layer?.cornerRadius = 10
        qrHolder.translatesAutoresizingMaskIntoConstraints = false
        webQRImage.translatesAutoresizingMaskIntoConstraints = false
        qrHolder.addSubview(webQRImage)
        NSLayoutConstraint.activate([
            qrHolder.widthAnchor.constraint(equalToConstant: 116),
            qrHolder.heightAnchor.constraint(equalToConstant: 116),
            webQRImage.leadingAnchor.constraint(equalTo: qrHolder.leadingAnchor, constant: 9),
            webQRImage.trailingAnchor.constraint(equalTo: qrHolder.trailingAnchor, constant: -9),
            webQRImage.topAnchor.constraint(equalTo: qrHolder.topAnchor, constant: 9),
            webQRImage.bottomAnchor.constraint(equalTo: qrHolder.bottomAnchor, constant: -9)
        ])
        webContentRow.setViews([webURLs, qrHolder], in: .leading)
        webContentRow.orientation = .horizontal
        webContentRow.alignment = .top
        webContentRow.spacing = 14

        // Master on/off for the whole server. Off = no listening socket at all.
        webEnableSwitch.target = self
        webEnableSwitch.action = #selector(webEnabledChanged)
        let webToggleRow = NSStackView(views: [webEnableLabel, NSView(), webEnableSwitch])
        webToggleRow.orientation = .horizontal
        webToggleRow.alignment = .centerY
        webToggleRow.spacing = 8

        let webBody = NSStackView(views: [webToggleRow, webContentRow])
        webBody.orientation = .vertical
        webBody.alignment = .leading
        webBody.spacing = 12
        webToggleRow.widthAnchor.constraint(equalTo: webBody.widthAnchor).isActive = true
        webContentRow.widthAnchor.constraint(equalTo: webBody.widthAnchor).isActive = true

        // Each section becomes a translucent bento card with a quiet title.
        let appearanceCard = sectionCard(title: appearanceSectionLabel, body: form)
        let generalCard = sectionCard(title: generalSectionLabel, body: generalBody)
        let cardsCard = sectionCard(title: cardsLabel, body: cardsBody)
        let notificationsCard = sectionCard(title: notificationsLabel, body: notificationsBody)
        let webCard = sectionCard(title: webSectionLabel, body: webBody)

        // Synchronizacja: token + address to pair, a field to paste the shared token, the peer list.
        syncTokenValue.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        syncTokenValue.textColor = GantryTheme.text
        syncTokenValue.isSelectable = true
        syncAddressValue.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        syncAddressValue.textColor = GantryTheme.secondary
        syncAddressValue.isSelectable = true
        [syncTokenTitle, syncAddressTitle].forEach { $0.font = .systemFont(ofSize: 11); $0.textColor = GantryTheme.muted }
        configureTextButton(syncTokenRegenButton, action: #selector(syncRegenToken))
        configureTextButton(syncAddPeerButton, action: #selector(syncAddPeer))
        configureTextButton(syncSetTokenButton, action: #selector(syncSetToken))
        configureTextButton(syncNowButton, action: #selector(syncNow))
        for field in [syncPeerField, syncTokenField] {
            field.font = .systemFont(ofSize: 12)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        }
        syncHint.font = .systemFont(ofSize: 11)
        syncHint.textColor = GantryTheme.muted

        let tokenRow = NSStackView(views: [syncTokenValue, NSView(), syncTokenRegenButton])
        tokenRow.orientation = .horizontal; tokenRow.alignment = .centerY; tokenRow.spacing = 8
        let tokenBlock = NSStackView(views: [syncTokenTitle, tokenRow])
        tokenBlock.orientation = .vertical; tokenBlock.alignment = .leading; tokenBlock.spacing = 3
        let addressBlock = NSStackView(views: [syncAddressTitle, syncAddressValue])
        addressBlock.orientation = .vertical; addressBlock.alignment = .leading; addressBlock.spacing = 3
        let addPeerRow = NSStackView(views: [syncPeerField, syncAddPeerButton])
        addPeerRow.orientation = .horizontal; addPeerRow.alignment = .centerY; addPeerRow.spacing = 8
        let setTokenRow = NSStackView(views: [syncTokenField, syncSetTokenButton])
        setTokenRow.orientation = .horizontal; setTokenRow.alignment = .centerY; setTokenRow.spacing = 8
        syncPeersStack.orientation = .vertical; syncPeersStack.alignment = .leading; syncPeersStack.spacing = 6
        let syncBody = NSStackView(views: [tokenBlock, addressBlock, addPeerRow, setTokenRow, syncPeersStack, syncNowButton, syncHint])
        syncBody.orientation = .vertical; syncBody.alignment = .leading; syncBody.spacing = 12
        for row in [tokenRow, tokenBlock, addressBlock, addPeerRow, setTokenRow, syncPeersStack] {
            row.widthAnchor.constraint(equalTo: syncBody.widthAnchor).isActive = true
        }
        let syncCard = sectionCard(title: syncSectionLabel, body: syncBody)

        let updatesCard = sectionCard(title: updatesTitleLabel, body: updatesBody)

        let header = NSStackView(views: [titleLabel, authorLabel, profileRow])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8

        let sectionCards = [appearanceCard, generalCard, cardsCard, notificationsCard, webCard, syncCard, updatesCard]
        let stack = NSStackView(views: [header] + sectionCards + [actionRow, supportStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The carded sections are taller than a fixed window, so the whole thing scrolls vertically.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        content.addSubview(scroll)

        // Rows carrying a trailing switch/control must span their body so the control sits flush right.
        // (form gets its width straight from the section-card helper: body == inner width.)
        let fullWidthRows: [(NSView, NSView)] = [
            (launchRow, generalBody), (spoolbaseRow, generalBody),
            (developerRow, generalBody), (scriptActionsRow, generalBody),
            (checkRow, updatesBody), (quietRow, notificationsBody)
        ]
        for (row, parent) in fullWidthRows {
            row.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            profileRow.widthAnchor.constraint(equalTo: header.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            supportStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            supportSubtitle.widthAnchor.constraint(equalTo: supportStack.widthAnchor)
        ] + sectionCards.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
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
        appearanceSectionLabel.stringValue = settings.text("WYGLĄD", "APPEARANCE")
        generalSectionLabel.stringValue = settings.text("OGÓLNE", "GENERAL")
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
        spoolbaseLabel.stringValue = settings.text("Spoolbase — magazyn filamentów", "Spoolbase — filament stock")
        spoolbaseSwitch.state = settings.spoolbaseEnabled ? .on : .off
        developerLabel.stringValue = settings.text("Tryb deweloperski (sterowanie + automatyzacje)",
                                                   "Developer mode (control + automations)")
        developerSwitch.state = settings.developerMode ? .on : .off
        scriptActionsLabel.stringValue = settings.text("Zezwól automatyzacjom na skrypty i własne komendy (domyślnie wył.)",
                                                       "Allow automations to run scripts and custom commands (off by default)")
        scriptActionsSwitch.state = settings.allowScriptActions ? .on : .off
        cardsLabel.stringValue = settings.text("KARTY DRUKAREK", "PRINTER CARDS")
        cardFileNameCheck.title = settings.text("Nazwa pliku", "File name")
        cardProgressCheck.title = settings.text("Postęp", "Progress")
        cardTempsCheck.title = settings.text("Temperatury", "Temperatures")
        cardFilamentsCheck.title = settings.text("Filamenty / AMS", "Filaments / AMS")
        cardSpoolGramsCheck.title = settings.text("Gramy na rolce (AMS NFC / Spoolbase)", "Grams on spool (AMS NFC / Spoolbase)")
        cardFileNameCheck.state = settings.cardShowFileName ? .on : .off
        cardProgressCheck.state = settings.cardShowProgress ? .on : .off
        cardTempsCheck.state = settings.cardShowTemperatures ? .on : .off
        cardFilamentsCheck.state = settings.cardShowFilaments ? .on : .off
        cardSpoolGramsCheck.state = settings.cardShowSpoolGrams ? .on : .off
        notificationsLabel.stringValue = settings.text("POWIADOMIENIA", "NOTIFICATIONS")
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
        refreshWebSection(settings)
        refreshSyncSection(settings)
        updatesTitleLabel.stringValue = settings.text("AKTUALIZACJE", "UPDATES")
        updateButton.title = settings.text("Sprawdź aktualizacje", "Check for updates")
        autoUpdateCheck.title = settings.text("Automatycznie pobieraj i instaluj aktualizacje",
                                              "Download and install updates automatically")
        autoUpdateCheck.state = settings.autoUpdate ? .on : .off
    }

    /// Fills the web-dashboard section with the live LAN URLs and a scannable QR of the IP URL
    /// (the IP always resolves on the same network, unlike the friendlier `.local` name).
    private func refreshWebSection(_ settings: AppSettings) {
        webSectionLabel.stringValue = settings.text("PODGLĄD W PRZEGLĄDARCE", "WEB DASHBOARD")
        webEnableLabel.stringValue = settings.text("Serwer podglądu (sieć lokalna)", "Preview server (local network)")
        webEnableLabel.font = .systemFont(ofSize: 13)
        webEnableLabel.textColor = GantryTheme.text
        webEnableSwitch.state = settings.webDashboardEnabled ? .on : .off
        webContentRow.isHidden = !settings.webDashboardEnabled
        guard settings.webDashboardEnabled else { return }
        let host = GantryWebServer.localHostName()
        let primary = GantryWebServer.primaryURL()
        let lan = GantryWebServer.lanURL()
        webPrimaryURL.stringValue = primary
        webLanURL.stringValue = lan ?? ""
        webLanURL.isHidden = (lan == nil) || (lan == primary)
        if host?.lowercased() == "gantry" {
            webHint.stringValue = settings.text(
                "Otwórz na telefonie w tej samej sieci Wi-Fi. Tylko podgląd.",
                "Open on a phone on the same Wi-Fi. View only.")
        } else {
            webHint.stringValue = settings.text(
                "Otwórz na telefonie w tej samej sieci Wi-Fi (tylko podgląd). Chcesz adres gantry.local? Zmień nazwę lokalną Maca na „gantry”: Ustawienia systemowe → Ogólne → Udostępnianie → Nazwa lokalna.",
                "Open on a phone on the same Wi-Fi (view only). Want gantry.local? Set the Mac's local hostname to “gantry”: System Settings → General → Sharing → Local hostname.")
        }
        // QR encodes the IP URL when available (most reliable to scan and open), else the primary URL.
        webQRImage.image = Self.makeQR(lan ?? primary, side: 320)
    }

    /// A crisp black-on-white QR NSImage for a URL, using CoreImage's built-in generator.
    private static func makeQR(_ string: String, side: CGFloat) -> NSImage? {
        guard let data = string.data(using: .ascii),
              let generator = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        generator.setValue(data, forKey: "inputMessage")
        generator.setValue("M", forKey: "inputCorrectionLevel")
        guard let coded = generator.outputImage else { return nil }
        // Force opaque black modules on a white background so it scans on any surface.
        guard let colored = CIFilter(name: "CIFalseColor") else { return nil }
        colored.setValue(coded, forKey: "inputImage")
        colored.setValue(CIColor(red: 0, green: 0, blue: 0), forKey: "inputColor0")
        colored.setValue(CIColor(red: 1, green: 1, blue: 1), forKey: "inputColor1")
        guard let output = colored.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    @objc private func webEnabledChanged() {
        AppSettings.shared.webDashboardEnabled = webEnableSwitch.state == .on
        refreshWebSection(AppSettings.shared)
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

    @objc private func developerToggled() {
        AppSettings.shared.developerMode = developerSwitch.state == .on
    }

    @objc private func scriptActionsToggled() {
        AppSettings.shared.allowScriptActions = scriptActionsSwitch.state == .on
    }

    @objc private func spoolbaseToggled() {
        AppSettings.shared.spoolbaseEnabled = spoolbaseSwitch.state == .on
    }

    @objc private func autoUpdateToggled() {
        AppSettings.shared.autoUpdate = autoUpdateCheck.state == .on
    }

    @objc private func notificationToggled() {
        let settings = AppSettings.shared
        settings.notifyFinished = notifyFinishedCheck.state == .on
        settings.notifyError = notifyErrorCheck.state == .on
        settings.notifyPaused = notifyPausedCheck.state == .on
        settings.notifyLowFilament = notifyLowFilamentCheck.state == .on
        settings.notifyHumidity = notifyHumidityCheck.state == .on
    }

    @objc private func cardContentToggled() {
        let settings = AppSettings.shared
        settings.cardShowFileName = cardFileNameCheck.state == .on
        settings.cardShowProgress = cardProgressCheck.state == .on
        settings.cardShowTemperatures = cardTempsCheck.state == .on
        settings.cardShowFilaments = cardFilamentsCheck.state == .on
        settings.cardShowSpoolGrams = cardSpoolGramsCheck.state == .on
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

    private func configureTextButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
    }

    // MARK: LAN sync section

    private func refreshSyncSection(_ settings: AppSettings) {
        syncSectionLabel.stringValue = settings.text("SYNCHRONIZACJA MIĘDZY KOMPUTERAMI", "SYNC BETWEEN COMPUTERS")
        syncTokenTitle.stringValue = settings.text("Wspólny token (skopiuj na drugi komputer)", "Shared token (copy to the other computer)")
        syncAddressTitle.stringValue = settings.text("Adres tego komputera", "This computer's address")
        syncTokenRegenButton.title = settings.text("Nowy", "New")
        syncAddPeerButton.title = settings.text("Dodaj", "Add")
        syncSetTokenButton.title = settings.text("Ustaw token", "Set token")
        syncNowButton.title = settings.text("Synchronizuj teraz", "Sync now")
        syncPeerField.placeholderString = settings.text("adres drugiego komputera, np. gantry.local", "other computer address, e.g. gantry.local")
        syncTokenField.placeholderString = settings.text("wklej token z drugiego komputera", "paste token from the other computer")
        syncHint.stringValue = settings.text(
            "Na drugim komputerze wklej powyższy token („Ustaw token”), potem dodaj adres tego komputera. Tylko sieć lokalna. Kody dostępu do drukarek nie są przesyłane.",
            "On the other computer paste this token (Set token), then add this computer's address. Local network only. Printer access codes are never sent.")

        guard let sync = SyncService.shared else {
            syncTokenValue.stringValue = "—"
            syncAddressValue.stringValue = "—"
            return
        }
        syncTokenValue.stringValue = sync.token
        syncAddressValue.stringValue = GantryWebServer.primaryURL().replacingOccurrences(of: "http://", with: "")

        // Rebuild the peers list.
        syncPeersStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if sync.peers.isEmpty {
            let none = NSTextField(labelWithString: settings.text("Brak sparowanych komputerów.", "No paired computers."))
            none.font = .systemFont(ofSize: 11); none.textColor = GantryTheme.muted
            syncPeersStack.addArrangedSubview(none)
        }
        for (index, peer) in sync.peers.enumerated() {
            let name = NSTextField(labelWithString: peer.address)
            name.font = .monospacedSystemFont(ofSize: 11, weight: .regular); name.textColor = GantryTheme.text
            let status = NSTextField(labelWithString: syncPeerStatus(peer, settings: settings))
            status.font = .systemFont(ofSize: 10); status.textColor = peer.lastError == nil ? GantryTheme.secondary : GantryTheme.statusPrinting
            let remove = NSButton(title: settings.text("Usuń", "Remove"), target: self, action: #selector(syncRemovePeer(_:)))
            configureTextButton(remove, action: #selector(syncRemovePeer(_:)))
            remove.tag = index
            let info = NSStackView(views: [name, status]); info.orientation = .vertical; info.alignment = .leading; info.spacing = 1
            let row = NSStackView(views: [info, NSView(), remove]); row.orientation = .horizontal; row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            syncPeersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: syncPeersStack.widthAnchor).isActive = true
        }
    }

    private func syncPeerStatus(_ peer: SyncPeer, settings: AppSettings) -> String {
        if let error = peer.lastError { return settings.text("Błąd: \(error)", "Error: \(error)") }
        guard let last = peer.lastSyncAt else { return settings.text("jeszcze nie zsynchronizowano", "not synced yet") }
        let formatter = DateFormatter(); formatter.dateStyle = .none; formatter.timeStyle = .short
        return settings.text("ostatnio: \(formatter.string(from: last))", "last: \(formatter.string(from: last))")
    }

    @objc private func syncRegenToken() {
        SyncService.shared?.regenerateToken()
        refresh()
    }

    @objc private func syncAddPeer() {
        let address = syncPeerField.stringValue
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        SyncService.shared?.addPeer(address: address)
        syncPeerField.stringValue = ""
        refresh()
    }

    @objc private func syncSetToken() {
        let token = syncTokenField.stringValue
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        SyncService.shared?.setToken(token)
        syncTokenField.stringValue = ""
        refresh()
    }

    @objc private func syncNow() {
        SyncService.shared?.syncNow()
    }

    @objc private func syncRemovePeer(_ sender: NSButton) {
        guard let sync = SyncService.shared, sender.tag >= 0, sender.tag < sync.peers.count else { return }
        sync.removePeer(sync.peers[sender.tag].id)
        refresh()
    }

    @objc private func closeSettings() {
        close()
    }
}

/// Top-down document view so the settings stack scrolls from the top, not the bottom.
private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
