import AppKit
import Combine
import CoreImage

/// The settings window, built the way macOS builds its own: an `NSTabViewController` in toolbar mode
/// inside a close-only title bar. AppKit then owns the toolbar, the icons, the switching animation,
/// the window title (it is always the active pane's name, so it also reads correctly in the Window
/// menu) and the resize between panes. None of that is drawn here any more.
///
/// What this replaced: a fixed 640 by 720 window with its own `#0C0D0E` canvas, a hand-built pill tab
/// bar, a large bold header, rounded sections with hairline borders, a footer with a Done button, and
/// three tabs, one of which carried the whole look-and-feel, the card contents, the floating window
/// and the entire edge dock with its printer list. That tab was the reason the window felt scattered.
///
/// Six panes now, one idea each, and none of them scrolls. Only the chrome and the layout changed:
/// every setting, every action and the whole refresh path are the ones that were already here.
private enum SettingsPaneID: String {
    case general, appearance, notifications, windows, integrations, advanced

    /// LITE has no Spoolbase, no updates, no floating window, no edge dock, no Telegram, no web
    /// dashboard and no developer switches, which empties three of the six panes. It therefore shows
    /// the first three, and the About section moves into General because there is no Advanced pane
    /// left to hold it.
    static var visible: [SettingsPaneID] {
        Build.isLite ? [.general, .appearance, .notifications]
                     : [.general, .appearance, .notifications, .windows, .integrations, .advanced]
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .notifications: "bell"
        case .windows: "macwindow.on.rectangle"
        case .integrations: "antenna.radiowaves.left.and.right"
        case .advanced: "slider.horizontal.3"
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: PrinterStore
    private let tabController = SettingsTabViewController()
    private var panes: [SettingsPaneID: SettingsPane] = [:]
    /// The one thing that actually sets the window's height.
    ///
    /// Measured, not assumed. A pane's own view knows its height from its content, but `NSTabView`
    /// gives its children frames rather than constraints, so that height never reaches the window:
    /// the width did reach it, because every pane carries an explicit width constraint, and the
    /// heights were simply ignored. `preferredContentSize` was no better, on the child (nothing
    /// happened at all) or on the tab controller (the window took the first pane's height, then the
    /// tallest pane's, and kept it). This constraint lives on the content view controller's own view,
    /// which is inside the window's constraint chain, so changing it resizes the window and nothing
    /// races it.
    private var paneHeight: NSLayoutConstraint?

    // MARK: General
    /// A popup, not a two-way segment: the list is whatever catalogs i18n/ contains, so a new
    /// language file appears here on its own.
    private let languageControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageCaption = settingsCaption()
    private lazy var launchCheck = SettingsCheckbox(target: self, action: #selector(launchAtLoginChanged))
    private lazy var spoolbaseCheck = SettingsCheckbox(target: self, action: #selector(spoolbaseToggled))
    private let basicsCaption = settingsCaption()

    private let updatesHeading = settingsHeading()
    private let updateButton = NSButton()
    private let updateCaption = settingsCaption()
    private let updateStatus = settingsNote()
    private lazy var autoUpdateCheck = SettingsCheckbox(target: self, action: #selector(autoUpdateToggled))

    private let aboutHeading = settingsHeading()
    private let appCaption = settingsCaption()
    private let appVersionLabel = NSTextField(labelWithString: "")
    private let githubCaption = settingsCaption()
    private let xCaption = settingsCaption()
    private let githubButton = NSButton()
    private let xButton = NSButton()
    private let supportButton = NSButton()
    private let supportSubtitle = settingsNote()

    // MARK: Notifications
    private let notificationsCaption = settingsCaption()
    private lazy var notifyFinishedCheck = SettingsCheckbox(target: self, action: #selector(notificationToggled))
    private lazy var notifyFinishingSoonCheck = SettingsCheckbox(target: self, action: #selector(notificationToggled))
    private lazy var notifyErrorCheck = SettingsCheckbox(target: self, action: #selector(notificationToggled))
    private lazy var notifyPausedCheck = SettingsCheckbox(target: self, action: #selector(notificationToggled))
    private lazy var notifyLowFilamentCheck = SettingsCheckbox(target: self, action: #selector(notificationToggled))
    private lazy var notifyHumidityCheck = SettingsCheckbox(target: self, action: #selector(notificationToggled))
    private lazy var quietHoursCheck = SettingsCheckbox(target: self, action: #selector(quietHoursChanged))
    private let quietStartPicker = NSDatePicker()
    private let quietEndPicker = NSDatePicker()
    private let quietRangeCaption = settingsCaption()
    private lazy var quietControls: NSStackView = {
        let separator = NSTextField(labelWithString: "")
        separator.font = .systemFont(ofSize: 13)
        separator.textColor = .secondaryLabelColor
        quietSeparatorLabel = separator
        // Every piece must hug its content, or whichever one hugs loosest absorbs the row's slack.
        for view in [separator, quietStartPicker, quietEndPicker] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        let stack = NSStackView(views: [quietStartPicker, separator, quietEndPicker])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setHuggingPriority(.required, for: .horizontal)
        return stack
    }()
    private var quietSeparatorLabel: NSTextField?

    // MARK: Appearance
    private let themeControl = NSSegmentedControl(labels: ["LIGHT", "DARK"], trackingMode: .selectOne, target: nil, action: nil)
    private let transparencyControl = NSSegmentedControl(labels: ["1", "2", "3"], trackingMode: .selectOne, target: nil, action: nil)
    private let themeCaption = settingsCaption()
    private let transparencyCaption = settingsCaption()
    private lazy var monochromeCheck = SettingsCheckbox(target: self, action: #selector(cardContentToggled))

    private let cardsHeading = settingsHeading()
    private let cardScaleCaption = settingsCaption()
    private let cardScaleControl = SettingsScaleControl()
    private let cardContentCaption = settingsCaption()
    private lazy var cardFileNameCheck = SettingsCheckbox(target: self, action: #selector(cardContentToggled))
    private lazy var cardProgressCheck = SettingsCheckbox(target: self, action: #selector(cardContentToggled))
    private lazy var cardTempsCheck = SettingsCheckbox(target: self, action: #selector(cardContentToggled))
    private lazy var cardFilamentsCheck = SettingsCheckbox(target: self, action: #selector(cardContentToggled))
    private lazy var cardSpoolGramsCheck = SettingsCheckbox(target: self, action: #selector(cardContentToggled))
    private lazy var cardDetailsChipCheck = SettingsCheckbox(target: self, action: #selector(cardContentToggled))

    // MARK: Windows and the strip
    private let floatingWindowCaption = settingsCaption()
    private lazy var floatingWindowCheck = SettingsCheckbox(target: self, action: #selector(floatingWindowToggled))

    private let dockHeading = settingsHeading()
    private lazy var dockEnableCheck = SettingsCheckbox(target: self, action: #selector(dockEnableToggled))
    private let dockEdgeControl = NSSegmentedControl(labels: ["L", "R"], trackingMode: .selectOne, target: nil, action: nil)
    private let dockEdgeCaption = settingsCaption()
    private let dockScaleControl = SettingsScaleControl()
    private let dockScaleCaption = settingsCaption()
    private let dockBehaviourCaption = settingsCaption()
    private lazy var dockPinnedCheck = SettingsCheckbox(target: self, action: #selector(dockPinnedToggled))
    private lazy var dockCameraCheck = SettingsCheckbox(target: self, action: #selector(dockCameraToggled))
    private lazy var dockOnlyPrintingCheck = SettingsCheckbox(target: self, action: #selector(dockOnlyPrintingToggled))
    private let dockPrintersCaption = settingsCaption()
    /// The per-printer list is a real list in a bordered scroller, so a large fleet scrolls instead of
    /// stretching the window past the screen.
    private let dockPrintersStack = NSStackView()
    private let dockPrintersScroll = NSScrollView()
    private var dockPrintersHeight: NSLayoutConstraint?
    private var dockPrinterSerials: [String] = []
    private let dockHint = settingsNote()

    // MARK: Integrations
    private let telegramHeading = settingsHeading()
    private lazy var telegramEnableCheck = SettingsCheckbox(target: self, action: #selector(telegramToggled))
    private let telegramTokenField = NSTextField()
    private let telegramChatField = NSTextField()
    private let telegramTokenCaption = settingsCaption()
    private let telegramChatCaption = settingsCaption()
    private let telegramTestButton = NSButton()
    private let telegramTestCaption = settingsCaption()
    private let telegramTestStatus = settingsNote()
    private let telegramHint = settingsNote()

    private let webHeading = settingsHeading()
    private lazy var webEnableCheck = SettingsCheckbox(target: self, action: #selector(webEnabledChanged))
    private let webPrimaryURL = NSTextField(labelWithString: "")
    private let webLanURL = NSTextField(labelWithString: "")
    private let webHint = settingsNote(width: 200)
    private let webQRImage = NSImageView()
    private let webContentStack = NSStackView()

    // MARK: Advanced
    private let featuresCaption = settingsCaption()
    private lazy var developerCheck = SettingsCheckbox(target: self, action: #selector(developerToggled))
    private lazy var printerControlCheck = SettingsCheckbox(target: self, action: #selector(printerControlToggled))
    private lazy var scriptActionsCheck = SettingsCheckbox(target: self, action: #selector(scriptActionsToggled))

    private var settingsSubscription: AnyCancellable?
    var onClose: (() -> Void)?

    init(store: PrinterStore) {
        self.store = store
        // No size here on purpose. The window takes its size from the active pane, which is what a
        // system settings window does, and it is why the contract no longer pins one.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // The toolbar style that puts the pane icons under the title, centred, the way every system
        // settings pane looks. Without this AppKit lays the toolbar out like a document window's.
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        buildPanes()
        window.contentViewController = tabController
        let height = tabController.view.heightAnchor.constraint(equalToConstant: 274)
        height.isActive = true
        paneHeight = height
        refresh()
        settingsSubscription = AppSettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Centred on the screen, always. It used to be centred on the fleet panel, which parked it
    /// straight on top of the cards the user had just come to adjust. `companion` only lends its
    /// window level, so the panel cannot end up covering the settings window they are typing in.
    func presentCentered(levelMatching companion: NSWindow? = nil) {
        refresh()
        showWindow(nil)
        guard let window else { return }
        window.level = companion?.level ?? .normal
        resizeToSelectedPane()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.level = .normal
        onClose?()
    }

    // MARK: Panes

    private func buildPanes() {
        languageControl.target = self
        languageControl.action = #selector(languageChanged)
        configureSegmented(themeControl, action: #selector(themeChanged), widths: [82, 82])
        configureSegmented(transparencyControl, action: #selector(transparencyChanged), widths: [72, 72, 72])
        configureSegmented(dockEdgeControl, action: #selector(dockEdgeChanged), widths: [78, 78])
        cardScaleControl.onStep = { [weak self] direction in self?.changeCardScale(direction) }
        dockScaleControl.onStep = { [weak self] direction in self?.changeDockScale(direction) }

        var items: [NSTabViewItem] = []
        for id in SettingsPaneID.visible {
            let pane = SettingsPane(identifier: id.rawValue, symbolName: id.symbolName,
                                    content: content(for: id))
            panes[id] = pane
            let item = NSTabViewItem(viewController: pane)
            item.image = NSImage(systemSymbolName: id.symbolName, accessibilityDescription: nil)
            item.identifier = id.rawValue
            items.append(item)
        }
        tabController.tabViewItems = items
        tabController.onSelect = { [weak self] in self?.resizeToSelectedPane(animated: true) }
    }

    private func content(for id: SettingsPaneID) -> NSGridView {
        switch id {
        case .general: buildGeneralPane()
        case .appearance: buildAppearancePane()
        case .notifications: buildNotificationsPane()
        case .windows: buildWindowsPane()
        case .integrations: buildIntegrationsPane()
        case .advanced: buildAdvancedPane()
        }
    }

    private func buildGeneralPane() -> NSGridView {
        updateButton.target = self
        updateButton.action = #selector(checkForUpdates)
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .regular

        let grid = SettingsGrid()
        grid.field(languageCaption, languageControl)
        // Spoolbase is a full-edition tool, so LITE's basics are language and launch at login only.
        grid.group(basicsCaption, Build.hasExtras ? [launchCheck, spoolbaseCheck] : [launchCheck])
        if Build.hasExtras {
            // LITE never checks for or installs updates, so it has no updates section at all.
            grid.section(updatesHeading)
            grid.field(updateCaption, updateButton)
            grid.aligned(updateStatus)
            grid.aligned(autoUpdateCheck)
        } else {
            appendAbout(to: grid)
        }
        return grid.build()
    }

    private func buildAppearancePane() -> NSGridView {
        let grid = SettingsGrid()
        grid.field(themeCaption, themeControl)
        grid.field(transparencyCaption, transparencyControl)
        grid.aligned(monochromeCheck)
        grid.section(cardsHeading)
        grid.field(cardScaleCaption, cardScaleControl, baseline: false)
        // The card-content switches LITE does not build would otherwise write their default back over
        // the stored value the moment the user touched any other one.
        let cardContent: [NSView] = Build.hasExtras
            ? [cardFileNameCheck, cardProgressCheck, cardTempsCheck, cardFilamentsCheck,
               cardSpoolGramsCheck, cardDetailsChipCheck]
            : [cardFileNameCheck, cardProgressCheck, cardTempsCheck, cardFilamentsCheck]
        grid.group(cardContentCaption, cardContent)
        return grid.build()
    }

    private func buildNotificationsPane() -> NSGridView {
        for picker in [quietStartPicker, quietEndPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinute
            picker.target = self
            picker.action = #selector(quietHoursChanged)
            picker.setContentHuggingPriority(.required, for: .horizontal)
        }

        let grid = SettingsGrid()
        grid.group(notificationsCaption, [notifyFinishedCheck, notifyFinishingSoonCheck,
                                          notifyErrorCheck, notifyPausedCheck,
                                          notifyLowFilamentCheck, notifyHumidityCheck])
        grid.separator()
        grid.aligned(quietHoursCheck)
        grid.field(quietRangeCaption, quietControls, baseline: false)
        return grid.build()
    }

    private func buildWindowsPane() -> NSGridView {
        dockPrintersStack.orientation = .vertical
        dockPrintersStack.alignment = .leading
        dockPrintersStack.spacing = 5
        dockPrintersStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        dockPrintersStack.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(dockPrintersStack)
        NSLayoutConstraint.activate([
            dockPrintersStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            dockPrintersStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            dockPrintersStack.topAnchor.constraint(equalTo: document.topAnchor),
            dockPrintersStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        dockPrintersScroll.documentView = document
        dockPrintersScroll.hasVerticalScroller = true
        dockPrintersScroll.autohidesScrollers = true
        dockPrintersScroll.borderType = .bezelBorder
        dockPrintersScroll.drawsBackground = true
        dockPrintersScroll.translatesAutoresizingMaskIntoConstraints = false
        let height = dockPrintersScroll.heightAnchor.constraint(equalToConstant: 96)
        dockPrintersHeight = height
        NSLayoutConstraint.activate([
            dockPrintersScroll.widthAnchor.constraint(equalToConstant: SettingsMetrics.controlColumn),
            document.widthAnchor.constraint(equalTo: dockPrintersScroll.contentView.widthAnchor),
            height
        ])

        let grid = SettingsGrid()
        grid.group(floatingWindowCaption, [floatingWindowCheck])
        grid.section(dockHeading)
        grid.aligned(dockEnableCheck)
        grid.field(dockEdgeCaption, dockEdgeControl)
        grid.field(dockScaleCaption, dockScaleControl, baseline: false)
        grid.group(dockBehaviourCaption, [dockPinnedCheck, dockCameraCheck, dockOnlyPrintingCheck])
        grid.field(dockPrintersCaption, dockPrintersScroll, baseline: false)
        grid.aligned(dockHint)
        return grid.build()
    }

    private func buildIntegrationsPane() -> NSGridView {
        for field in [telegramTokenField, telegramChatField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.bezelStyle = .roundedBezel
            field.target = self
            field.action = #selector(telegramFieldChanged)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 250).isActive = true
        }
        telegramTokenField.placeholderString = "123456:ABC-DEF..."
        telegramChatField.placeholderString = "123456789"
        telegramTestButton.target = self
        telegramTestButton.action = #selector(telegramTest)
        telegramTestButton.bezelStyle = .rounded

        webPrimaryURL.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        webPrimaryURL.textColor = .labelColor
        webPrimaryURL.isSelectable = true
        webLanURL.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        webLanURL.textColor = .secondaryLabelColor
        webLanURL.isSelectable = true
        let webURLs = NSStackView(views: [webPrimaryURL, webLanURL, webHint])
        webURLs.orientation = .vertical
        webURLs.alignment = .leading
        webURLs.spacing = 5
        webQRImage.imageScaling = .scaleProportionallyUpOrDown
        webQRImage.wantsLayer = true
        webQRImage.layer?.magnificationFilter = .nearest
        let qrHolder = NSView()
        qrHolder.wantsLayer = true
        qrHolder.layer?.backgroundColor = NSColor.white.cgColor
        qrHolder.layer?.cornerRadius = 8
        qrHolder.translatesAutoresizingMaskIntoConstraints = false
        webQRImage.translatesAutoresizingMaskIntoConstraints = false
        qrHolder.addSubview(webQRImage)
        NSLayoutConstraint.activate([
            qrHolder.widthAnchor.constraint(equalToConstant: 104),
            qrHolder.heightAnchor.constraint(equalToConstant: 104),
            webQRImage.leadingAnchor.constraint(equalTo: qrHolder.leadingAnchor, constant: 8),
            webQRImage.trailingAnchor.constraint(equalTo: qrHolder.trailingAnchor, constant: -8),
            webQRImage.topAnchor.constraint(equalTo: qrHolder.topAnchor, constant: 8),
            webQRImage.bottomAnchor.constraint(equalTo: qrHolder.bottomAnchor, constant: -8)
        ])
        webContentStack.setViews([webURLs, qrHolder], in: .leading)
        webContentStack.orientation = .horizontal
        webContentStack.alignment = .top
        webContentStack.spacing = 12

        let grid = SettingsGrid()
        grid.wide(telegramHeading)
        grid.aligned(telegramEnableCheck)
        grid.field(telegramTokenCaption, telegramTokenField)
        grid.field(telegramChatCaption, telegramChatField)
        grid.field(telegramTestCaption, telegramTestButton)
        grid.aligned(telegramTestStatus)
        grid.aligned(telegramHint)
        grid.section(webHeading)
        grid.aligned(webEnableCheck)
        grid.aligned(webContentStack)
        return grid.build()
    }

    private func buildAdvancedPane() -> NSGridView {
        let grid = SettingsGrid()
        grid.group(featuresCaption, [printerControlCheck, developerCheck, scriptActionsCheck])
        appendAbout(to: grid)
        return grid.build()
    }

    /// Version, the two profiles and the coffee. Its own section under Advanced in the full edition,
    /// and folded into General in LITE, which builds no Advanced pane.
    private func appendAbout(to grid: SettingsGrid) {
        configureProfileButton(githubButton, action: #selector(openGitHub))
        configureProfileButton(xButton, action: #selector(openX))
        supportButton.target = self
        supportButton.action = #selector(openSupport)
        supportButton.bezelStyle = .rounded
        supportButton.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Support")
        supportButton.imagePosition = .imageLeading
        appVersionLabel.font = .systemFont(ofSize: 13)
        appVersionLabel.textColor = .secondaryLabelColor

        grid.section(aboutHeading)
        grid.field(appCaption, appVersionLabel)
        grid.field(githubCaption, githubButton)
        grid.field(xCaption, xButton)
        grid.aligned(supportButton)
        grid.aligned(supportSubtitle)
    }

    private func configureSegmented(_ control: NSSegmentedControl, action: Selector, widths: [CGFloat]) {
        control.target = self
        control.action = action
        control.segmentStyle = .rounded
        for (index, width) in widths.enumerated() { control.setWidth(width, forSegment: index) }
    }

    /// Resizes the window around the active pane, and titles it after that pane.
    ///
    /// Both are done by hand on purpose. Handing the pane's `preferredContentSize` up to the tab
    /// controller and letting AppKit propagate it only worked for some panes: measured across all six,
    /// the window took the first pane's height, ignored the next two, then took the fourth's and kept
    /// it. The window title had the same problem, staying on whichever pane happened to be selected
    /// first, because AppKit syncs it from the toolbar's own selection rather than from the tab view.
    /// Setting the frame and the title here is a line of code either way and it is deterministic.
    ///
    /// The top edge stays put while the bottom moves, which is what a settings window does; letting
    /// `setContentSize` keep the origin instead would grow the window upward off the screen.
    private func resizeToSelectedPane(animated: Bool = false) {
        let index = tabController.selectedTabViewItemIndex
        guard let window, index >= 0, index < tabController.tabViewItems.count else { return }
        window.title = tabController.tabViewItems[index].label
        guard let pane = tabController.tabViewItems[index].viewController as? SettingsPane else { return }
        pane.updatePreferredSize()
        let target = pane.preferredContentSize.height
        guard target > 1, let height = paneHeight, abs(height.constant - target) > 0.5 else { return }
        guard animated, window.isVisible else {
            height.constant = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            height.constant = target
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: Refresh

    private func refresh() {
        guard let window else { return }
        let settings = AppSettings.shared
        window.appearance = settings.appearance

        // The toolbar labels follow the app's language, and AppKit takes the window title from the
        // active one, so both are set from the same place.
        for item in tabController.tabViewItems {
            guard let id = (item.identifier as? String).flatMap(SettingsPaneID.init(rawValue:)) else { continue }
            item.label = paneTitle(id, settings)
        }
        let index = tabController.selectedTabViewItemIndex
        if index >= 0, index < tabController.tabViewItems.count {
            window.title = tabController.tabViewItems[index].label
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.19"
        refreshGeneral(settings, version: version)
        refreshAppearance(settings)
        if Build.hasExtras { refreshAdvanced(settings) }
        resizeToSelectedPane()
    }

    private func paneTitle(_ id: SettingsPaneID, _ settings: AppSettings) -> String {
        switch id {
        case .general: settings.t("General")
        case .appearance: settings.t("Appearance")
        case .notifications: settings.t("Notifications")
        case .windows: settings.t("Windows and strip")
        case .integrations: settings.t("Integrations")
        case .advanced: settings.t("Advanced")
        }
    }

    private func refreshGeneral(_ settings: AppSettings, version: String) {
        languageCaption.stringValue = settings.t("Language") + ":"
        let languages = Localization.available()
        languageControl.removeAllItems()
        for language in languages { languageControl.addItem(withTitle: language.name) }
        if let index = languages.firstIndex(where: { $0.code == settings.language }) {
            languageControl.selectItem(at: index)
        }
        basicsCaption.stringValue = settings.t("Options") + ":"
        launchCheck.title = settings.t("Launch at login")
        launchCheck.isOn = LaunchAtLoginManager.isEnabled
        if Build.hasExtras {
            spoolbaseCheck.title = settings.t("Spoolbase")
            spoolbaseCheck.setSubtitle(settings.t("Filament stock in the menu"))
            spoolbaseCheck.isOn = settings.spoolbaseEnabled

            updatesHeading.stringValue = settings.t("Updates")
            updateCaption.stringValue = settings.t("Check for updates") + ":"
            updateButton.title = settings.t("Check")
            autoUpdateCheck.title = settings.t("Install automatically")
            autoUpdateCheck.setSubtitle(settings.t("Downloads and verifies the release signature"))
            autoUpdateCheck.isOn = settings.autoUpdate
        }

        notificationsCaption.stringValue = settings.t("Notify me") + ":"
        notifyFinishedCheck.title = settings.t("Print finished")
        notifyFinishedCheck.isOn = settings.notifyFinished
        notifyFinishingSoonCheck.title = settings.t("Finishing in {0} minutes", settings.finishingSoonMinutes)
        notifyFinishingSoonCheck.isOn = settings.notifyFinishingSoon
        notifyErrorCheck.title = settings.t("Printer error")
        notifyErrorCheck.isOn = settings.notifyError
        notifyPausedCheck.title = settings.t("Print paused")
        notifyPausedCheck.isOn = settings.notifyPaused
        notifyLowFilamentCheck.title = settings.t("Low filament")
        notifyLowFilamentCheck.isOn = settings.notifyLowFilament
        notifyHumidityCheck.title = settings.t("High AMS humidity")
        notifyHumidityCheck.isOn = settings.notifyHumidity
        quietHoursCheck.title = settings.t("Quiet hours")
        quietHoursCheck.isOn = QuietHours.isEnabled
        quietRangeCaption.stringValue = settings.t("Hours") + ":"
        quietSeparatorLabel?.stringValue = settings.t("to")
        quietStartPicker.dateValue = date(fromMinutes: QuietHours.startMinutes)
        quietEndPicker.dateValue = date(fromMinutes: QuietHours.endMinutes)
        setQuietPickersEnabled(QuietHours.isEnabled)

        aboutHeading.stringValue = settings.t("About Gantry")
        appCaption.stringValue = Build.appName + ":"
        appVersionLabel.stringValue = settings.t("Version {0} • {1}", version, AccessCodeStore.modeName)
        githubCaption.stringValue = "GitHub:"
        githubButton.title = "@parametryczny"
        xCaption.stringValue = "X:"
        xButton.title = "@_parametryczny"
        supportButton.title = settings.t("Support the project")
        supportSubtitle.stringValue = settings.t("I never say no to good coffee, and this virtual one gives me a caffeine kick for my next projects! 🚀 If you'd like to chip in for my next cup and support what I do, click “Support the project”.")
    }

    private func refreshAppearance(_ settings: AppSettings) {
        themeCaption.stringValue = settings.t("Appearance") + ":"
        themeControl.setLabel(settings.t("LIGHT"), forSegment: 0)
        themeControl.setLabel(settings.t("DARK"), forSegment: 1)
        themeControl.selectedSegment = settings.theme == .light ? 0 : 1
        transparencyCaption.stringValue = settings.t("Transparency") + ":"
        transparencyControl.setLabel(settings.t("LOW"), forSegment: 0)
        transparencyControl.setLabel(settings.t("MEDIUM"), forSegment: 1)
        transparencyControl.setLabel(settings.t("HIGH"), forSegment: 2)
        switch settings.panelTransparency {
        case .low: transparencyControl.selectedSegment = 0
        case .medium: transparencyControl.selectedSegment = 1
        case .high: transparencyControl.selectedSegment = 2
        }
        monochromeCheck.title = settings.t("Monochrome colours")
        monochromeCheck.setSubtitle(settings.t("No tint on temperatures and filaments"))
        monochromeCheck.isOn = settings.monochrome

        cardsHeading.stringValue = settings.t("Printer cards")
        cardScaleCaption.stringValue = settings.t("Card size") + ":"
        cardScaleControl.configure(percent: settings.cardScalePercent, steps: AppSettings.cardScaleSteps)
        cardContentCaption.stringValue = settings.t("Show on the card") + ":"
        cardFileNameCheck.title = settings.t("File name")
        cardFileNameCheck.isOn = settings.cardShowFileName
        cardProgressCheck.title = settings.t("Progress")
        cardProgressCheck.isOn = settings.cardShowProgress
        cardTempsCheck.title = settings.t("Temperatures")
        cardTempsCheck.isOn = settings.cardShowTemperatures
        cardFilamentsCheck.title = settings.t("Filaments / AMS")
        cardFilamentsCheck.isOn = settings.cardShowFilaments
        // Everything below belongs to controls LITE never builds.
        guard Build.hasExtras else { return }
        cardSpoolGramsCheck.title = settings.t("Grams on spool")
        cardSpoolGramsCheck.setSubtitle("AMS NFC / Spoolbase")
        cardSpoolGramsCheck.isOn = settings.cardShowSpoolGrams
        cardDetailsChipCheck.title = settings.t("Details chip on the card")
        cardDetailsChipCheck.setSubtitle(settings.t("Shortcut to the detail view; the ⋯ menu always has it"))
        cardDetailsChipCheck.isOn = settings.cardShowDetailsChip

        floatingWindowCaption.stringValue = settings.t("Floating window") + ":"
        floatingWindowCheck.title = settings.t("Show Gantry in a floating window")
        floatingWindowCheck.setSubtitle(settings.t("Resize it freely; use the pin in its top bar to keep it above other windows"))
        floatingWindowCheck.isOn = settings.floatingWindowEnabled

        dockHeading.stringValue = settings.t("Edge dock")
        dockEnableCheck.title = settings.t("Show the strip on top")
        dockEnableCheck.isOn = settings.edgeDockEnabled
        dockEdgeCaption.stringValue = settings.t("Edge") + ":"
        dockEdgeControl.setLabel(settings.t("LEFT"), forSegment: 0)
        dockEdgeControl.setLabel(settings.t("RIGHT"), forSegment: 1)
        dockEdgeControl.selectedSegment = settings.edgeDockEdge == .left ? 0 : 1
        dockEdgeControl.isEnabled = settings.edgeDockEnabled
        dockScaleCaption.stringValue = settings.t("Edge dock size") + ":"
        dockScaleControl.configure(percent: settings.edgeDockScalePercent,
                                   steps: AppSettings.edgeDockScaleSteps,
                                   enabled: settings.edgeDockEnabled)
        dockBehaviourCaption.stringValue = settings.t("Behaviour") + ":"
        dockPinnedCheck.title = settings.t("Keep the strip open")
        dockPinnedCheck.isOn = settings.edgeDockPinned
        dockPinnedCheck.setEnabled(settings.edgeDockEnabled)
        dockCameraCheck.title = settings.t("Camera under the strip")
        dockCameraCheck.setSubtitle(settings.t("With nothing picked it follows the printer that is printing. Pick printers below and each picture sits under its own row."))
        dockCameraCheck.isOn = settings.edgeDockCamera
        dockCameraCheck.setEnabled(settings.edgeDockEnabled)
        dockOnlyPrintingCheck.title = settings.t("Only printing")
        dockOnlyPrintingCheck.isOn = settings.edgeDockOnlyPrinting
        dockOnlyPrintingCheck.setEnabled(settings.edgeDockEnabled)
        dockPrintersCaption.stringValue = settings.t("Which printers") + ":"
        dockHint.stringValue = settings.t("A narrow strip pinned to the screen edge, always on top. Hovering expands it to names, clicking opens details.")
        rebuildDockPrinters()
    }

    private func refreshAdvanced(_ settings: AppSettings) {
        featuresCaption.stringValue = settings.t("Features") + ":"
        printerControlCheck.title = settings.t("Printer control")
        printerControlCheck.setSubtitle(settings.t("Enables temperature, fan and speed controls in Details. Off by default."))
        printerControlCheck.isOn = settings.printerControlEnabled
        developerCheck.title = settings.t("Developer mode")
        developerCheck.setSubtitle(settings.t("Reveals control and automations"))
        developerCheck.isOn = settings.developerMode
        scriptActionsCheck.title = settings.t("Scripts in automations")
        scriptActionsCheck.setSubtitle(settings.t("Lets a rule run a program or a raw command. Off by default."))
        scriptActionsCheck.isOn = settings.allowScriptActions

        telegramHeading.stringValue = "Telegram"
        telegramEnableCheck.title = settings.t("Send notifications")
        telegramEnableCheck.isOn = settings.telegramEnabled
        telegramTokenCaption.stringValue = settings.t("Bot token") + ":"
        telegramChatCaption.stringValue = "Chat ID:"
        telegramTestCaption.stringValue = settings.t("Connection test") + ":"
        telegramTestButton.title = settings.t("Send")
        telegramHint.stringValue = settings.t("Create a bot via @BotFather (token), message it, and get your chat_id from @userinfobot. Sends the same events as the system notifications.")
        telegramTokenField.stringValue = settings.telegramBotToken
        telegramChatField.stringValue = settings.telegramChatID
        telegramTokenField.isEnabled = settings.telegramEnabled
        telegramChatField.isEnabled = settings.telegramEnabled
        telegramTestButton.isEnabled = settings.telegramEnabled
        for caption in [telegramTokenCaption, telegramChatCaption, telegramTestCaption] {
            caption.textColor = settings.telegramEnabled ? .labelColor : .tertiaryLabelColor
        }

        refreshWebSection(settings)
    }

    /// Fills the web-dashboard section with the live LAN URLs and a scannable QR of the IP URL
    /// (the IP always resolves on the same network, unlike the friendlier `.local` name).
    private func refreshWebSection(_ settings: AppSettings) {
        webHeading.stringValue = settings.t("Web dashboard")
        webEnableCheck.title = settings.t("Preview server")
        webEnableCheck.setSubtitle(settings.t("Local network, read only"))
        webEnableCheck.isOn = settings.webDashboardEnabled
        webContentStack.isHidden = !settings.webDashboardEnabled
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
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Actions

    @objc private func webEnabledChanged() {
        AppSettings.shared.webDashboardEnabled = webEnableCheck.isOn
        refreshWebSection(AppSettings.shared)
        resizeToSelectedPane()
    }

    @objc private func languageChanged() {
        let languages = Localization.available()
        let index = languageControl.indexOfSelectedItem
        guard index >= 0, index < languages.count else { return }
        AppSettings.shared.language = languages[index].code
    }

    @objc private func quietHoursChanged() {
        let enabled = quietHoursCheck.isOn
        QuietHours.isEnabled = enabled
        QuietHours.startMinutes = minutes(from: quietStartPicker.dateValue)
        QuietHours.endMinutes = minutes(from: quietEndPicker.dateValue)
        setQuietPickersEnabled(enabled)
    }

    /// Only the clocks dim when quiet hours are off; the checkbox itself has to stay fully legible.
    private func setQuietPickersEnabled(_ enabled: Bool) {
        for picker in [quietStartPicker, quietEndPicker] { picker.isEnabled = enabled }
        quietRangeCaption.textColor = enabled ? .labelColor : .tertiaryLabelColor
        quietSeparatorLabel?.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
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
            try LaunchAtLoginManager.setEnabled(launchCheck.isOn)
        } catch {
            launchCheck.isOn = LaunchAtLoginManager.isEnabled
            NotificationService.post(title: "Gantry", body: error.localizedDescription)
        }
    }

    @objc private func developerToggled() {
        AppSettings.shared.developerMode = developerCheck.isOn
    }

    @objc private func printerControlToggled() {
        AppSettings.shared.printerControlEnabled = printerControlCheck.isOn
    }

    @objc private func scriptActionsToggled() {
        AppSettings.shared.allowScriptActions = scriptActionsCheck.isOn
    }

    @objc private func spoolbaseToggled() {
        AppSettings.shared.spoolbaseEnabled = spoolbaseCheck.isOn
    }

    @objc private func autoUpdateToggled() {
        AppSettings.shared.autoUpdate = autoUpdateCheck.isOn
    }

    @objc private func notificationToggled() {
        let settings = AppSettings.shared
        settings.notifyFinished = notifyFinishedCheck.isOn
        settings.notifyError = notifyErrorCheck.isOn
        settings.notifyPaused = notifyPausedCheck.isOn
        settings.notifyFinishingSoon = notifyFinishingSoonCheck.isOn
        settings.notifyLowFilament = notifyLowFilamentCheck.isOn
        settings.notifyHumidity = notifyHumidityCheck.isOn
    }

    @objc private func cardContentToggled() {
        let settings = AppSettings.shared
        settings.cardShowFileName = cardFileNameCheck.isOn
        settings.cardShowProgress = cardProgressCheck.isOn
        settings.cardShowTemperatures = cardTempsCheck.isOn
        settings.cardShowFilaments = cardFilamentsCheck.isOn
        settings.monochrome = monochromeCheck.isOn
        // These two only exist in the full edition; in LITE they are never built, so reading them
        // here would only write a default back over the stored value.
        guard Build.hasExtras else { return }
        settings.cardShowSpoolGrams = cardSpoolGramsCheck.isOn
        settings.cardShowDetailsChip = cardDetailsChipCheck.isOn
    }

    @objc private func floatingWindowToggled() {
        AppSettings.shared.floatingWindowEnabled = floatingWindowCheck.isOn
    }

    private func changeCardScale(_ direction: Int) {
        let settings = AppSettings.shared
        guard let index = AppSettings.cardScaleSteps.firstIndex(of: settings.cardScalePercent) else { return }
        let target = min(max(0, index + direction), AppSettings.cardScaleSteps.count - 1)
        settings.cardScalePercent = AppSettings.cardScaleSteps[target]
    }

    // MARK: Edge dock

    @objc private func dockEnableToggled() {
        AppSettings.shared.edgeDockEnabled = dockEnableCheck.isOn
    }

    @objc private func dockEdgeChanged() {
        AppSettings.shared.edgeDockEdge = dockEdgeControl.selectedSegment == 0 ? .left : .right
    }

    private func changeDockScale(_ direction: Int) {
        let settings = AppSettings.shared
        guard let index = AppSettings.edgeDockScaleSteps.firstIndex(of: settings.edgeDockScalePercent) else { return }
        let target = min(max(0, index + direction), AppSettings.edgeDockScaleSteps.count - 1)
        settings.edgeDockScalePercent = AppSettings.edgeDockScaleSteps[target]
    }

    @objc private func dockPinnedToggled() {
        AppSettings.shared.edgeDockPinned = dockPinnedCheck.isOn
    }

    @objc private func dockCameraToggled() {
        AppSettings.shared.edgeDockCamera = dockCameraCheck.isOn
        syncDockPrinterSwitches()
    }

    /// Which printers hang a picture under their row. Same identifier trick as the visibility box,
    /// prefixed so one recursive pass can tell the two controls apart.
    @objc private func dockPrinterCameraToggled(_ sender: NSButton) {
        let name = sender.identifier?.rawValue ?? ""
        guard name.hasPrefix("camera:") else { return }
        let serial = String(name.dropFirst("camera:".count))
        guard !serial.isEmpty else { return }
        var chosen = AppSettings.shared.edgeDockCameraSerials
        if sender.state == .on { chosen.insert(serial) } else { chosen.remove(serial) }
        AppSettings.shared.edgeDockCameraSerials = chosen
    }

    @objc private func dockOnlyPrintingToggled() {
        AppSettings.shared.edgeDockOnlyPrinting = dockOnlyPrintingCheck.isOn
    }

    /// The serial rides in the checkbox's identifier because the list is rebuilt whenever refresh()
    /// runs, so a captured index would go stale.
    @objc private func dockPrinterToggled(_ sender: NSButton) {
        let serial = sender.identifier?.rawValue ?? ""
        guard !serial.isEmpty else { return }
        var hidden = AppSettings.shared.edgeDockHiddenPrinters
        if sender.state == .on { hidden.remove(serial) } else { hidden.insert(serial) }
        AppSettings.shared.edgeDockHiddenPrinters = hidden
    }

    /// Rebuilds the printer list only when the fleet itself changed; otherwise just re-syncs the
    /// controls, so refresh() does not throw away and recreate views on every settings change.
    private func rebuildDockPrinters() {
        let settings = AppSettings.shared
        let serials = store.printers.map(\.serial)
        guard serials != dockPrinterSerials || dockPrintersStack.views.isEmpty else {
            syncDockPrinterSwitches()
            return
        }
        dockPrinterSerials = serials
        dockPrintersStack.views.forEach { $0.removeFromSuperview() }

        if store.printers.isEmpty {
            let empty = NSTextField(labelWithString: settings.t("No printers"))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            dockPrintersStack.addView(empty, in: .top)
        }
        for printer in store.printers {
            // Two decisions per printer: is it in the strip at all, and does its picture hang under
            // its row. The camera is the smaller control, because it is the rarer choice.
            let box = NSButton(checkboxWithTitle: printer.name, target: self,
                               action: #selector(dockPrinterToggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(printer.serial)
            box.font = .systemFont(ofSize: 12)
            box.toolTip = printer.model
            let camera = NSButton()
            camera.identifier = NSUserInterfaceItemIdentifier("camera:\(printer.serial)")
            camera.setButtonType(.toggle)
            camera.bezelStyle = .accessoryBarAction
            camera.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
            camera.alternateImage = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
            camera.imagePosition = .imageOnly
            camera.target = self
            camera.action = #selector(dockPrinterCameraToggled(_:))
            camera.toolTip = settings.t("Camera under the strip")

            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            for control in [box, camera] as [NSView] {
                control.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(control)
            }
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                box.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                camera.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                camera.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                box.trailingAnchor.constraint(lessThanOrEqualTo: camera.leadingAnchor, constant: -8),
                row.heightAnchor.constraint(equalTo: camera.heightAnchor),
                // The list is as wide as the control column minus the scroller's own insets, so the
                // camera button lands on a straight right edge down the whole list.
                row.widthAnchor.constraint(equalToConstant: SettingsMetrics.controlColumn - 18)
            ])
            dockPrintersStack.addView(row, in: .top)
        }
        // Fits the list to the fleet, up to four rows; a bigger fleet scrolls rather than pushing the
        // window past the bottom of the screen.
        let rows = max(1, store.printers.count)
        dockPrintersHeight?.constant = min(CGFloat(rows) * 27 + 12, 120)
        syncDockPrinterSwitches()
    }

    private func syncDockPrinterSwitches() {
        let settings = AppSettings.shared
        let hidden = settings.edgeDockHiddenPrinters
        let withCamera = settings.edgeDockCameraSerials
        for row in dockPrintersStack.views {
            for control in identifiedControls(in: row) {
                guard let name = control.identifier?.rawValue else { continue }
                guard let button = control as? NSButton else { continue }
                guard name.hasPrefix("camera:") else {
                    button.state = hidden.contains(name) ? .off : .on
                    button.isEnabled = settings.edgeDockEnabled
                    continue
                }
                let serial = String(name.dropFirst("camera:".count))
                let kind = store.printers.first(where: { $0.serial == serial })?.kind
                let on = withCamera.contains(serial)
                button.state = on ? .on : .off
                // The filled glyph alone is a subtle difference at this size; the accent colour makes
                // "this printer is streaming" readable at a glance.
                button.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
                // A brand with no stream Gantry can decode never gets the choice offered.
                button.isEnabled = settings.edgeDockEnabled && settings.edgeDockCamera
                    && !hidden.contains(serial) && CameraFeedController.supportsCamera(kind)
                button.isHidden = !CameraFeedController.supportsCamera(kind)
            }
        }
    }

    /// The per-printer row nests its controls, so a flat pass over `subviews` misses them.
    private func identifiedControls(in view: NSView) -> [NSControl] {
        view.subviews.flatMap { subview -> [NSControl] in
            if let control = subview as? NSControl, control.identifier != nil { return [control] }
            return identifiedControls(in: subview)
        }
    }

    // MARK: Telegram

    @objc private func telegramToggled() {
        AppSettings.shared.telegramEnabled = telegramEnableCheck.isOn
        refreshAdvanced(AppSettings.shared)
        resizeToSelectedPane()
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
            telegramTestStatus.stringValue = settings.t("Enter a token and chat_id.")
            telegramTestStatus.textColor = GantryTheme.statusError
            return
        }
        telegramTestStatus.stringValue = settings.t("Sending…")
        telegramTestStatus.textColor = .secondaryLabelColor
        let text = TelegramService.format(printer: "Gantry", title: settings.t("Test notification"),
                                          body: settings.t("The connection works."))
        Task { @MainActor in
            let ok = await TelegramService.sendMessage(token: token, chatID: chat, text: text)
            telegramTestStatus.stringValue = ok ? settings.t("Sent ✓")
                                                : settings.t("Failed. Check the token and chat_id.")
            telegramTestStatus.textColor = ok ? GantryTheme.statusFinished : GantryTheme.statusError
        }
    }

    // MARK: Updates

    @objc private func checkForUpdates() {
        let settings = AppSettings.shared
        updateButton.isEnabled = false
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.stringValue = settings.t("Checking…")
        Task { @MainActor in
            defer { updateButton.isEnabled = true }
            do {
                let release = try await UpdateService.latestRelease()
                if UpdateService.isNewer(release.version, than: UpdateService.currentVersion) {
                    updateStatus.stringValue = ""
                    presentUpdateAvailable(release)
                } else {
                    updateStatus.stringValue = settings.t("You have the latest version.")
                }
            } catch {
                updateStatus.stringValue = ""
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
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.stringValue = settings.t("Downloading and installing…")
        Task { @MainActor in
            do {
                try await UpdateService.downloadAndInstall(release)
                // The helper relaunches the app; this process is about to terminate.
            } catch {
                updateButton.isEnabled = true
                updateStatus.stringValue = ""
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
        button.font = .systemFont(ofSize: 13)
        button.contentTintColor = .linkColor
    }
}

/// The toolbar itself. `NSTabViewController` in `.toolbar` mode builds the toolbar, the pane icons,
/// the crossfade between panes and the window title, so all that is left here is telling the window
/// controller when the pane changed, and remembering which one it was.
@MainActor
private final class SettingsTabViewController: NSTabViewController {
    var onSelect: (() -> Void)?
    private static let lastPaneKey = "settings.last-pane"

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        transitionOptions = [.crossfade]
        let remembered = BambuDefaults.shared.integer(forKey: Self.lastPaneKey)
        if remembered > 0, remembered < tabViewItems.count { selectedTabViewItemIndex = remembered }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        BambuDefaults.shared.set(selectedTabViewItemIndex, forKey: Self.lastPaneKey)
        onSelect?()
    }
}

/// Top-down document view, so the printer list fills from the top rather than the bottom.
final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
