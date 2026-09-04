import AppKit
import Combine
import CoreImage

/// The settings window: three tabs (General / Appearance / Advanced), each a scrolling column of
/// grouped cards. Every line is a `SettingsRowView`, so labels share one left column and controls one
/// right column across the whole window instead of each section inventing its own layout.
private enum SettingsTab: Int, CaseIterable {
    case general, appearance, advanced
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let store: PrinterStore

    // Chrome
    private let headerTitle = NSTextField(labelWithString: "")
    private let headerSubtitle = NSTextField(labelWithString: "")
    private let tabBar = SettingsTabBar(count: SettingsTab.allCases.count)
    private let pagesContainer = NSView()
    private var pages: [SettingsTab: NSScrollView] = [:]
    private var currentTab: SettingsTab = .general
    private let closeButton = NSButton()
    private let footerVersion = NSTextField(labelWithString: "")

    // MARK: General
    private let basicsGroupLabel = NSTextField(labelWithString: "")
    /// A popup, not a two-way segment: the list is whatever catalogs i18n/ contains, so a new
    /// language file appears here on its own.
    private let languageControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var languageRow = SettingsRowView(control: languageControl)
    private lazy var launchRow = SettingsToggleRow(target: self, action: #selector(launchAtLoginChanged))
    private lazy var spoolbaseRow = SettingsToggleRow(target: self, action: #selector(spoolbaseToggled))

    private let notificationsGroupLabel = NSTextField(labelWithString: "")
    private lazy var notifyFinishedRow = SettingsToggleRow(target: self, action: #selector(notificationToggled))
    private lazy var notifyFinishingSoonRow = SettingsToggleRow(target: self, action: #selector(notificationToggled))
    private lazy var notifyErrorRow = SettingsToggleRow(target: self, action: #selector(notificationToggled))
    private lazy var notifyPausedRow = SettingsToggleRow(target: self, action: #selector(notificationToggled))
    private lazy var notifyLowFilamentRow = SettingsToggleRow(target: self, action: #selector(notificationToggled))
    private lazy var notifyHumidityRow = SettingsToggleRow(target: self, action: #selector(notificationToggled))
    // Quiet hours keeps its two clocks on the same line as the label, so the control column stays a
    // single column: [from]–[to] then the switch, like every other row.
    private let quietStartPicker = NSDatePicker()
    private let quietEndPicker = NSDatePicker()
    private let quietHoursSwitch = NSSwitch()
    private lazy var quietHoursRow = SettingsRowView(control: quietControls)
    private lazy var quietControls: NSStackView = {
        let dash = NSTextField(labelWithString: "–")
        dash.textColor = GantryTheme.secondary
        // Every piece must hug its content, or whichever one hugs loosest absorbs the row's slack.
        for view in [dash, quietHoursSwitch] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        let stack = NSStackView(views: [quietStartPicker, dash, quietEndPicker, quietHoursSwitch])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(12, after: quietEndPicker)
        // NSStackView keeps its own hugging priority, and the horizontal default is low: without this
        // the stack stretches across the free width and its contents bunch up at the left end instead
        // of sitting in the control column with every other row.
        stack.setHuggingPriority(.required, for: .horizontal)
        return stack
    }()

    private let updatesGroupLabel = NSTextField(labelWithString: "")
    private let updateButton = NSButton()
    private lazy var updateRow = SettingsRowView(control: updateButton)
    private lazy var autoUpdateRow = SettingsToggleRow(target: self, action: #selector(autoUpdateToggled))

    private let aboutGroupLabel = NSTextField(labelWithString: "")
    private lazy var appRow = SettingsRowView(control: nil)
    private let githubButton = NSButton()
    private let xButton = NSButton()
    private lazy var githubRow = SettingsRowView(control: githubButton)
    private lazy var xRow = SettingsRowView(control: xButton)
    private let supportButton = NSButton()
    private let supportSubtitle = NSTextField(wrappingLabelWithString: "")

    // MARK: Appearance
    private let themeGroupLabel = NSTextField(labelWithString: "")
    private let themeControl = NSSegmentedControl(labels: ["LIGHT", "DARK"], trackingMode: .selectOne, target: nil, action: nil)
    private let transparencyControl = NSSegmentedControl(labels: ["1", "2", "3"], trackingMode: .selectOne, target: nil, action: nil)
    private lazy var themeRow = SettingsRowView(control: themeControl)
    private lazy var transparencyRow = SettingsRowView(control: transparencyControl)
    private lazy var monochromeRow = SettingsToggleRow(target: self, action: #selector(cardContentToggled))

    private let cardsGroupLabel = NSTextField(labelWithString: "")
    private lazy var cardFileNameRow = SettingsToggleRow(target: self, action: #selector(cardContentToggled))
    private lazy var cardProgressRow = SettingsToggleRow(target: self, action: #selector(cardContentToggled))
    private lazy var cardTempsRow = SettingsToggleRow(target: self, action: #selector(cardContentToggled))
    private lazy var cardFilamentsRow = SettingsToggleRow(target: self, action: #selector(cardContentToggled))
    private lazy var cardSpoolGramsRow = SettingsToggleRow(target: self, action: #selector(cardContentToggled))
    private lazy var cardDetailsChipRow = SettingsToggleRow(target: self, action: #selector(cardContentToggled))

    private let dockGroupLabel = NSTextField(labelWithString: "")
    private lazy var dockEnableRow = SettingsToggleRow(target: self, action: #selector(dockEnableToggled))
    private let dockEdgeControl = NSSegmentedControl(labels: ["L", "R"], trackingMode: .selectOne, target: nil, action: nil)
    private lazy var dockEdgeRow = SettingsRowView(control: dockEdgeControl)
    private lazy var dockOnlyPrintingRow = SettingsToggleRow(target: self, action: #selector(dockOnlyPrintingToggled))
    private let dockPrintersCaption = NSTextField(labelWithString: "")
    /// The per-printer list is its own card so it can be rebuilt wholesale when printers come and go,
    /// without disturbing the fixed rows above it.
    private let dockPrintersHolder = NSView()
    private var dockPrinterSerials: [String] = []
    private let dockHint = NSTextField(wrappingLabelWithString: "")

    // MARK: Advanced
    private let developerGroupLabel = NSTextField(labelWithString: "")
    private lazy var developerRow = SettingsToggleRow(target: self, action: #selector(developerToggled))
    private lazy var scriptActionsRow = SettingsToggleRow(target: self, action: #selector(scriptActionsToggled))

    private let telegramGroupLabel = NSTextField(labelWithString: "")
    private lazy var telegramEnableRow = SettingsToggleRow(target: self, action: #selector(telegramToggled))
    private let telegramTokenField = NSTextField()
    private let telegramChatField = NSTextField()
    private lazy var telegramTokenRow = SettingsRowView(control: telegramTokenField)
    private lazy var telegramChatRow = SettingsRowView(control: telegramChatField)
    private let telegramTestButton = NSButton()
    private lazy var telegramTestRow = SettingsRowView(control: telegramTestButton)
    private let telegramHint = NSTextField(wrappingLabelWithString: "")

    private let webGroupLabel = NSTextField(labelWithString: "")
    private lazy var webEnableRow = SettingsToggleRow(target: self, action: #selector(webEnabledChanged))
    private let webPrimaryURL = NSTextField(labelWithString: "")
    private let webLanURL = NSTextField(labelWithString: "")
    private let webHint = NSTextField(wrappingLabelWithString: "")
    private let webQRImage = NSImageView()
    private let webContentStack = NSStackView()
    private var webContentRow: SettingsContentRow?

    private let syncGroupLabel = NSTextField(labelWithString: "")
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

    init(store: PrinterStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 600, height: 520)
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

    // MARK: Layout helpers

    /// Stacks rows into one rounded card, separated by hairlines that start where the labels do.
    private func makeCard(_ rows: [NSView]) -> NSView {
        var interleaved: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { interleaved.append(makeSeparator()) }
            interleaved.append(row)
        }
        let stack = NSStackView(views: interleaved)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = GantryTheme.card.withAlphaComponent(0.55).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = GantryTheme.line.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ] + interleaved.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        return container
    }

    private func makeSeparator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = GantryTheme.line.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// A quiet uppercase caption above a card.
    private func makeGroup(_ title: NSTextField, _ rows: [NSView]) -> NSView {
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = GantryTheme.muted
        let card = makeCard(rows)
        let stack = NSStackView(views: [title, card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// One tab's scrolling column of groups.
    private func makePage(_ groups: [NSView]) -> NSScrollView {
        let stack = NSStackView(views: groups)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)
        ] + groups.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        return scroll
    }

    private func caption(_ field: NSTextField) -> NSTextField {
        field.font = .systemFont(ofSize: 11)
        field.textColor = GantryTheme.muted
        return field
    }

    // MARK: Interface

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = GantryTheme.canvas.cgColor

        headerTitle.font = .systemFont(ofSize: 19, weight: .bold)
        headerTitle.textColor = GantryTheme.text
        headerSubtitle.font = .systemFont(ofSize: 11)
        headerSubtitle.textColor = GantryTheme.muted
        let headerText = NSStackView(views: [headerTitle, headerSubtitle])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 1

        tabBar.onSelect = { [weak self] index in
            guard let tab = SettingsTab(rawValue: index) else { return }
            self?.show(tab: tab)
        }

        languageControl.target = self
        languageControl.action = #selector(languageChanged)
        configureSegmented(themeControl, action: #selector(themeChanged), widths: [82, 82])
        configureSegmented(transparencyControl, action: #selector(transparencyChanged), widths: [72, 72, 72])
        configureSegmented(dockEdgeControl, action: #selector(dockEdgeChanged), widths: [78, 78])

        pages[.general] = makePage(buildGeneralGroups())
        pages[.appearance] = makePage(buildAppearanceGroups())
        pages[.advanced] = makePage(buildAdvancedGroups())

        pagesContainer.translatesAutoresizingMaskIntoConstraints = false
        for page in pages.values {
            pagesContainer.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: pagesContainer.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: pagesContainer.trailingAnchor),
                page.topAnchor.constraint(equalTo: pagesContainer.topAnchor),
                page.bottomAnchor.constraint(equalTo: pagesContainer.bottomAnchor)
            ])
        }

        closeButton.target = self
        closeButton.action = #selector(closeSettings)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        footerVersion.font = .systemFont(ofSize: 11)
        footerVersion.textColor = GantryTheme.muted
        let footer = NSStackView(views: [footerVersion, NSView(), closeButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerLine = makeSeparator()

        for view in [headerText, tabBar, pagesContainer, footer, footerLine] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            // The title bar is transparent, so the header clears the traffic lights by hand.
            headerText.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            headerText.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            headerText.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -22),

            tabBar.topAnchor.constraint(equalTo: headerText.bottomAnchor, constant: 14),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),

            pagesContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 14),
            pagesContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pagesContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pagesContainer.bottomAnchor.constraint(equalTo: footerLine.topAnchor),

            footerLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerLine.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -11),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])

        show(tab: .general)
    }

    private func configureSegmented(_ control: NSSegmentedControl, action: Selector, widths: [CGFloat]) {
        control.target = self
        control.action = action
        control.segmentStyle = .rounded
        for (index, width) in widths.enumerated() { control.setWidth(width, forSegment: index) }
    }

    private func show(tab: SettingsTab) {
        currentTab = tab
        for (key, page) in pages { page.isHidden = key != tab }
        tabBar.select(tab.rawValue)
    }

    // MARK: Page contents

    private func buildGeneralGroups() -> [NSView] {
        for picker in [quietStartPicker, quietEndPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinute
            picker.target = self
            picker.action = #selector(quietHoursChanged)
            // Date pickers hug loosely, so the first one would swallow the row's free width.
            picker.setContentHuggingPriority(.required, for: .horizontal)
        }
        quietHoursSwitch.target = self
        quietHoursSwitch.action = #selector(quietHoursChanged)

        updateButton.target = self
        updateButton.action = #selector(checkForUpdates)
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Updates")
        updateButton.imagePosition = .imageLeading

        configureProfileButton(githubButton, action: #selector(openGitHub))
        configureProfileButton(xButton, action: #selector(openX))
        supportButton.target = self
        supportButton.action = #selector(openSupport)
        supportButton.bezelStyle = .rounded
        supportButton.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Support")
        supportButton.imagePosition = .imageLeading
        supportSubtitle.font = .systemFont(ofSize: 10)
        supportSubtitle.textColor = GantryTheme.muted
        let supportStack = NSStackView(views: [supportButton, supportSubtitle])
        supportStack.orientation = .vertical
        supportStack.alignment = .leading
        supportStack.spacing = 6
        let supportRow = SettingsContentRow(supportStack)
        supportSubtitle.widthAnchor.constraint(equalTo: supportStack.widthAnchor).isActive = true

        return [
            makeGroup(basicsGroupLabel, [languageRow, launchRow, spoolbaseRow]),
            makeGroup(notificationsGroupLabel, [notifyFinishedRow, notifyFinishingSoonRow, notifyErrorRow,
                                                notifyPausedRow, notifyLowFilamentRow, notifyHumidityRow,
                                                quietHoursRow]),
            makeGroup(updatesGroupLabel, [updateRow, autoUpdateRow]),
            makeGroup(aboutGroupLabel, [appRow, githubRow, xRow, supportRow])
        ]
    }

    private func buildAppearanceGroups() -> [NSView] {
        dockHint.font = .systemFont(ofSize: 11)
        dockHint.textColor = GantryTheme.muted
        _ = caption(dockPrintersCaption)
        dockPrintersCaption.font = .systemFont(ofSize: 10, weight: .semibold)
        dockPrintersHolder.translatesAutoresizingMaskIntoConstraints = false

        // The dock section is one heading over two cards: the fixed switches, then the printer list.
        dockGroupLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        dockGroupLabel.textColor = GantryTheme.muted
        let dockSettingsCard = makeCard([dockEnableRow, dockEdgeRow, dockOnlyPrintingRow])
        let dockGroup = NSStackView(views: [dockGroupLabel, dockSettingsCard,
                                            dockPrintersCaption, dockPrintersHolder, dockHint])
        dockGroup.orientation = .vertical
        dockGroup.alignment = .leading
        dockGroup.spacing = 7
        dockGroup.setCustomSpacing(16, after: dockSettingsCard)
        dockGroup.setCustomSpacing(10, after: dockPrintersHolder)
        dockGroup.translatesAutoresizingMaskIntoConstraints = false
        for view in [dockSettingsCard, dockPrintersHolder, dockHint] {
            view.widthAnchor.constraint(equalTo: dockGroup.widthAnchor).isActive = true
        }

        return [
            makeGroup(themeGroupLabel, [themeRow, transparencyRow, monochromeRow]),
            makeGroup(cardsGroupLabel, [cardFileNameRow, cardProgressRow, cardTempsRow,
                                        cardFilamentsRow, cardSpoolGramsRow, cardDetailsChipRow]),
            dockGroup
        ]
    }

    private func buildAdvancedGroups() -> [NSView] {
        for field in [telegramTokenField, telegramChatField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.bezelStyle = .roundedBezel
            field.target = self
            field.action = #selector(telegramFieldChanged)
            field.widthAnchor.constraint(equalToConstant: 250).isActive = true
        }
        telegramTokenField.placeholderString = "123456:ABC-DEF..."
        telegramChatField.placeholderString = "123456789"
        configureTextButton(telegramTestButton, action: #selector(telegramTest))
        telegramHint.font = .systemFont(ofSize: 11)
        telegramHint.textColor = GantryTheme.muted
        let telegramHintRow = SettingsContentRow(telegramHint)

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
        webContentStack.setViews([webURLs, qrHolder], in: .leading)
        webContentStack.orientation = .horizontal
        webContentStack.alignment = .top
        webContentStack.spacing = 14
        let webRow = SettingsContentRow(webContentStack)
        webContentRow = webRow

        // Sync: shared token, this machine's address, then pairing controls and the peer list.
        syncTokenValue.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        syncTokenValue.textColor = GantryTheme.text
        syncTokenValue.isSelectable = true
        syncAddressValue.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        syncAddressValue.textColor = GantryTheme.secondary
        syncAddressValue.isSelectable = true
        _ = caption(syncTokenTitle)
        _ = caption(syncAddressTitle)
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
        let syncBody = NSStackView(views: [tokenBlock, addressBlock, addPeerRow, setTokenRow,
                                           syncPeersStack, syncNowButton, syncHint])
        syncBody.orientation = .vertical; syncBody.alignment = .leading; syncBody.spacing = 12
        for row in [tokenRow, tokenBlock, addressBlock, addPeerRow, setTokenRow, syncPeersStack, syncHint] {
            row.widthAnchor.constraint(equalTo: syncBody.widthAnchor).isActive = true
        }
        let syncRow = SettingsContentRow(syncBody)

        return [
            makeGroup(developerGroupLabel, [developerRow, scriptActionsRow]),
            makeGroup(telegramGroupLabel, [telegramEnableRow, telegramTokenRow, telegramChatRow,
                                           telegramTestRow, telegramHintRow]),
            makeGroup(webGroupLabel, [webEnableRow, webRow]),
            makeGroup(syncGroupLabel, [syncRow])
        ]
    }

    // MARK: Refresh

    private func refresh() {
        guard let window else { return }
        let settings = AppSettings.shared
        window.appearance = settings.appearance
        window.title = settings.t("Gantry Settings")
        headerTitle.stringValue = settings.t("Settings")
        headerSubtitle.stringValue = "Gantry · @parametryczny"
        tabBar.setTitles([settings.t("General"),
                          settings.t("Appearance"),
                          settings.t("Advanced")])

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.19"
        footerVersion.stringValue = settings.t("Version {0}", version) + " • \(AccessCodeStore.modeName)"
        closeButton.title = settings.t("Done")

        refreshGeneral(settings, version: version)
        refreshAppearance(settings)
        refreshAdvanced(settings)
    }

    private func refreshGeneral(_ settings: AppSettings, version: String) {
        basicsGroupLabel.stringValue = settings.t("BASICS")
        languageRow.titleLabel.stringValue = settings.t("Language")
        let languages = Localization.available()
        languageControl.removeAllItems()
        for language in languages { languageControl.addItem(withTitle: language.name) }
        if let index = languages.firstIndex(where: { $0.code == settings.language }) {
            languageControl.selectItem(at: index)
        }
        launchRow.titleLabel.stringValue = settings.t("Launch at login")
        launchRow.isOn = LaunchAtLoginManager.isEnabled
        spoolbaseRow.titleLabel.stringValue = settings.t("Spoolbase")
        spoolbaseRow.setSubtitle(settings.t("Filament stock in the menu"))
        spoolbaseRow.isOn = settings.spoolbaseEnabled

        notificationsGroupLabel.stringValue = settings.t("NOTIFICATIONS")
        notifyFinishedRow.titleLabel.stringValue = settings.t("Print finished")
        notifyFinishedRow.isOn = settings.notifyFinished
        notifyFinishingSoonRow.titleLabel.stringValue = settings.t("Finishing in {0} minutes", settings.finishingSoonMinutes)
        notifyFinishingSoonRow.isOn = settings.notifyFinishingSoon
        notifyErrorRow.titleLabel.stringValue = settings.t("Printer error")
        notifyErrorRow.isOn = settings.notifyError
        notifyPausedRow.titleLabel.stringValue = settings.t("Print paused")
        notifyPausedRow.isOn = settings.notifyPaused
        notifyLowFilamentRow.titleLabel.stringValue = settings.t("Low filament")
        notifyLowFilamentRow.isOn = settings.notifyLowFilament
        notifyHumidityRow.titleLabel.stringValue = settings.t("High AMS humidity")
        notifyHumidityRow.isOn = settings.notifyHumidity
        // No explanatory line here: the two clocks already sit in the control column and would squeeze
        // a subtitle into four wrapped lines.
        quietHoursRow.titleLabel.stringValue = settings.t("Quiet hours")
        quietHoursSwitch.state = QuietHours.isEnabled ? .on : .off
        quietStartPicker.dateValue = date(fromMinutes: QuietHours.startMinutes)
        quietEndPicker.dateValue = date(fromMinutes: QuietHours.endMinutes)
        setQuietPickersEnabled(QuietHours.isEnabled)

        updatesGroupLabel.stringValue = settings.t("UPDATES")
        updateRow.titleLabel.stringValue = settings.t("Check for updates")
        updateButton.title = settings.t("Check")
        autoUpdateRow.titleLabel.stringValue = settings.t("Install automatically")
        autoUpdateRow.setSubtitle(settings.t("Downloads and verifies the release signature"))
        autoUpdateRow.isOn = settings.autoUpdate

        aboutGroupLabel.stringValue = settings.t("ABOUT GANTRY")
        appRow.titleLabel.stringValue = "Gantry"
        appRow.setSubtitle(settings.t("Version {0} • {1}", version, AccessCodeStore.modeName))
        githubRow.titleLabel.stringValue = "GitHub"
        githubButton.title = "@parametryczny"
        xRow.titleLabel.stringValue = "X"
        xButton.title = "@_parametryczny"
        supportButton.title = settings.t("Support the project")
        supportSubtitle.stringValue = settings.t("I never say no to good coffee, and this virtual one gives me a caffeine kick for my next projects! 🚀 If you'd like to chip in for my next cup and support what I do, click “Support the project”.")
    }

    private func refreshAppearance(_ settings: AppSettings) {
        themeGroupLabel.stringValue = settings.t("THEME")
        themeRow.titleLabel.stringValue = settings.t("Appearance")
        themeControl.setLabel(settings.t("LIGHT"), forSegment: 0)
        themeControl.setLabel(settings.t("DARK"), forSegment: 1)
        themeControl.selectedSegment = settings.theme == .light ? 0 : 1
        transparencyRow.titleLabel.stringValue = settings.t("Transparency")
        transparencyControl.setLabel(settings.t("LOW"), forSegment: 0)
        transparencyControl.setLabel(settings.t("MEDIUM"), forSegment: 1)
        transparencyControl.setLabel(settings.t("HIGH"), forSegment: 2)
        switch settings.panelTransparency {
        case .low: transparencyControl.selectedSegment = 0
        case .medium: transparencyControl.selectedSegment = 1
        case .high: transparencyControl.selectedSegment = 2
        }
        monochromeRow.titleLabel.stringValue = settings.t("Monochrome colours")
        monochromeRow.setSubtitle(settings.t("No tint on temperatures and filaments"))
        monochromeRow.isOn = settings.monochrome

        cardsGroupLabel.stringValue = settings.t("PRINTER CARDS")
        cardFileNameRow.titleLabel.stringValue = settings.t("File name")
        cardFileNameRow.isOn = settings.cardShowFileName
        cardProgressRow.titleLabel.stringValue = settings.t("Progress")
        cardProgressRow.isOn = settings.cardShowProgress
        cardTempsRow.titleLabel.stringValue = settings.t("Temperatures")
        cardTempsRow.isOn = settings.cardShowTemperatures
        cardFilamentsRow.titleLabel.stringValue = settings.t("Filaments / AMS")
        cardFilamentsRow.isOn = settings.cardShowFilaments
        cardSpoolGramsRow.titleLabel.stringValue = settings.t("Grams on spool")
        cardSpoolGramsRow.setSubtitle("AMS NFC / Spoolbase")
        cardSpoolGramsRow.isOn = settings.cardShowSpoolGrams
        cardDetailsChipRow.titleLabel.stringValue = settings.t("Details chip on the card")
        cardDetailsChipRow.setSubtitle(settings.t("Shortcut to the detail view; the ⋯ menu always has it"))
        cardDetailsChipRow.isOn = settings.cardShowDetailsChip

        dockGroupLabel.stringValue = settings.t("EDGE DOCK")
        dockEnableRow.titleLabel.stringValue = settings.t("Show the strip on top")
        dockEnableRow.isOn = settings.edgeDockEnabled
        dockEdgeRow.titleLabel.stringValue = settings.t("Edge")
        dockEdgeControl.setLabel(settings.t("LEFT"), forSegment: 0)
        dockEdgeControl.setLabel(settings.t("RIGHT"), forSegment: 1)
        dockEdgeControl.selectedSegment = settings.edgeDockEdge == .left ? 0 : 1
        dockEdgeControl.isEnabled = settings.edgeDockEnabled
        dockEdgeRow.alphaValue = settings.edgeDockEnabled ? 1 : 0.45
        dockOnlyPrintingRow.titleLabel.stringValue = settings.t("Only printing")
        dockOnlyPrintingRow.isOn = settings.edgeDockOnlyPrinting
        dockOnlyPrintingRow.setEnabled(settings.edgeDockEnabled)
        dockPrintersCaption.stringValue = settings.t("Which printers")
        dockHint.stringValue = settings.t("A narrow strip pinned to the screen edge, always on top. Hovering expands it to names, clicking opens details.")
        rebuildDockPrinters()
    }

    private func refreshAdvanced(_ settings: AppSettings) {
        developerGroupLabel.stringValue = settings.t("DEVELOPER")
        developerRow.titleLabel.stringValue = settings.t("Developer mode")
        developerRow.setSubtitle(settings.t("Reveals control and automations"))
        developerRow.isOn = settings.developerMode
        scriptActionsRow.titleLabel.stringValue = settings.t("Scripts in automations")
        scriptActionsRow.setSubtitle(settings.t("Lets a rule run a program or a raw command. Off by default."))
        scriptActionsRow.isOn = settings.allowScriptActions

        telegramGroupLabel.stringValue = "TELEGRAM"
        telegramEnableRow.titleLabel.stringValue = settings.t("Send notifications")
        telegramEnableRow.isOn = settings.telegramEnabled
        telegramTokenRow.titleLabel.stringValue = settings.t("Bot token")
        telegramChatRow.titleLabel.stringValue = "Chat ID"
        telegramTestRow.titleLabel.stringValue = settings.t("Connection test")
        telegramTestButton.title = settings.t("Send")
        telegramHint.stringValue = settings.t("Create a bot via @BotFather (token), message it, and get your chat_id from @userinfobot. Sends the same events as the system notifications.")
        telegramTokenField.stringValue = settings.telegramBotToken
        telegramChatField.stringValue = settings.telegramChatID
        telegramTokenField.isEnabled = settings.telegramEnabled
        telegramChatField.isEnabled = settings.telegramEnabled
        telegramTestButton.isEnabled = settings.telegramEnabled
        for row in [telegramTokenRow, telegramChatRow, telegramTestRow] {
            row.alphaValue = settings.telegramEnabled ? 1 : 0.45
        }

        refreshWebSection(settings)
        refreshSyncSection(settings)
    }

    /// Fills the web-dashboard section with the live LAN URLs and a scannable QR of the IP URL
    /// (the IP always resolves on the same network, unlike the friendlier `.local` name).
    private func refreshWebSection(_ settings: AppSettings) {
        webGroupLabel.stringValue = settings.t("WEB DASHBOARD")
        webEnableRow.titleLabel.stringValue = settings.t("Preview server")
        webEnableRow.setSubtitle(settings.t("Local network, read only"))
        webEnableRow.isOn = settings.webDashboardEnabled
        webContentRow?.isHidden = !settings.webDashboardEnabled
        guard settings.webDashboardEnabled else { return }
        let host = GantryWebServer.localHostName()
        let primary = GantryWebServer.primaryURL()
        let lan = GantryWebServer.lanURL()
        webPrimaryURL.stringValue = primary
        webLanURL.stringValue = lan ?? ""
        webLanURL.isHidden = (lan == nil) || (lan == primary)
        if host?.lowercased() == "gantry" {
            webHint.stringValue = settings.t("Open on a phone on the same Wi-Fi. View only.")
        } else {
            webHint.stringValue = settings.t("Open on a phone on the same Wi-Fi (view only). Want gantry.local? Set the Mac's local hostname to “gantry”: System Settings → General → Sharing → Local hostname.")
        }
        webQRImage.image = Self.makeQR(lan ?? primary, side: 320)
    }

    /// A crisp black-on-white QR NSImage for a URL, using CoreImage's built-in generator.
    private static func makeQR(_ string: String, side: CGFloat) -> NSImage? {
        guard let data = string.data(using: .ascii),
              let generator = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        generator.setValue(data, forKey: "inputMessage")
        generator.setValue("M", forKey: "inputCorrectionLevel")
        guard let coded = generator.outputImage else { return nil }
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

    // MARK: Actions

    @objc private func webEnabledChanged() {
        AppSettings.shared.webDashboardEnabled = webEnableRow.isOn
        refreshWebSection(AppSettings.shared)
    }

    @objc private func languageChanged() {
        let languages = Localization.available()
        let index = languageControl.indexOfSelectedItem
        guard index >= 0, index < languages.count else { return }
        AppSettings.shared.language = languages[index].code
    }

    @objc private func quietHoursChanged() {
        let enabled = quietHoursSwitch.state == .on
        QuietHours.isEnabled = enabled
        QuietHours.startMinutes = minutes(from: quietStartPicker.dateValue)
        QuietHours.endMinutes = minutes(from: quietEndPicker.dateValue)
        setQuietPickersEnabled(enabled)
    }

    /// Only the clocks dim when quiet hours are off; the switch itself has to stay fully legible.
    private func setQuietPickersEnabled(_ enabled: Bool) {
        for picker in [quietStartPicker, quietEndPicker] {
            picker.isEnabled = enabled
            picker.alphaValue = enabled ? 1 : 0.4
        }
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
            try LaunchAtLoginManager.setEnabled(launchRow.isOn)
        } catch {
            launchRow.isOn = LaunchAtLoginManager.isEnabled
            NotificationService.post(title: "Gantry", body: error.localizedDescription)
        }
    }

    @objc private func developerToggled() {
        AppSettings.shared.developerMode = developerRow.isOn
    }

    @objc private func scriptActionsToggled() {
        AppSettings.shared.allowScriptActions = scriptActionsRow.isOn
    }

    @objc private func spoolbaseToggled() {
        AppSettings.shared.spoolbaseEnabled = spoolbaseRow.isOn
    }

    @objc private func autoUpdateToggled() {
        AppSettings.shared.autoUpdate = autoUpdateRow.isOn
    }

    @objc private func notificationToggled() {
        let settings = AppSettings.shared
        settings.notifyFinished = notifyFinishedRow.isOn
        settings.notifyError = notifyErrorRow.isOn
        settings.notifyPaused = notifyPausedRow.isOn
        settings.notifyFinishingSoon = notifyFinishingSoonRow.isOn
        settings.notifyLowFilament = notifyLowFilamentRow.isOn
        settings.notifyHumidity = notifyHumidityRow.isOn
    }

    @objc private func cardContentToggled() {
        let settings = AppSettings.shared
        settings.cardShowFileName = cardFileNameRow.isOn
        settings.cardShowProgress = cardProgressRow.isOn
        settings.cardShowTemperatures = cardTempsRow.isOn
        settings.cardShowFilaments = cardFilamentsRow.isOn
        settings.cardShowSpoolGrams = cardSpoolGramsRow.isOn
        settings.cardShowDetailsChip = cardDetailsChipRow.isOn
        settings.monochrome = monochromeRow.isOn
    }

    // MARK: Edge dock

    @objc private func dockEnableToggled() {
        AppSettings.shared.edgeDockEnabled = dockEnableRow.isOn
    }

    @objc private func dockEdgeChanged() {
        AppSettings.shared.edgeDockEdge = dockEdgeControl.selectedSegment == 0 ? .left : .right
    }

    @objc private func dockOnlyPrintingToggled() {
        AppSettings.shared.edgeDockOnlyPrinting = dockOnlyPrintingRow.isOn
    }

    /// The serial rides in the switch's identifier because the list is rebuilt whenever refresh()
    /// runs, so a captured index would go stale.
    @objc private func dockPrinterToggled(_ sender: NSSwitch) {
        let serial = sender.identifier?.rawValue ?? ""
        guard !serial.isEmpty else { return }
        var hidden = AppSettings.shared.edgeDockHiddenPrinters
        if sender.state == .on { hidden.remove(serial) } else { hidden.insert(serial) }
        AppSettings.shared.edgeDockHiddenPrinters = hidden
    }

    /// Rebuilds the printer card only when the fleet itself changed; otherwise just re-syncs the
    /// switches, so refresh() does not throw away and recreate views on every settings change.
    private func rebuildDockPrinters() {
        let settings = AppSettings.shared
        let serials = store.printers.map(\.serial)
        guard serials != dockPrinterSerials || dockPrintersHolder.subviews.isEmpty else {
            syncDockPrinterSwitches()
            return
        }
        dockPrinterSerials = serials
        dockPrintersHolder.subviews.forEach { $0.removeFromSuperview() }

        var rows: [NSView] = []
        if store.printers.isEmpty {
            let empty = SettingsRowView(control: nil, minHeight: 40)
            empty.titleLabel.stringValue = settings.t("No printers")
            empty.titleLabel.textColor = GantryTheme.muted
            rows.append(empty)
        }
        for printer in store.printers {
            let toggle = NSSwitch()
            toggle.identifier = NSUserInterfaceItemIdentifier(printer.serial)
            toggle.target = self
            toggle.action = #selector(dockPrinterToggled(_:))
            let row = SettingsRowView(control: toggle, minHeight: 40)
            row.titleLabel.stringValue = printer.name
            row.setSubtitle(printer.model)
            rows.append(row)
        }
        let card = makeCard(rows)
        dockPrintersHolder.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: dockPrintersHolder.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: dockPrintersHolder.trailingAnchor),
            card.topAnchor.constraint(equalTo: dockPrintersHolder.topAnchor),
            card.bottomAnchor.constraint(equalTo: dockPrintersHolder.bottomAnchor)
        ])
        syncDockPrinterSwitches()
    }

    private func syncDockPrinterSwitches() {
        let settings = AppSettings.shared
        let hidden = settings.edgeDockHiddenPrinters
        for row in dockPrintersHolder.subviews.first?.subviews.first?.subviews ?? [] {
            guard let row = row as? SettingsRowView else { continue }
            row.alphaValue = settings.edgeDockEnabled ? 1 : 0.45
            for control in row.subviews {
                guard let toggle = control as? NSSwitch, let serial = toggle.identifier?.rawValue else { continue }
                toggle.state = hidden.contains(serial) ? .off : .on
                toggle.isEnabled = settings.edgeDockEnabled
            }
        }
    }

    // MARK: Telegram

    @objc private func telegramToggled() {
        AppSettings.shared.telegramEnabled = telegramEnableRow.isOn
        refreshAdvanced(AppSettings.shared)
        TelegramBot.shared?.syncWithSettings()
    }

    @objc private func telegramFieldChanged() {
        AppSettings.shared.telegramBotToken = telegramTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.shared.telegramChatID = telegramChatField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        TelegramBot.shared?.syncWithSettings()
    }

    @objc private func telegramTest() {
        telegramFieldChanged()   // persist whatever is typed before sending
        let settings = AppSettings.shared
        let token = settings.telegramBotToken, chat = settings.telegramChatID
        guard !token.isEmpty, !chat.isEmpty else {
            telegramTestRow.setSubtitle(settings.t("Enter a token and chat_id."))
            telegramTestRow.subtitleLabel.textColor = GantryTheme.statusError
            return
        }
        telegramTestRow.setSubtitle(settings.t("Sending…"))
        telegramTestRow.subtitleLabel.textColor = GantryTheme.muted
        let text = TelegramService.format(printer: "Gantry", title: settings.t("Test notification"),
                                          body: settings.t("The connection works."))
        Task { @MainActor in
            let ok = await TelegramService.sendMessage(token: token, chatID: chat, text: text)
            telegramTestRow.setSubtitle(ok ? settings.t("Sent ✓")
                                           : settings.t("Failed. Check the token and chat_id."))
            telegramTestRow.subtitleLabel.textColor = ok ? GantryTheme.statusFinished : GantryTheme.statusError
        }
    }

    // MARK: Updates

    @objc private func checkForUpdates() {
        let settings = AppSettings.shared
        updateButton.isEnabled = false
        updateRow.subtitleLabel.textColor = GantryTheme.muted
        updateRow.setSubtitle(settings.t("Checking…"))
        Task { @MainActor in
            defer { updateButton.isEnabled = true }
            do {
                let release = try await UpdateService.latestRelease()
                if UpdateService.isNewer(release.version, than: UpdateService.currentVersion) {
                    updateRow.setSubtitle("")
                    presentUpdateAvailable(release)
                } else {
                    updateRow.setSubtitle(settings.t("You have the latest version."))
                }
            } catch {
                updateRow.setSubtitle("")
                presentAlert(
                    title: settings.t("Could not check for updates"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func presentUpdateAvailable(_ release: UpdateService.Release) {
        let settings = AppSettings.shared
        let alert = NSAlert()
        alert.messageText = settings.t("Update available: {0}", release.version)
        alert.informativeText = settings.t("You have {0}. Install {1}? Gantry will download the update and restart.", UpdateService.currentVersion, release.version)
        alert.addButton(withTitle: settings.t("Install"))
        alert.addButton(withTitle: settings.t("Open page"))
        alert.addButton(withTitle: settings.t("Cancel"))
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
        updateRow.subtitleLabel.textColor = GantryTheme.muted
        updateRow.setSubtitle(settings.t("Downloading and installing…"))
        Task { @MainActor in
            do {
                try await UpdateService.downloadAndInstall(release)
                // The helper relaunches the app; this process is about to terminate.
            } catch {
                updateButton.isEnabled = true
                updateRow.setSubtitle("")
                let alert = NSAlert()
                alert.messageText = settings.t("Installation failed")
                alert.informativeText = error.localizedDescription + "\n\n" + settings.t("Open the release page to download it manually.")
                alert.addButton(withTitle: settings.t("Open page"))
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
        guard let url = URL(string: "https://x.com/_parametryczny") else { return }
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
        syncGroupLabel.stringValue = settings.t("SYNC BETWEEN COMPUTERS")
        syncTokenTitle.stringValue = settings.t("Shared token (copy to the other computer)")
        syncAddressTitle.stringValue = settings.t("This computer's address")
        syncTokenRegenButton.title = settings.t("New")
        syncAddPeerButton.title = settings.t("Add")
        syncSetTokenButton.title = settings.t("Set token")
        syncNowButton.title = settings.t("Sync now")
        syncPeerField.placeholderString = settings.t("other computer address, e.g. gantry.local")
        syncTokenField.placeholderString = settings.t("paste token from the other computer")
        syncHint.stringValue = settings.t("On the other computer paste this token (Set token), then add this computer's address. Local network only. Printer access codes are never sent.")

        guard let sync = SyncService.shared else {
            syncTokenValue.stringValue = "—"
            syncAddressValue.stringValue = "—"
            return
        }
        syncTokenValue.stringValue = sync.token
        syncAddressValue.stringValue = GantryWebServer.primaryURL().replacingOccurrences(of: "http://", with: "")

        syncPeersStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if sync.peers.isEmpty {
            let none = NSTextField(labelWithString: settings.t("No paired computers."))
            none.font = .systemFont(ofSize: 11); none.textColor = GantryTheme.muted
            syncPeersStack.addArrangedSubview(none)
        }
        for (index, peer) in sync.peers.enumerated() {
            let name = NSTextField(labelWithString: peer.address)
            name.font = .monospacedSystemFont(ofSize: 11, weight: .regular); name.textColor = GantryTheme.text
            let status = NSTextField(labelWithString: syncPeerStatus(peer, settings: settings))
            status.font = .systemFont(ofSize: 10); status.textColor = peer.lastError == nil ? GantryTheme.secondary : GantryTheme.statusPrinting
            let remove = NSButton(title: settings.t("Remove"), target: self, action: #selector(syncRemovePeer(_:)))
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
        if let error = peer.lastError { return settings.t("Error: {0}", error) }
        guard let last = peer.lastSyncAt else { return settings.t("not synced yet") }
        let formatter = DateFormatter(); formatter.dateStyle = .none; formatter.timeStyle = .short
        return settings.t("last: {0}", formatter.string(from: last))
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
