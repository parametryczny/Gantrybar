import AppKit
import Combine

private let printerCardPasteboardType = NSPasteboard.PasteboardType("pl.gantry.printer-card")

/// Flipped so a scroll's document anchors its content to the top-left; short content then
/// sits at the top instead of the bottom of the clip view.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A purely-visual overlay: it never intercepts mouse events, so controls beneath it (the ⋯ menu,
/// details chip, drag grip) stay clickable through a disconnect scrim.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Dimmed backdrop behind the spool-assignment panel. A click that lands on the backdrop itself (not on
/// the panel above it) dismisses the overlay; clicks on the panel are handled by the panel's controls.
private final class SpoolBackdropView: NSView {
    var onClickOutside: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClickOutside?() }
}

@MainActor
final class PrinterDashboardViewController: NSViewController {
    private let store: PrinterStore
    private let onAdd: () -> Void
    private let onEdit: (SavedPrinter) -> Void
    private let onReconnect: (SavedPrinter) -> Void
    private let onShowDetails: (String) -> Void
    private let onPreferredContentSize: (NSSize) -> Void
    private let cardsStack = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    // The translucent panel backdrop sits BEHIND the cards (not as the root view) so its transparency
    // can change without fading the cards on top of it.
    private let backgroundEffectView = NSVisualEffectView()
    private let resetButton = NSButton()
    private let compactButton = NSButton()
    private let columnsButton = NSButton()
    private var renderedColumnCount = 0
    /// User-chosen number of card columns (1 = one per row / "pionowo", 2 = two per row). Persisted.
    private var preferredColumns: Int {
        get { let v = UserDefaults.standard.integer(forKey: "gantry.dashboard.columns"); return v == 0 ? 2 : min(2, max(1, v)) }
        set { UserDefaults.standard.set(min(2, max(1, newValue)), forKey: "gantry.dashboard.columns") }
    }
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var timerSubscription: AnyCancellable?
    private var cardsBySerial: [String: PrinterCardView] = [:]
    private var compactRowsBySerial: [String: CompactPrinterRowView] = [:]
    private var expandedCardsBySerial: [String: PrinterCardView] = [:]
    private var expandedCompactSerials: Set<String> = []
    private var renderedSerials: [String] = []
    private var renderedWideSerials: Set<String> = []
    private var renderedCompactMode: Bool?
    private var refreshWorkItem: DispatchWorkItem?
    private let dashboardDefaults = BambuDefaults.shared
    private var prefersCompactMode: Bool
    private var compactModeChosen: Bool

    init(
        store: PrinterStore,
        onAdd: @escaping () -> Void,
        onEdit: @escaping (SavedPrinter) -> Void,
        onReconnect: @escaping (SavedPrinter) -> Void,
        onShowDetails: @escaping (String) -> Void,
        onPreferredContentSize: @escaping (NSSize) -> Void
    ) {
        self.store = store
        self.onAdd = onAdd
        self.onEdit = onEdit
        self.onReconnect = onReconnect
        self.onShowDetails = onShowDetails
        self.onPreferredContentSize = onPreferredContentSize
        prefersCompactMode = BambuDefaults.shared.bool(forKey: "dashboard-compact-mode")
        compactModeChosen = BambuDefaults.shared.bool(forKey: "dashboard-compact-mode-set")
        super.init(nibName: nil, bundle: nil)
        subscription = store.objectWillChange.sink { [weak self] _ in
            self?.scheduleRefresh()
        }
        settingsSubscription = AppSettings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsChanged() }
        }
        timerSubscription = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshDashboard() }
        // A spool assignment (Spoolbase) should reflect on the cards immediately.
        SpoolbaseShared.spools.onChange = { [weak self] in self?.refreshDashboard() }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 650))
        root.wantsLayer = true
        root.layer?.backgroundColor = GantryTheme.canvas.cgColor
        // The vibrancy backdrop fills the panel behind everything; its material/alpha come from the
        // Panel-transparency setting. Because it's a sibling behind the cards (not the root), lowering
        // its alpha lets more desktop show through the gaps WITHOUT fading the cards themselves.
        backgroundEffectView.frame = root.bounds
        backgroundEffectView.autoresizingMask = [.width, .height]
        backgroundEffectView.blendingMode = .behindWindow
        backgroundEffectView.state = .active
        backgroundEffectView.wantsLayer = true
        root.addSubview(backgroundEffectView)
        view = root
        applyPanelTransparency()

        summaryLabel.font = .systemFont(ofSize: 11, weight: .regular)
        summaryLabel.textColor = GantryTheme.secondary
        // The summary yields (truncates) before the icons when the header is narrow, so the buttons
        // always fit instead of overflowing the bento.
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // One-line header: GANTRY · N drukarek · M pracuje
        let wordmark = NSImageView(image: GantryLogo.wordmarkImage(height: 13))
        wordmark.setContentHuggingPriority(.required, for: .horizontal)
        wordmark.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleDot = NSTextField(labelWithString: "·")
        titleDot.font = .systemFont(ofSize: 12, weight: .semibold)
        titleDot.textColor = GantryTheme.muted
        let titleStack = NSStackView(views: [wordmark, titleDot, summaryLabel])
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 7

        let addButton = iconButton("plus", tooltip: "Dodaj drukarkę / Add printer", action: #selector(addPressed))
        let refreshButton = iconButton("arrow.clockwise", tooltip: "Połącz ponownie / Reconnect", action: #selector(refreshPressed))
        // Reset (clear finished jobs) — compact icon.
        resetButton.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        resetButton.imagePosition = .imageOnly
        resetButton.isBordered = false
        resetButton.contentTintColor = GantryTheme.secondary
        resetButton.target = self
        resetButton.action = #selector(resetPressed)
        resetButton.toolTip = AppSettings.shared.text("Wyczyść zakończone", "Clear finished")
        // Layout toggle (cards ↔ list) — icon; image set per mode in refreshDashboard.
        compactButton.imagePosition = .imageOnly
        compactButton.isBordered = false
        compactButton.contentTintColor = GantryTheme.secondary
        compactButton.target = self
        compactButton.action = #selector(toggleCompactMode)
        compactButton.isHidden = true

        // Column-count toggle (1 ↔ 2 columns) — separate from the cards/list density toggle.
        columnsButton.imagePosition = .imageOnly
        columnsButton.isBordered = false
        columnsButton.contentTintColor = GantryTheme.secondary
        columnsButton.target = self
        columnsButton.action = #selector(toggleColumns)

        let controls = NSStackView(views: [columnsButton, compactButton, resetButton, refreshButton, addButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 2

        let headerInner = NSStackView(views: [titleStack, NSView(), controls])
        headerInner.orientation = .horizontal
        headerInner.alignment = .centerY
        headerInner.spacing = 6
        headerInner.translatesAutoresizingMaskIntoConstraints = false

        // Wrap the header in a light bento surface (saves vertical space, matches the card bentos).
        let header = NSView()
        header.wantsLayer = true
        header.layer?.cornerRadius = GantryTheme.tileRadius
        header.layer?.backgroundColor = GantryTheme.surface.cgColor
        header.layer?.borderWidth = 1
        header.layer?.borderColor = GantryTheme.line.cgColor
        header.addSubview(headerInner)
        NSLayoutConstraint.activate([
            headerInner.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            headerInner.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            headerInner.topAnchor.constraint(equalTo: header.topAnchor, constant: 6),
            headerInner.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6)
        ])

        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 8
        cardsStack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(cardsStack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document

        // A light, unobtrusive tagline under the cards.
        footerLabel.font = .systemFont(ofSize: 10, weight: .regular)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(scroll)
        view.addSubview(footerLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            header.heightAnchor.constraint(equalToConstant: 36),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -6),
            footerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            footerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            footerLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            cardsStack.topAnchor.constraint(equalTo: document.topAnchor),
            cardsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        refreshLocalization()
        refreshDashboard()
    }

    /// Height the popover should take so it fits the printer cards (or compact rows) without
    /// leaving empty space, capped so large fleets scroll instead of growing off-screen.
    private func preferredPopoverHeight(compact: Bool, columns: Int) -> CGFloat {
        let printerCount = store.printers.count
        let insets: CGFloat = 12                 // cardsStack top + bottom edge insets
        let chrome: CGFloat = 12 + 36 + 6 + 8    // view top + header + gap + scroll bottom inset
        var content: CGFloat
        if printerCount == 0 {
            content = 120 + insets
        } else if compact {
            content = CGFloat(printerCount) * 31 + CGFloat(printerCount - 1) * 3 + insets
            content += CGFloat(expandedCompactSerials.count) * (174 + 3)   // full card beneath each expanded row
        } else {
            let rows = Int(ceil(Double(printerCount) / Double(max(1, columns))))
            content = CGFloat(rows) * 174 + CGFloat(max(0, rows - 1)) * 8 + insets
        }
        // Tall enough for up to 8 full cards (2 columns → 4 rows) before scrolling kicks in.
        return min(820, chrome + content)
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refreshDashboard() }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: item)
    }

    private func refreshDashboard() {
        guard isViewLoaded else { return }
        let online = store.telemetry.values.filter { $0.state != .offline }.count
        let settings = AppSettings.shared
        summaryLabel.stringValue = settings.language == .pl
            ? "\(store.printers.count) drukarek · \(store.activePrintCount) pracuje"
            : "\(store.printers.count) printers · \(store.activePrintCount) printing"
        let supportsCompactMode = store.printers.count >= 4
        // Full view fits up to 8 printers; above 8 default to compact. A manual toggle overrides.
        let useCompactMode = supportsCompactMode && (compactModeChosen ? prefersCompactMode : store.printers.count > 8)
        // The reference dashboard is 840 px / three columns. Geometry no longer depends on printer
        // count: each normal card spans one column and a dual-nozzle or multi-AMS card spans two.
        // User-chosen 1 or 2 card columns; the last odd card stretches to full width at the bottom.
        let expandedColumnCount = useCompactMode ? 1 : preferredColumns
        let panelWidth: CGFloat = useCompactMode ? 512 : (expandedColumnCount == 1 ? 380 : 563)
        let wideSerials = Set(store.printers.compactMap { printer in
            cardNeedsWideSpan(printer) ? printer.serial : nil
        })
        // The popover size is reported once at the end of render() from the cards' real measured
        // height — reporting an estimate here too made the popover oscillate between the two values.
        compactButton.isHidden = !supportsCompactMode
        // Layout toggle icon: in card mode show a "list" icon (tap → list); in list mode a "grid" icon.
        compactButton.image = NSImage(systemSymbolName: useCompactMode ? "square.grid.2x2" : "list.bullet",
                                      accessibilityDescription: nil)
        compactButton.toolTip = settings.text(
            useCompactMode ? "Układ: kafle" : "Układ: lista",
            useCompactMode ? "Layout: cards" : "Layout: list"
        )
        // Column-count toggle only makes sense in card mode; hide it in the compact list.
        columnsButton.isHidden = useCompactMode
        columnsButton.image = NSImage(systemSymbolName: preferredColumns == 2 ? "rectangle.portrait" : "square.split.2x1",
                                      accessibilityDescription: nil)
        columnsButton.toolTip = settings.text(
            preferredColumns == 2 ? "Jedna kolumna" : "Dwie kolumny",
            preferredColumns == 2 ? "One column" : "Two columns"
        )
        cardsStack.spacing = useCompactMode ? 3 : 6
        if store.printers.isEmpty {
            detachCardRows()
            cardsBySerial.removeAll()
            compactRowsBySerial.removeAll()
            renderedSerials.removeAll()
            renderedWideSerials.removeAll()
            renderedCompactMode = nil
            let empty = NSTextField(wrappingLabelWithString: settings.text(
                "Brak drukarek. Kliknij +, aby wyszukać urządzenia w sieci.",
                "No printers. Click + to find devices on your network."
            ))
            empty.alignment = .center
            empty.textColor = .secondaryLabelColor
            empty.widthAnchor.constraint(equalToConstant: 440).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 120).isActive = true
            cardsStack.addArrangedSubview(empty)
            return
        }

        let desiredSerials = store.printers.map(\.serial)
        // Drop expansion state for printers that no longer exist, so a removed-while-expanded row
        // doesn't keep inflating the popover height.
        expandedCompactSerials.formIntersection(desiredSerials)
        if desiredSerials != renderedSerials || renderedCompactMode != useCompactMode || renderedWideSerials != wideSerials || renderedColumnCount != expandedColumnCount {
            detachCardRows()
            if renderedCompactMode != useCompactMode {
                cardsBySerial.removeAll()
                compactRowsBySerial.removeAll()
                expandedCardsBySerial.removeAll()
            }
            renderedSerials = desiredSerials
            renderedCompactMode = useCompactMode
            renderedWideSerials = wideSerials
            renderedColumnCount = expandedColumnCount

            if useCompactMode {
                compactRowsBySerial = compactRowsBySerial.filter { desiredSerials.contains($0.key) }
                expandedCardsBySerial = expandedCardsBySerial.filter { desiredSerials.contains($0.key) }
                let contentWidth = panelWidth - 24
                for printer in store.printers {
                    let row = compactRowsBySerial[printer.serial] ?? CompactPrinterRowView(
                        printer: printer,
                        onMove: { [weak self] sourceSerial, targetSerial, insertAfter in
                            self?.store.movePrinter(serial: sourceSerial, relativeTo: targetSerial, insertAfter: insertAfter)
                        },
                        onSelect: { [weak self] in self?.toggleCompactExpansion(printer.serial) }
                    )
                    compactRowsBySerial[printer.serial] = row
                    row.setLayoutWidth(contentWidth)
                    cardsStack.addArrangedSubview(row)
                    if expandedCompactSerials.contains(printer.serial) {
                        let card = expandedCardsBySerial[printer.serial] ?? makeCard(for: printer)
                        expandedCardsBySerial[printer.serial] = card
                        card.setLayoutWidth(contentWidth)
                        cardsStack.addArrangedSubview(card)
                    }
                }
            } else {
                cardsBySerial = cardsBySerial.filter { desiredSerials.contains($0.key) }
                var cards: [PrinterCardView] = []
                for printer in store.printers {
                    let card = cardsBySerial[printer.serial] ?? makeCard(for: printer)
                    cardsBySerial[printer.serial] = card
                    cards.append(card)
                }
                addExpandedRows(cards, printers: store.printers, contentWidth: panelWidth - 24,
                                columns: expandedColumnCount)
            }
        }

        for printer in store.printers {
            let telemetry = store.telemetry[printer.serial] ?? .init()
            let message = store.connectionMessages[printer.serial]
            if useCompactMode {
                compactRowsBySerial[printer.serial]?.update(printer: printer, telemetry: telemetry, message: message, settings: settings)
                expandedCardsBySerial[printer.serial]?.update(printer: printer, telemetry: telemetry, message: message, settings: settings)
            } else {
                cardsBySerial[printer.serial]?.update(printer: printer, telemetry: telemetry, message: message, settings: settings)
            }
            let serial = printer.serial
            cardsBySerial[serial]?.showNotices(store.spoolNotices[serial] ?? []) { [weak self] in
                self?.store.dismissSpoolNotices(serial: serial)
            }
        }

        // Size the popover from the cards' real laid-out height (cards grow when AMS chips wrap).
        // Only report when it actually changes, otherwise repeated identical resizes make the
        // popover's bottom edge visibly pulse on every telemetry tick.
        view.layoutSubtreeIfNeeded()
        let measuredContent = cardsStack.fittingSize.height
        if measuredContent > 1 {
            // header(12+36) + gap(6) + footer block(scroll→footer 6 + footer 14 + bottom 8), plus a
            // 4 px hairline so rounding never leaves a scrollbar — otherwise the panel hugs its content.
            let chromeAndInsets: CGFloat = 12 + 36 + 6 + 6 + 14 + 8 + 4
            // Cap to the screen so a tall (e.g. 1-column) fleet doesn't push the popover up behind the
            // menu bar and clip the header — the excess scrolls inside instead.
            let maxHeight = ((view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 24
            let size = NSSize(width: panelWidth, height: min(maxHeight, chromeAndInsets + measuredContent))
            if abs(size.width - lastReportedContentSize.width) > 0.5
                || abs(size.height - lastReportedContentSize.height) > 0.5 {
                lastReportedContentSize = size
                // Setting the content controller's preferredContentSize is what actually makes a
                // shown NSPopover resize (assigning popover.contentSize after presentation doesn't
                // shrink it — that left the panel stuck at its initial height with empty space).
                preferredContentSize = size
                onPreferredContentSize(size)
            }
        }
    }

    private var lastReportedContentSize: NSSize = .zero
    // Equal-height constraints tying the cards of each row together; rebuilt every populate so a
    // card re-paired into a different row never keeps a stale partner.
    private var rowHeightConstraints: [NSLayoutConstraint] = []

    private func cardNeedsWideSpan(_ printer: SavedPrinter) -> Bool {
        let telemetry = store.telemetry[printer.serial] ?? .init()
        let dualNozzle = telemetry.nozzles.contains { $0.position == .right }
            || telemetry.nozzleTemperature2 != nil
        let amsCount = telemetry.filamentGroups.filter { !$0.isExternal }.count
        return dualNozzle || amsCount >= 2
    }

    /// Packs cards into the six-column contract represented here as three printer columns. A wide
    /// card consumes two columns. Incomplete rows receive an invisible spacer; the last card never
    /// stretches merely because the printer count is odd.
    private func addExpandedRows(_ cards: [PrinterCardView], printers: [SavedPrinter],
                                 contentWidth: CGFloat, columns: Int) {
        guard columns > 0 else { return }
        let gap: CGFloat = 10
        let unit = (contentWidth - CGFloat(columns - 1) * gap) / CGFloat(columns)
        var rowItems: [(card: PrinterCardView, span: Int)] = []
        var used = 0

        func flushRow() {
            guard !rowItems.isEmpty else { return }
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = gap
            var rowCards: [PrinterCardView] = []
            for item in rowItems {
                item.card.setLayoutWidth(unit * CGFloat(item.span) + gap * CGFloat(item.span - 1))
                row.addArrangedSubview(item.card)
                rowCards.append(item.card)
            }
            let remaining = columns - used
            if remaining > 0 {
                let spacer = NSView()
                spacer.widthAnchor.constraint(equalToConstant: unit * CGFloat(remaining) + gap * CGFloat(remaining - 1)).isActive = true
                row.addArrangedSubview(spacer)
            }
            if let first = rowCards.first {
                for card in rowCards.dropFirst() {
                    let equal = card.heightAnchor.constraint(equalTo: first.heightAnchor)
                    equal.isActive = true
                    rowHeightConstraints.append(equal)
                }
            }
            cardsStack.addArrangedSubview(row)
            rowItems.removeAll(keepingCapacity: true)
            used = 0
        }

        for (index, (card, printer)) in zip(cards, printers).enumerated() {
            var span = min(columns, cardNeedsWideSpan(printer) ? 2 : 1)
            if used + span > columns { flushRow() }
            // The last card, alone on a fresh row (odd count), stretches to the full width at the bottom.
            if index == cards.count - 1, used == 0 { span = columns }
            rowItems.append((card, span))
            used += span
            if used == columns { flushRow() }
        }
        flushRow()
    }

    private func detachCardRows() {
        NSLayoutConstraint.deactivate(rowHeightConstraints)
        rowHeightConstraints.removeAll()
        for arrangedView in cardsStack.arrangedSubviews {
            if let row = arrangedView as? NSStackView {
                for card in row.arrangedSubviews {
                    row.removeArrangedSubview(card)
                    card.removeFromSuperview()
                }
            }
            cardsStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
    }

    private func settingsChanged() {
        guard isViewLoaded else { return }
        view.appearance = AppSettings.shared.appearance
        view.window?.appearance = AppSettings.shared.appearance
        view.layer?.backgroundColor = NSColor.clear.cgColor
        refreshLocalization()
        // Force a full card rebuild: settings like monochrome change the slot colours, which are baked in
        // when a FilamentSlotView is created — an in-place update would not recompute them.
        renderedSerials = []
        refreshDashboard()
    }

    /// Applies the Panel-transparency setting to the backdrop only (material + its own alpha), leaving
    /// the cards untouched so they stay readable at every level.
    func applyPanelTransparency() {
        let level = AppSettings.shared.panelTransparency
        backgroundEffectView.material = level.material
        backgroundEffectView.alphaValue = level.backgroundAlpha
    }

    private func refreshLocalization() {
        let settings = AppSettings.shared
        footerLabel.stringValue = settings.text("Drukuj spokojnie — wszystko pod kontrolą",
                                                "Print in peace — everything under control")
        // Reset/clear is icon-only (a broom-like ✨); don't set a title or it takes header width.
        resetButton.imagePosition = .imageOnly
        resetButton.toolTip = settings.text(
            "Usuń zakończone zadania i stare nazwy plików",
            "Clear completed jobs and old file names"
        )
        // The layout-toggle button is icon-only; its image + tooltip are refreshed in refreshDashboard.
    }

    private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!, target: self, action: action)
        // Flat, borderless icon so Reconnect and Add match the other header buttons (columns / list /
        // clear) instead of showing filled circular bezels.
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = GantryTheme.secondary
        button.toolTip = tooltip
        return button
    }

    private func openBambuStudio(camera: Bool) {
        let url = URL(fileURLWithPath: "/Applications/BambuStudio.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let cameraMessage = AppSettings.shared.text(
            "Otwórz kartę Urządzenie, aby zobaczyć kamerę.",
            "Open the Device tab to view the camera."
        )
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in
            if camera {
                NotificationService.post(title: "Gantry", body: cameraMessage)
            }
        }
    }

    private func copyIP(_ host: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(host, forType: .string)
    }

    private func confirmRemove(_ printer: SavedPrinter) {
        let settings = AppSettings.shared
        let alert = NSAlert()
        alert.messageText = settings.text("Usunąć drukarkę \(printer.name)?", "Remove printer \(printer.name)?")
        alert.informativeText = settings.text(
            "Zapisany kod dostępu i pin certyfikatu tej drukarki zostaną usunięte.",
            "This printer's saved access code and certificate pin will be removed."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: settings.text("Usuń", "Remove"))
        alert.addButton(withTitle: settings.text("Anuluj", "Cancel"))
        // Prefer a modal sheet on the window; fall back to a standalone alert.
        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] result in
                if result == .alertFirstButtonReturn { self?.store.remove(printer) }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            store.remove(printer)
        }
    }

    @objc private func addPressed() { onAdd() }
    @objc private func refreshPressed() {
        store.reconnectAll()
        store.refreshPrinterNames()
    }
    @objc private func resetPressed() { store.resetCompletedStatuses() }
    @objc private func toggleColumns() {
        preferredColumns = preferredColumns == 2 ? 1 : 2
        refreshDashboard()
    }
    @objc private func toggleCompactMode() {
        guard store.printers.count >= 4 else { return }
        // Toggle relative to what's shown now, and remember that the user made an explicit choice.
        let currentlyCompact = compactModeChosen ? prefersCompactMode : store.printers.count > 8
        prefersCompactMode = !currentlyCompact
        compactModeChosen = true
        dashboardDefaults.set(prefersCompactMode, forKey: "dashboard-compact-mode")
        dashboardDefaults.set(true, forKey: "dashboard-compact-mode-set")
        renderedCompactMode = nil
        refreshDashboard()
    }

    private func makeCard(for printer: SavedPrinter) -> PrinterCardView {
        PrinterCardView(
            printer: printer,
            onEdit: { [weak self] in
                guard let self, let current = self.store.printers.first(where: { $0.serial == printer.serial }) else { return }
                self.onEdit(current)
            },
            onReconnect: { [weak self] in
                guard let self, let current = self.store.printers.first(where: { $0.serial == printer.serial }) else { return }
                self.onReconnect(current)
            },
            onOpenCamera: { [weak self] in self?.openBambuStudio(camera: true) },
            onShowDetails: { [weak self] in self?.onShowDetails(printer.serial) },
            onOpenSlicer: { url in SlicerLauncher.open(url) },
            onCopyIP: { [weak self] in
                guard let self, let host = self.store.printers.first(where: { $0.serial == printer.serial })?.host else { return }
                self.copyIP(host)
            },
            onRemove: { [weak self] in
                guard let self, let current = self.store.printers.first(where: { $0.serial == printer.serial }) else { return }
                self.confirmRemove(current)
            },
            onMove: { [weak self] sourceSerial, targetSerial, insertAfter in
                self?.store.movePrinter(serial: sourceSerial, relativeTo: targetSerial, insertAfter: insertAfter)
            }
        )
    }

    /// Toggles whether one printer's full card is shown beneath its compact row (accordion).
    private func toggleCompactExpansion(_ serial: String) {
        if expandedCompactSerials.contains(serial) { expandedCompactSerials.remove(serial) }
        else { expandedCompactSerials.insert(serial) }
        renderedCompactMode = nil
        refreshDashboard()
    }
}

@MainActor
private final class CompactPrinterRowView: NSView, NSDraggingSource {
    let serial: String
    /// macOS 26 "liquid glass" where available, a standard translucent material on older systems.
    private let backdrop: NSView
    private let stateIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let dropIndicatorLayer = CALayer()
    private var dragHandle: PrinterDragHandle?
    private let onMove: (_ sourceSerial: String, _ targetSerial: String, _ insertAfter: Bool) -> Void
    private let onSelect: (() -> Void)?
    private var layoutWidthConstraint: NSLayoutConstraint?

    /// Match the collapsed row to the current panel content width so it lines up with an expanded card.
    func setLayoutWidth(_ width: CGFloat) {
        layoutWidthConstraint?.isActive = false
        layoutWidthConstraint = widthAnchor.constraint(equalToConstant: width)
        layoutWidthConstraint?.isActive = true
    }

    init(
        printer: SavedPrinter,
        onMove: @escaping (_ sourceSerial: String, _ targetSerial: String, _ insertAfter: Bool) -> Void,
        onSelect: (() -> Void)? = nil
    ) {
        serial = printer.serial
        self.onMove = onMove
        self.onSelect = onSelect
        backdrop = CompactPrinterRowView.makeBackdrop()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        registerForDraggedTypes([printerCardPasteboardType])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked)))
        layoutWidthConstraint = widthAnchor.constraint(equalToConstant: 456)
        layoutWidthConstraint?.isActive = true
        heightAnchor.constraint(equalToConstant: 31).isActive = true

        let rowContent = NSView()
        rowContent.wantsLayer = true
        rowContent.translatesAutoresizingMaskIntoConstraints = false
        // On macOS 26 the glass view hosts its content; on older systems we stack it over the material.
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            glass.contentView = rowContent
        } else {
            addSubview(rowContent)
            NSLayoutConstraint.activate([
                rowContent.leadingAnchor.constraint(equalTo: leadingAnchor),
                rowContent.trailingAnchor.constraint(equalTo: trailingAnchor),
                rowContent.topAnchor.constraint(equalTo: topAnchor),
                rowContent.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        dropIndicatorLayer.backgroundColor = NSColor.systemBlue.cgColor
        dropIndicatorLayer.cornerRadius = 1
        dropIndicatorLayer.opacity = 0
        dropIndicatorLayer.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        rowContent.layer?.addSublayer(dropIndicatorLayer)

        let handle = PrinterDragHandle { [weak self] event in self?.beginRowDrag(with: event) }
        dragHandle = handle
        stateIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        stateIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = GantryTheme.text
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.widthAnchor.constraint(equalToConstant: 128).isActive = true
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [handle, stateIcon, nameLabel, NSView(), statusLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowContent.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rowContent.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: rowContent.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: rowContent.centerYAnchor)
        ])
        update(printer: printer, telemetry: .init(), message: nil, settings: AppSettings.shared)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func rowClicked() { onSelect?() }

    override func layout() {
        super.layout()
        if dropIndicatorLayer.opacity > 0 {
            dropIndicatorLayer.frame.size.width = max(0, bounds.width - 16)
        }
    }

    func update(printer: SavedPrinter, telemetry: PrinterTelemetry, message: String?, settings: AppSettings) {
        nameLabel.stringValue = printer.name
        nameLabel.toolTip = printer.name
        let baseStatus = message ?? settings.activityLabel(stage: telemetry.currentStage, state: telemetry.state)
        if message == nil, telemetry.state == .printing || telemetry.state == .paused {
            statusLabel.stringValue = "\(baseStatus) · \(telemetry.progress)%"
        } else {
            statusLabel.stringValue = baseStatus
        }
        statusLabel.toolTip = statusLabel.stringValue
        let stale = telemetry.lastUpdated.map { Date().timeIntervalSince($0) > 90 } ?? false
        statusLabel.textColor = stale ? .systemOrange : (telemetry.state == .error ? GantryTheme.statusPrinting : GantryTheme.secondary)
        stateIcon.image = NSImage(systemSymbolName: telemetry.state.symbol, accessibilityDescription: baseStatus)
        stateIcon.contentTintColor = stateColor(telemetry.state)

        // Neutral glass to match the flat translucent cards; only an error carries a faint warm wash.
        // (macOS 26 tint only; on older systems the error is already carried by the icon and red text.)
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            glass.tintColor = telemetry.state == .error ? GantryTheme.statusPrinting.withAlphaComponent(0.08) : .clear
        }
    }

    /// Backdrop for the compact row: the macOS 26 "liquid glass" effect where available, degrading to a
    /// standard translucent material on older systems so the app still runs on macOS 14+.
    private static func makeBackdrop() -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 12
            glass.tintColor = .clear
            return glass
        }
        let effect = NSVisualEffectView()
        effect.blendingMode = .behindWindow
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        return effect
    }

    // Match the neutral card contract: state is carried by the icon shape and the label text,
    // never by a loud colour. Only a genuine error keeps a quiet accent so it still stands out.
    private func stateColor(_ state: PrinterState) -> NSColor {
        state == .error ? GantryTheme.statusPrinting : GantryTheme.accent
    }

    private func beginRowDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(serial, forType: printerCardPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let representation = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: representation)
            image.addRepresentation(representation)
        }
        draggingItem.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragHandle?.reset()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicatorLayer.opacity = 0
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.string(forType: printerCardPasteboardType) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropIndicatorLayer.opacity = 0 }
        guard let sourceSerial = sender.draggingPasteboard.string(forType: printerCardPasteboardType),
              sourceSerial != serial else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        onMove(sourceSerial, serial, point.y < bounds.midY)
        return true
    }

    private func updateDropIndicator(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let sourceSerial = sender.draggingPasteboard.string(forType: printerCardPasteboardType),
              sourceSerial != serial else {
            dropIndicatorLayer.opacity = 0
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let insertAfter = point.y < bounds.midY
        dropIndicatorLayer.frame = NSRect(
            x: 8,
            y: insertAfter ? 1 : bounds.maxY - 3,
            width: max(0, bounds.width - 16),
            height: 2
        )
        dropIndicatorLayer.opacity = 1
        return .move
    }
}

@MainActor
private final class PrinterCardView: NSView, NSDraggingSource {
    let serial: String
    private let onShowDetails: () -> Void
    private let stateEmphasisLayer = CAGradientLayer()
    private let dropIndicatorLayer = CALayer()
    private let nameLabel = NSTextField(labelWithString: "")
    private let manufacturerLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let stateDot = NSImageView()
    private let jobStateDot = NSView()
    private let jobLabel = MarqueeLabel()
    private let jobSeparator = NSTextField(labelWithString: "·")
    private let progressSummary = NSStackView()
    private let progress = BrutalistProgressView()
    private let percentLabel = NSTextField(labelWithString: "0%")
    private static let finishTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short   // respects the system 12/24-hour setting
        formatter.dateStyle = .none
        return formatter
    }()
    private let etaMetric = CompactMetricView(symbol: "clock", tooltip: "ETA", chip: false)
    private let layerMetric = CompactMetricView(symbol: "square.3.layers.3d", tooltip: "Layer")
    // Nozzle/bed/chamber use explicit text labels (Dysza/L/P, Stół, Komora) instead of glued
    // temperatures so the two-nozzle order is unambiguous.
    private let leftNozzleMetric = LabeledMetricView()
    private let rightNozzleMetric = LabeledMetricView()
    private let bedMetric = LabeledMetricView()
    private let chamberMetric = LabeledMetricView()
    private let nozzleRow = NSStackView()
    private let envRow = NSStackView()
    private let tempBento = TemperatureBentoView()
    private let filamentDock = FilamentDockView()
    // Flat-card prototype: thin full-width rules separate the sections instead of nested bento boxes.
    private let tempDivider = PrinterCardView.makeDivider()
    private let amsDivider = PrinterCardView.makeDivider()
    // Disconnect scrim: dims the whole card and shows the connection error when the printer is offline.
    private let disconnectOverlay = PassthroughView()
    private let disconnectLabel = NSTextField(labelWithString: "")
    // Small dismissible notice at the bottom of the card (e.g. a Spoolbase spool auto-detached by an NFC roll).
    private let noticeBanner = NSView()
    private let noticeLabel = NSTextField(labelWithString: "")
    private let noticeOKButton = NSButton()
    private var onDismissNotice: (() -> Void)?
    // The spool-assignment overlay lives on the popover's content view (not a nested NSPopover, which a
    // transient menu-bar popover would instantly dismiss). Static so it survives a card rebuild.
    private static var activeSpoolBackdrop: NSView?
    private static var activeSpoolVC: SpoolAssignPopoverViewController?
    static func dismissSpoolOverlay() {
        activeSpoolBackdrop?.removeFromSuperview()
        activeSpoolBackdrop = nil
        activeSpoolVC = nil
    }
    private var layoutWidthConstraint: NSLayoutConstraint?
    private var dragHandle: PrinterDragHandle?
    private var renderedGroups: [FilamentGroup] = []
    /// Signature of the last-rendered filament dock, so it rebuilds only when the AMS/EXT data or an
    /// assigned Spoolbase spool actually changes — not on every telemetry tick (which caused a jitter).
    private var lastFilamentSignature: String?
    private var lastMetricsKey: String?
    private var lastDual = false
    private var currentLayoutWidth: CGFloat = 456
    private var displayedRemainingMinutes: Int?
    private var etaUpdatedAt: Date?
    private var lastJobName: String?
    private var lastState: PrinterState?
    private var emphasizedState: PrinterState?

    init(
        printer: SavedPrinter,
        onEdit: @escaping () -> Void,
        onReconnect: @escaping () -> Void,
        onOpenCamera: @escaping () -> Void,
        onShowDetails: @escaping () -> Void,
        onOpenSlicer: @escaping (URL) -> Void,
        onCopyIP: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onMove: @escaping (_ sourceSerial: String, _ targetSerial: String, _ insertAfter: Bool) -> Void
    ) {
        serial = printer.serial
        self.onShowDetails = onShowDetails
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = GantryTheme.cardRadius
        // Translucent card so the panel's vibrancy shows through instead of a flat black block that
        // clashes with the see-through panel.
        layer?.backgroundColor = GantryTheme.card.withAlphaComponent(0.5).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = GantryTheme.line.cgColor
        layer?.masksToBounds = true
        let cardContent = NSView()
        cardContent.wantsLayer = true
        cardContent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardContent)
        NSLayoutConstraint.activate([
            cardContent.topAnchor.constraint(equalTo: topAnchor),
            cardContent.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardContent.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardContent.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        stateEmphasisLayer.cornerRadius = GantryTheme.cardRadius
        stateEmphasisLayer.opacity = 0
        // A radial "status glow" anchored at the top-leading corner (per the layout contract's
        // statusAppearance): start just outside the top-left, fade out before the opposite side.
        stateEmphasisLayer.type = .radial
        stateEmphasisLayer.startPoint = CGPoint(x: -0.05, y: 1.05)
        stateEmphasisLayer.endPoint = CGPoint(x: 1.15, y: -0.05)
        stateEmphasisLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
            "borderWidth": NSNull(),
            "opacity": NSNull(),
            "colors": NSNull(),
            "locations": NSNull()
        ]
        cardContent.layer?.insertSublayer(stateEmphasisLayer, at: 0)
        registerForDraggedTypes([printerCardPasteboardType])
        // Minimum, not fixed: the card grows when AMS chips wrap onto extra rows (multiple AMS units).
        heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        dropIndicatorLayer.backgroundColor = NSColor.systemBlue.cgColor
        dropIndicatorLayer.cornerRadius = 1.5
        dropIndicatorLayer.opacity = 0
        dropIndicatorLayer.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        cardContent.layer?.addSublayer(dropIndicatorLayer)

        stateDot.image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: "Printer")
        stateDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        stateDot.widthAnchor.constraint(equalToConstant: 14).isActive = true
        stateDot.heightAnchor.constraint(equalToConstant: 14).isActive = true
        jobStateDot.wantsLayer = true
        jobStateDot.layer?.cornerRadius = 3
        jobStateDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        jobStateDot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        manufacturerLabel.font = .systemFont(ofSize: 10, weight: .regular)
        manufacturerLabel.textColor = .tertiaryLabelColor
        manufacturerLabel.wantsLayer = true
        manufacturerLabel.layer?.cornerRadius = 5
        manufacturerLabel.layer?.borderWidth = 1
        manufacturerLabel.layer?.borderColor = GantryTheme.line.cgColor
        manufacturerLabel.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.025).cgColor
        manufacturerLabel.lineBreakMode = .byTruncatingTail
        manufacturerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail

        var actionEntries: [CardActionsButton.Entry] = [
            .init(polishTitle: "Szczegóły", englishTitle: "Details", symbol: "chart.xyaxis.line", action: onShowDetails),
            .init(polishTitle: "Połącz ponownie", englishTitle: "Reconnect", symbol: "arrow.clockwise", action: onReconnect)
        ]
        // Camera lives in Bambu Studio, so it only makes sense for Bambu printers.
        if printer.kind == .bambu {
            actionEntries.append(.init(polishTitle: "Kamera w Bambu Studio", englishTitle: "Camera in Bambu Studio",
                                       symbol: "video.fill", action: onOpenCamera))
        }
        // Any printer can open a slicer; offer whichever are installed as a submenu.
        let slicers = SlicerLauncher.installed()
        if !slicers.isEmpty {
            let slicerEntries = slicers.map { slicer in
                CardActionsButton.Entry(polishTitle: slicer.name, englishTitle: slicer.name,
                                        symbol: "square.and.arrow.up", action: { onOpenSlicer(slicer.url) })
            }
            actionEntries.append(.init(polishTitle: "Otwórz slicer", englishTitle: "Open slicer",
                                       symbol: "square.and.arrow.up", submenu: slicerEntries))
        }
        actionEntries.append(contentsOf: [
            .init(polishTitle: "Kopiuj adres IP", englishTitle: "Copy IP address", symbol: "doc.on.doc", action: onCopyIP),
            .init(polishTitle: "Edytuj drukarkę", englishTitle: "Edit printer", symbol: "pencil", action: onEdit),
            .init(polishTitle: "Usuń drukarkę", englishTitle: "Remove printer", symbol: "trash", action: onRemove)
        ])
        let actions = CardActionsButton(entries: actionEntries)
        let handle = PrinterDragHandle { [weak self] event in self?.beginCardDrag(with: event) }
        dragHandle = handle
        // Name and a small secondary manufacturer/model label sit together, e.g. "Warsztat · P1S".
        let titleCluster = NSStackView(views: [nameLabel, manufacturerLabel])
        titleCluster.orientation = .horizontal
        titleCluster.alignment = .centerY
        titleCluster.spacing = 5
        // A small "bento" pill next to the name opens the detail view directly (also in the ⋯ menu).
        // Quiet, secondary chip — a thin outline instead of a loud filled blue pill, so a wall of
        // cards doesn't read as a wall of buttons.
        let detailsChip = NSView()
        detailsChip.wantsLayer = true
        detailsChip.layer?.cornerRadius = 10
        detailsChip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.065).cgColor
        let detailsIcon = NSImageView(image: NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: nil) ?? NSImage())
        detailsIcon.contentTintColor = GantryTheme.text
        detailsIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        detailsIcon.translatesAutoresizingMaskIntoConstraints = false
        detailsChip.addSubview(detailsIcon)
        NSLayoutConstraint.activate([
            detailsChip.widthAnchor.constraint(equalToConstant: 20),
            detailsChip.heightAnchor.constraint(equalToConstant: 20),
            detailsIcon.centerXAnchor.constraint(equalTo: detailsChip.centerXAnchor),
            detailsIcon.centerYAnchor.constraint(equalTo: detailsChip.centerYAnchor),
            detailsIcon.widthAnchor.constraint(equalToConstant: 11),
            detailsIcon.heightAnchor.constraint(equalToConstant: 11)
        ])
        detailsChip.toolTip = AppSettings.shared.text("Szczegóły", "Details")
        detailsChip.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(detailsPressed)))
        detailsChip.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [stateDot, titleCluster, detailsChip, NSView(), handle, actions])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7

        jobLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        jobLabel.textColor = .labelColor
        jobLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        jobLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progress.heightAnchor.constraint(equalToConstant: 8).isActive = true
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        percentLabel.alignment = .left
        // Hug the content instead of a fixed 46 px that clipped "100%".
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)
        percentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Status and job name deliberately share a single line. The marquee makes the complete name
        // available on hover without allowing a long file name to increase the card height.
        jobSeparator.stringValue = "·"
        jobSeparator.font = .systemFont(ofSize: 10, weight: .semibold)
        jobSeparator.textColor = .tertiaryLabelColor
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [jobStateDot, statusLabel, jobSeparator, jobLabel, statusSpacer])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 5

        // Layers ride the progress line next to ETA (there was dead space there) so the status line can
        // hand its full width to the file name instead of truncating it.
        [percentLabel, etaMetric, layerMetric, NSView()].forEach { progressSummary.addArrangedSubview($0) }
        progressSummary.orientation = .horizontal
        progressSummary.alignment = .centerY
        progressSummary.spacing = 7
        // First temperature row: single nozzle → [Dysza, Stół, Komora?]; dual nozzle → [L, P].
        nozzleRow.orientation = .horizontal
        nozzleRow.alignment = .centerY
        nozzleRow.spacing = 12
        // Second temperature row, used only for dual-nozzle printers → [Stół, Komora?].
        envRow.orientation = .horizontal
        envRow.alignment = .centerY
        envRow.spacing = 12
        filamentDock.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filamentDock.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Printer identity, job, ETA and progress form one flexible bento. When a row-mate is taller,
        // only this surface absorbs the difference; temperature and AMS/EXT stay aligned.
        let jobSurface = NSView()
        jobSurface.wantsLayer = true
        // Flat prototype: no box around the job section (transparent, no border).
        jobSurface.layer?.cornerRadius = 0
        jobSurface.layer?.backgroundColor = NSColor.clear.cgColor
        jobSurface.layer?.borderWidth = 0
        jobSurface.setContentHuggingPriority(.defaultLow, for: .vertical)
        let flexibleJobSpace = NSView()
        flexibleJobSpace.setContentHuggingPriority(.defaultLow, for: .vertical)
        flexibleJobSpace.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let jobStack = NSStackView(views: [header, statusRow, flexibleJobSpace, progressSummary, progress])
        jobStack.orientation = .vertical
        jobStack.alignment = .leading
        jobStack.spacing = 1
        jobStack.translatesAutoresizingMaskIntoConstraints = false
        jobSurface.addSubview(jobStack)
        NSLayoutConstraint.activate([
            jobStack.leadingAnchor.constraint(equalTo: jobSurface.leadingAnchor, constant: 2),
            jobStack.trailingAnchor.constraint(equalTo: jobSurface.trailingAnchor, constant: -2),
            jobStack.topAnchor.constraint(equalTo: jobSurface.topAnchor, constant: 2),
            jobStack.bottomAnchor.constraint(equalTo: jobSurface.bottomAnchor, constant: -2),
            header.widthAnchor.constraint(equalTo: jobStack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: jobStack.widthAnchor),
            progressSummary.widthAnchor.constraint(equalTo: jobStack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: jobStack.widthAnchor)
        ])

        let stack = NSStackView(views: [jobSurface, tempDivider, tempBento, amsDivider, filamentDock])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let content = cardContent
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            jobSurface.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tempBento.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filamentDock.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tempDivider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            amsDivider.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        // Disconnect scrim on top of everything (click-through, so ⋯/details still work).
        disconnectOverlay.wantsLayer = true
        disconnectOverlay.layer?.backgroundColor = GantryTheme.canvas.withAlphaComponent(0.66).cgColor
        disconnectOverlay.layer?.cornerRadius = GantryTheme.cardRadius
        disconnectOverlay.isHidden = true
        let offIcon = NSImageView(image: NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil) ?? NSImage())
        offIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        offIcon.contentTintColor = GantryTheme.secondary
        disconnectLabel.font = .systemFont(ofSize: 11, weight: .medium)
        disconnectLabel.textColor = GantryTheme.secondary
        disconnectLabel.alignment = .center
        disconnectLabel.lineBreakMode = .byWordWrapping
        disconnectLabel.maximumNumberOfLines = 3
        let offStack = NSStackView(views: [offIcon, disconnectLabel])
        offStack.orientation = .vertical
        offStack.alignment = .centerX
        offStack.spacing = 6
        offStack.translatesAutoresizingMaskIntoConstraints = false
        disconnectOverlay.addSubview(offStack)
        disconnectOverlay.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(disconnectOverlay)
        NSLayoutConstraint.activate([
            disconnectOverlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            disconnectOverlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            disconnectOverlay.topAnchor.constraint(equalTo: content.topAnchor),
            disconnectOverlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            offStack.centerXAnchor.constraint(equalTo: disconnectOverlay.centerXAnchor),
            offStack.centerYAnchor.constraint(equalTo: disconnectOverlay.centerYAnchor),
            offStack.leadingAnchor.constraint(greaterThanOrEqualTo: disconnectOverlay.leadingAnchor, constant: 16),
            offStack.trailingAnchor.constraint(lessThanOrEqualTo: disconnectOverlay.trailingAnchor, constant: -16)
        ])

        // Bottom notice banner (spool auto-detached, etc.) with an OK to dismiss.
        noticeBanner.wantsLayer = true
        noticeBanner.layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.09, alpha: 0.98).cgColor
        noticeBanner.layer?.cornerRadius = 10
        noticeBanner.layer?.borderWidth = 1
        noticeBanner.layer?.borderColor = GantryTheme.line.cgColor
        noticeBanner.isHidden = true
        noticeBanner.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        noticeLabel.textColor = GantryTheme.text
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 3
        noticeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Yield horizontal room to the OK button so it is never pushed out of view.
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeOKButton.title = "OK"
        noticeOKButton.bezelStyle = .rounded
        noticeOKButton.controlSize = .regular
        noticeOKButton.bezelColor = GantryTheme.accent
        noticeOKButton.contentTintColor = GantryTheme.canvas
        noticeOKButton.font = .systemFont(ofSize: 11, weight: .bold)
        noticeOKButton.target = self
        noticeOKButton.action = #selector(dismissNoticeTapped)
        noticeOKButton.setContentHuggingPriority(.required, for: .horizontal)
        noticeOKButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        noticeOKButton.translatesAutoresizingMaskIntoConstraints = false
        let noticeRow = NSStackView(views: [noticeLabel, noticeOKButton])
        noticeRow.orientation = .horizontal
        noticeRow.alignment = .centerY
        noticeRow.spacing = 8
        noticeRow.translatesAutoresizingMaskIntoConstraints = false
        noticeBanner.addSubview(noticeRow)
        content.addSubview(noticeBanner)
        NSLayoutConstraint.activate([
            noticeBanner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            noticeBanner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            noticeBanner.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            noticeRow.leadingAnchor.constraint(equalTo: noticeBanner.leadingAnchor, constant: 10),
            noticeRow.trailingAnchor.constraint(equalTo: noticeBanner.trailingAnchor, constant: -8),
            noticeRow.topAnchor.constraint(equalTo: noticeBanner.topAnchor, constant: 6),
            noticeRow.bottomAnchor.constraint(equalTo: noticeBanner.bottomAnchor, constant: -6)
        ])

        update(printer: printer, telemetry: .init(), message: nil, settings: AppSettings.shared)
        self.onMove = onMove
    }

    @objc private func dismissNoticeTapped() {
        noticeBanner.isHidden = true
        onDismissNotice?()
    }

    /// Shows a dismissible notice at the bottom of the card, or hides it when there is nothing to say.
    func showNotices(_ texts: [String], onDismiss: @escaping () -> Void) {
        guard !texts.isEmpty else { noticeBanner.isHidden = true; return }
        noticeLabel.stringValue = texts.joined(separator: "\n")
        onDismissNotice = onDismiss
        noticeBanner.isHidden = false
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        stateEmphasisLayer.frame = bounds
    }

    private var onMove: ((_ sourceSerial: String, _ targetSerial: String, _ insertAfter: Bool) -> Void)?

    func setLayoutWidth(_ width: CGFloat) {
        layoutWidthConstraint?.isActive = false
        layoutWidthConstraint = widthAnchor.constraint(equalToConstant: width)
        layoutWidthConstraint?.isActive = true
        // A wider card can collapse a dual-nozzle printer's two temperature rows into one, so
        // re-evaluate the layout whenever the width changes.
        currentLayoutWidth = width
        configureMetricsLayout(dual: lastDual, settings: AppSettings.shared)
    }

    @objc private func detailsPressed() { onShowDetails() }

    private func beginCardDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(serial, forType: printerCardPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let representation = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: representation)
            image.addRepresentation(representation)
        }
        draggingItem.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragHandle?.reset()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicatorLayer.opacity = 0
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.string(forType: printerCardPasteboardType) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropIndicatorLayer.opacity = 0 }
        guard let sourceSerial = sender.draggingPasteboard.string(forType: printerCardPasteboardType),
              sourceSerial != serial else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        onMove?(sourceSerial, serial, point.x >= bounds.midX)
        return true
    }

    private func updateDropIndicator(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let sourceSerial = sender.draggingPasteboard.string(forType: printerCardPasteboardType),
              sourceSerial != serial else {
            dropIndicatorLayer.opacity = 0
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let after = point.x >= bounds.midX
        dropIndicatorLayer.frame = NSRect(x: after ? bounds.maxX - 4 : 1, y: 10, width: 3, height: max(0, bounds.height - 20))
        dropIndicatorLayer.opacity = 1
        return .move
    }

    func update(printer: SavedPrinter, telemetry: PrinterTelemetry, message: String?, settings: AppSettings) {
        nameLabel.stringValue = printer.name
        manufacturerLabel.stringValue = switch printer.kind {
        case .bambu: " MQTT "
        case .klipper: " KLIPPER "
        case .prusa: " PRUSALINK "
        case .snapmaker: " HTTP "
        }
        manufacturerLabel.isHidden = false
        let dataAge = telemetry.lastUpdated.map { max(0, Date().timeIntervalSince($0)) }
        let stale = dataAge.map { $0 > 90 } ?? false
        let baseStatus = message ?? settings.activityLabel(stage: telemetry.currentStage, state: telemetry.state)
        if let dataAge, dataAge >= 60 {
            statusLabel.stringValue = "\(baseStatus) • \(shortAge(dataAge))"
        } else {
            statusLabel.stringValue = baseStatus
        }
        statusLabel.toolTip = baseStatus
        statusLabel.textColor = stale ? .systemOrange : (message == nil ? stateColor(telemetry.state) : .secondaryLabelColor)
        stateDot.contentTintColor = stateColor(telemetry.state)
        jobStateDot.layer?.backgroundColor = stateColor(telemetry.state).cgColor
        updateCardEmphasis(for: telemetry.state)

        if telemetry.state == .error {
            let errorDescription = HMSResolver.shared.description(for: telemetry.hmsCodes, serial: printer.serial, language: settings.language)
                ?? (telemetry.errorCode != 0
                    ? String(format: settings.text("Kod błędu: 0x%llX", "Error code: 0x%llX"), telemetry.errorCode)
                    : settings.text("Drukarka zgłosiła błąd", "Printer reported an error"))
            jobLabel.stringValue = errorDescription
            jobLabel.toolTip = errorDescription
        } else {
            // Only an actively running/paused print has a job to show. On finished/idle the printer
            // still echoes the last filename, so we treat those as "no active job" and hide the name.
            let hasActiveJob = (telemetry.state == .printing || telemetry.state == .paused)
                && telemetry.jobName?.isEmpty == false
            jobLabel.stringValue = hasActiveJob
                ? telemetry.jobName!
                : settings.text("BRAK AKTYWNEGO ZADANIA", "NO ACTIVE JOB")
            jobLabel.toolTip = hasActiveJob ? telemetry.jobName : nil
        }
        progress.value = telemetry.progress
        progress.tintColor = stateColor(telemetry.state)
        percentLabel.stringValue = "\(telemetry.progress)%"
        percentLabel.textColor = stateColor(telemetry.state)

        let now = Date()
        let shouldRefreshETA = etaUpdatedAt == nil
            || now.timeIntervalSince(etaUpdatedAt!) >= 300
            || lastJobName != telemetry.jobName
            || lastState != telemetry.state
        if shouldRefreshETA {
            displayedRemainingMinutes = telemetry.remainingMinutes
            etaUpdatedAt = now
        }
        lastJobName = telemetry.jobName
        lastState = telemetry.state
        let eta = displayedRemainingMinutes.map(format) ?? "—"
        // Append the estimated finish clock time next to the remaining time ("33m · 14:32"). Computed
        // from the moment the remaining time was last sampled, so the finish time stays stable between
        // refreshes instead of creeping forward every tick.
        var etaValue = eta
        if let mins = displayedRemainingMinutes, mins > 0, let base = etaUpdatedAt {
            let finish = base.addingTimeInterval(Double(mins) * 60)
            etaValue += " · \(Self.finishTimeFormatter.string(from: finish))"
        }
        let layer = telemetry.currentLayer.flatMap { current in telemetry.totalLayers.map { "\(current)/\($0)" } } ?? "—"
        etaMetric.value = etaValue
        layerMetric.value = layer

        // Resolve the nozzle collection (falls back to the legacy single-nozzle fields for parsers
        // that have not adopted the new model yet).
        let nozzles = telemetry.nozzles.isEmpty
            ? [NozzleTelemetry(position: .single, currentTemperature: telemetry.nozzleTemperature,
                               targetTemperature: telemetry.nozzleTargetTemperature)]
            : telemetry.nozzles
        let dual = nozzles.contains { $0.position == .right }
        configureMetricsLayout(dual: dual, settings: settings)

        let bed = temperature(telemetry.bedTemperature, telemetry.bedTargetTemperature)
        let chamber = telemetry.chamberTemperature.map { "\(Int($0.rounded()))°" }
        bedMetric.valueColor = tempColor(telemetry.bedTemperature, telemetry.bedTargetTemperature)
        if dual {
            let left = nozzles.first { $0.position == .left } ?? nozzles.first
            let right = nozzles.first { $0.position == .right }
            leftNozzleMetric.value = temperature(left?.currentTemperature, left?.targetTemperature)
            leftNozzleMetric.valueColor = tempColor(left?.currentTemperature, left?.targetTemperature)
            rightNozzleMetric.value = temperature(right?.currentTemperature, right?.targetTemperature)
            rightNozzleMetric.valueColor = tempColor(right?.currentTemperature, right?.targetTemperature)
            bedMetric.value = bed
            chamberMetric.value = chamber ?? ""
            chamberMetric.isHidden = chamber == nil
        } else {
            let single = nozzles.first
            leftNozzleMetric.value = temperature(single?.currentTemperature, single?.targetTemperature)
            leftNozzleMetric.valueColor = tempColor(single?.currentTemperature, single?.targetTemperature)
            bedMetric.value = bed
            chamberMetric.value = chamber ?? ""
            chamberMetric.isHidden = chamber == nil
        }
        tempBento.update(nozzles: nozzles,
                         bedCurrent: telemetry.bedTemperature,
                         bedTarget: telemetry.bedTargetTemperature,
                         chamberCurrent: telemetry.chamberTemperature,
                         settings: settings)

        // Physical filament modules, laid out as side-by-side groups that wrap in pairs. Parsers that
        // have not adopted the group model yet (Moonraker CFS/MMU) still fill the flat slot list, so
        // synthesize groups from it until they are migrated.
        let groups = telemetry.filamentGroups.isEmpty
            ? Self.legacyGroups(from: telemetry.amsSlots)
            : telemetry.filamentGroups
        // Rebuild only when the filament data or an assigned Spoolbase spool actually changes — not on
        // every telemetry tick, which recreated the views and made the slots jitter up/down.
        let filamentSig = Self.filamentSignature(groups, serial: printer.serial, settings: settings)
        if filamentSig != lastFilamentSignature {
        lastFilamentSignature = filamentSig
        renderedGroups = groups
        filamentDock.setGroups(groups, settings: settings, showRemaining: true,
                               printerSerial: printer.serial,
                               onSlotTapped: { [weak self] location, title, material, colorHex, anchor in
            guard let self, let host = self.window?.contentView else { return }
            PrinterCardView.dismissSpoolOverlay()
            let vc = SpoolAssignPopoverViewController(printerSerial: printer.serial, location: location,
                                                      slotTitle: title, amsMaterial: material,
                                                      amsColorHex: colorHex, onChange: {})
            vc.onClose = { PrinterCardView.dismissSpoolOverlay() }
            let backdrop = SpoolBackdropView(frame: host.bounds)
            backdrop.autoresizingMask = [.width, .height]
            backdrop.wantsLayer = true
            backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
            backdrop.onClickOutside = { PrinterCardView.dismissSpoolOverlay() }
            let panel = vc.view
            panel.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
                panel.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
                panel.widthAnchor.constraint(equalToConstant: 300),
                panel.heightAnchor.constraint(lessThanOrEqualTo: backdrop.heightAnchor, constant: -24)
            ])
            host.addSubview(backdrop)
            PrinterCardView.activeSpoolBackdrop = backdrop
            PrinterCardView.activeSpoolVC = vc
            _ = anchor
        })
        }

        // User-controlled card content (Settings → "Karty drukarek"). Hidden modules simply collapse
        // out of the vertical stack; the card resizes to fit whatever remains.
        jobLabel.isHidden = !settings.cardShowFileName
        jobSeparator.isHidden = !settings.cardShowFileName
        progressSummary.isHidden = !settings.cardShowProgress
        progress.isHidden = !settings.cardShowProgress
        tempBento.isHidden = !settings.cardShowTemperatures
        filamentDock.isHidden = groups.isEmpty || !settings.cardShowFilaments
        // A section rule only shows when its section is visible (no orphan lines).
        tempDivider.isHidden = tempBento.isHidden
        amsDivider.isHidden = filamentDock.isHidden

        // Offline: dim the whole card and surface the connection error over it.
        let disconnected = telemetry.state == .offline
        disconnectOverlay.isHidden = !disconnected
        if disconnected {
            disconnectLabel.stringValue = message
                ?? settings.text("Brak połączenia z drukarką", "No connection to the printer")
        }
    }

    /// A compact signature of everything the filament dock draws (group data + assigned Spoolbase spool
    /// + the grams/filament settings), so the dock rebuilds only when something visible changed.
    private static func filamentSignature(_ groups: [FilamentGroup], serial: String, settings: AppSettings) -> String {
        var parts: [String] = [settings.cardShowSpoolGrams ? "g1" : "g0", settings.cardShowFilaments ? "f1" : "f0"]
        for (gi, g) in groups.enumerated() {
            parts.append("\(g.displayName)/\(g.isExternal)/\(g.humidityPercent ?? -1)/\(g.temperatureCelsius.map { Int($0) } ?? -1)/\(g.declaredCapacity)")
            for (si, slot) in g.slots.enumerated() {
                let loc = SpoolLocation(printerSerial: serial, feeder: g.isExternal ? .ext : .ams, amsIndex: gi, slot: si)
                let sp = SpoolbaseShared.spools.spool(at: loc)
                parts.append("\(slot.label),\(slot.material ?? ""),\(slot.colorHex ?? ""),\(slot.remainingPercent ?? -1),\(slot.isActive),\(slot.remainingWeightGrams.map { Int($0) } ?? -1),\(sp?.id ?? ""),\(sp.map { Int($0.remainingWeightGrams) } ?? -1)")
            }
        }
        return parts.joined(separator: "|")
    }

    /// Rebuild the temperature rows only when the nozzle count changes. Single-nozzle printers keep a
    /// compact single row (Nozzle · Bed · Chamber); dual-nozzle printers split into an L/P row and a
    /// Bed/Chamber row.
    private func configureMetricsLayout(dual: Bool, settings: AppSettings) {
        leftNozzleMetric.label = dual ? settings.text("L", "L") : settings.text("Dysza", "Nozzle")
        rightNozzleMetric.label = settings.text("P", "R")
        bedMetric.label = settings.text("Stół", "Bed")
        chamberMetric.label = settings.text("Komora", "Chamber")
        lastDual = dual
        // Dual nozzle needs two rows in a narrow column, but a wide (full-width) card fits all four
        // temperatures on a single line — no reason to spend a second row when there's room.
        let singleRow = !dual || currentLayoutWidth >= 360
        let key = "\(dual)-\(singleRow)"
        guard lastMetricsKey != key else { return }
        lastMetricsKey = key
        if dual && !singleRow {
            setRow(nozzleRow, [leftNozzleMetric, rightNozzleMetric])
            setRow(envRow, [bedMetric, chamberMetric])
            envRow.isHidden = false
        } else if dual {
            setRow(nozzleRow, [leftNozzleMetric, rightNozzleMetric, bedMetric, chamberMetric])
            setRow(envRow, [])
            envRow.isHidden = true
        } else {
            setRow(nozzleRow, [leftNozzleMetric, bedMetric, chamberMetric])
            setRow(envRow, [])
            envRow.isHidden = true
        }
    }

    /// Bridge the legacy flat `AMSSlot` list into filament groups so parsers that have not adopted the
    /// group model yet keep rendering. External spools each become an EXT group; the rest form one
    /// module (named MMU when the labels look like Happy Hare gates, otherwise AMS).
    private static func legacyGroups(from slots: [AMSSlot]) -> [FilamentGroup] {
        guard !slots.isEmpty else { return [] }
        func convert(_ slot: AMSSlot) -> FilamentSlot {
            FilamentSlot(
                id: slot.id,
                label: slot.label,
                material: slot.material == "—" ? nil : slot.material,
                colorHex: slot.colorHex,
                remainingPercent: slot.remainingPercent,
                isActive: slot.isActive
            )
        }
        var groups: [FilamentGroup] = []
        let inner = slots.filter { !$0.isExternal }
        if !inner.isEmpty {
            let isMMU = inner.contains { $0.label.hasPrefix("T") }
            groups.append(FilamentGroup(
                id: "legacy-main",
                sourceType: isMMU ? .mmu : .ams,
                displayName: isMMU ? "MMU" : "AMS",
                declaredCapacity: inner.count,
                humidityPercent: nil,
                temperatureCelsius: nil,
                isExternal: false,
                slots: inner.map(convert)
            ))
        }
        for slot in slots where slot.isExternal {
            groups.append(FilamentGroup(
                id: "legacy-\(slot.id)",
                sourceType: .external,
                displayName: "EXT",
                declaredCapacity: 1,
                humidityPercent: nil,
                temperatureCelsius: nil,
                isExternal: true,
                slots: [convert(slot)]
            ))
        }
        return groups
    }

    private func setRow(_ row: NSStackView, _ views: [NSView]) {
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        views.forEach { row.addArrangedSubview($0) }
        if !views.isEmpty { row.addArrangedSubview(NSView()) }   // trailing spacer keeps metrics left-aligned
    }

    private func updateCardEmphasis(for state: PrinterState) {
        guard emphasizedState != state else { return }
        emphasizedState = state
        stateEmphasisLayer.removeAllAnimations()

        // Neutral cards, matching the single-tile reference: no coral wash/glow when printing. The
        // status-light is an opt-in per-card experiment, never the default for every printing card.
        _ = state
        stateEmphasisLayer.colors = nil
        stateEmphasisLayer.borderWidth = 0
        stateEmphasisLayer.opacity = 0
    }

    private func stateColor(_ state: PrinterState) -> NSColor {
        // Every card is neutral (--accent #d4d7d3); the state is carried by the label text, not colour.
        GantryTheme.accent
    }

    /// A 1px full-width rule used to separate flat card sections (replaces the nested bento boxes).
    static func makeDivider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = GantryTheme.line.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func format(_ minutes: Int) -> String { minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m" }
    private func shortAge(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h"
    }
    private func temperature(_ current: Double?, _ target: Double?) -> String {
        guard let current else { return "—" }
        if let target, target > 0 { return "\(Int(current.rounded()))/\(Int(target.rounded()))°" }
        return "\(Int(current.rounded()))°"
    }

    // Muted, desaturated hints — a whisper of warm/cool, not a bright signal that fights the UI.
    private static let heatingColor = NSColor(calibratedRed: 0.82, green: 0.55, blue: 0.51, alpha: 1)
    private static let coolingColor = NSColor(calibratedRed: 0.55, green: 0.66, blue: 0.78, alpha: 1)

    /// Tints a temperature by what it's doing: warming toward a setpoint reads red, cooling down from
    /// one reads blue, and holding at (or near) the setpoint stays the neutral default.
    private func tempColor(_ current: Double?, _ target: Double?) -> NSColor {
        if AppSettings.shared.monochrome { return .secondaryLabelColor }
        guard let current else { return .secondaryLabelColor }
        let target = target ?? 0
        if target > 5, current < target - 3 { return Self.heatingColor }        // ramping up
        if current > max(target, 0) + 5, current > 30 { return Self.coolingColor } // above setpoint, still warm
        return .secondaryLabelColor                                              // at temperature / idle
    }
}

@MainActor
private final class PrinterDragHandle: NSView {
    private let onDrag: (NSEvent) -> Void
    private var didBeginDrag = false

    init(onDrag: @escaping (NSEvent) -> Void) {
        self.onDrag = onDrag
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.065).cgColor
        toolTip = AppSettings.shared.text("Przeciągnij w górę/dół, aby zmienić kolejność drukarek",
                                          "Drag up/down to reorder printers")
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        GantryTheme.secondary.setFill()
        // Tight, centred 2×3 dot grid — spread-out dots read as "empty / on the edge".
        let dot: CGFloat = 2.2, step: CGFloat = 4.0
        let originX = (bounds.width  - (step + dot)) / 2
        let originY = (bounds.height - (2 * step + dot)) / 2
        for column in 0..<2 {
            for row in 0..<3 {
                let rect = NSRect(x: originX + CGFloat(column) * step,
                                  y: originY + CGFloat(row) * step,
                                  width: dot, height: dot)
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        didBeginDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didBeginDrag else { return }
        didBeginDrag = true
        onDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        didBeginDrag = false
    }

    func reset() {
        didBeginDrag = false
    }
}

@MainActor
private final class CardActionsButton: NSButton {
    struct Entry {
        let polishTitle: String
        let englishTitle: String
        let symbol: String
        let action: (() -> Void)?
        let submenu: [Entry]?

        init(polishTitle: String, englishTitle: String, symbol: String,
             action: (() -> Void)? = nil, submenu: [Entry]? = nil) {
            self.polishTitle = polishTitle
            self.englishTitle = englishTitle
            self.symbol = symbol
            self.action = action
            self.submenu = submenu
        }
    }

    private final class ActionBox {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    private let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Actions")
        bezelStyle = .circular
        controlSize = .small
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.065).cgColor
        contentTintColor = GantryTheme.text
        target = self
        action = #selector(showActions)
        toolTip = AppSettings.shared.text("Więcej działań", "More actions")
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    @objc private func showActions() {
        toolTip = AppSettings.shared.text("Więcej działań", "More actions")
        let menu = buildMenu(from: entries)
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.minY), in: self)
    }

    private func buildMenu(from entries: [Entry]) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            let title = AppSettings.shared.text(entry.polishTitle, entry.englishTitle)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: title)
            if let submenu = entry.submenu {
                item.submenu = buildMenu(from: submenu)
            } else if let action = entry.action {
                item.target = self
                item.action = #selector(performAction(_:))
                item.representedObject = ActionBox(action)
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        (sender.representedObject as? ActionBox)?.run()
    }
}

@MainActor
private final class CompactMetricView: NSView {
    private let valueLabel = NSTextField(labelWithString: "—")
    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }

    init(symbol: String, tooltip: String, chip: Bool = false) {
        super.init(frame: .zero)
        self.toolTip = tooltip
        if chip {
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.025).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = GantryTheme.line.cgColor
        }
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        image.contentTintColor = .tertiaryLabelColor
        image.widthAnchor.constraint(equalToConstant: 11).isActive = true
        valueLabel.font = .monospacedDigitSystemFont(ofSize: chip ? 10 : 9, weight: chip ? .semibold : .medium)
        valueLabel.textColor = chip ? .labelColor : .secondaryLabelColor
        valueLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let stack = NSStackView(views: [image, valueLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: chip ? 7 : 0),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: chip ? -7 : 0),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: chip ? 3 : 0),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: chip ? -3 : 0)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class BrutalistProgressView: NSView {
    var value = 0 { didSet { needsDisplay = true } }
    var tintColor: NSColor = .systemBlue { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let count = 32
        let gap: CGFloat = 2
        let segmentWidth = max(1, (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count))
        let activeSegments = Int((CGFloat(max(0, min(value, 100))) / 100 * CGFloat(count)).rounded())
        for index in 0..<count {
            let rect = NSRect(x: CGFloat(index) * (segmentWidth + gap), y: 2,
                              width: segmentWidth, height: max(1, bounds.height - 4))
            (index < activeSegments ? tintColor : NSColor.labelColor.withAlphaComponent(0.12)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// The compact thermal bento shared by every dashboard card. A single-nozzle printer renders three
/// equal zones; a dual-nozzle printer renders P, L, bed and chamber in one row on its wide card.
@MainActor
private final class TemperatureBentoView: NSView {
    private let row = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Flat prototype: no box around temperatures (the zone separators still read the columns).
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        heightAnchor.constraint(equalToConstant: 34).isActive = true

        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(nozzles: [NozzleTelemetry], bedCurrent: Double?, bedTarget: Double?,
                chamberCurrent: Double?, settings: AppSettings) {
        row.arrangedSubviews.forEach {
            row.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let dual = nozzles.contains { $0.position == .right }
        var zones: [(String, Double?, Double?, NSColor)] = []
        if dual {
            let left = nozzles.first { $0.position == .left } ?? nozzles.first
            let right = nozzles.first { $0.position == .right }
            zones.append((settings.text("DYSZE L", "NOZZLES L"), left?.currentTemperature,
                          left?.targetTemperature, GantryTheme.nozzle))
            zones.append(("P", right?.currentTemperature,
                          right?.targetTemperature, GantryTheme.nozzle))
        } else {
            let nozzle = nozzles.first
            zones.append((settings.text("DYSZA", "NOZZLE"), nozzle?.currentTemperature,
                          nozzle?.targetTemperature, GantryTheme.nozzle))
        }
        zones.append((settings.text("STÓŁ", "BED"), bedCurrent, bedTarget, GantryTheme.bed))
        // Only show a chamber tile when the printer actually reports a chamber temperature — an empty
        // "KOMORA — / —" tile just steals a third of the row, so nozzle + bed take the space instead.
        if chamberCurrent != nil {
            zones.append((settings.text("KOMORA", "CHAMBER"), chamberCurrent, nil, GantryTheme.chamber))
        }

        // Temperatures are coloured by activity (not a fixed per-zone tint): warm while heating, cool
        // while cooling above the setpoint, grey at temperature / idle. Monochrome keeps every value grey.
        let heat = NSColor(calibratedRed: 0.82, green: 0.55, blue: 0.51, alpha: 1)
        let cool = NSColor(calibratedRed: 0.55, green: 0.66, blue: 0.78, alpha: 1)
        let mono = settings.monochrome
        for (index, zone) in zones.enumerated() {
            let cur = zone.1
            let tgt = zone.2 ?? 0
            let tint: NSColor
            if mono {
                tint = .secondaryLabelColor
            } else if let c = cur, tgt > 5, c < tgt - 3 {
                tint = heat
            } else if let c = cur, c > max(tgt, 0) + 5, c > 30 {
                tint = cool
            } else {
                tint = .secondaryLabelColor
            }
            row.addArrangedSubview(ThermalZoneView(label: zone.0,
                                                   current: Self.value(zone.1),
                                                   target: Self.target(zone.2),
                                                   tint: tint,
                                                   separated: index > 0))
        }
    }

    private static func value(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))°" } ?? "—"
    }

    private static func target(_ value: Double?) -> String {
        guard let value, value > 0 else { return "/ —" }
        return "/ \(Int(value.rounded()))°"
    }
}

@MainActor
private final class ThermalZoneView: NSView {
    private let accent = CALayer()
    private let separator = CALayer()
    private let ambient = CAGradientLayer()

    init(label: String, current: String, target: String, tint: NSColor, separated: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        // Neutral tile: the hue lives only on the temperature value below, so a wall of zones reads
        // as one calm surface instead of orange/gold/purple bars. A faint neutral top-light keeps depth.
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.012).cgColor
        // Flat: no colour glow, no separator lines. The zone is just its label + the coloured value.
        ambient.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor]
        ambient.actions = ["bounds": NSNull(), "position": NSNull()]
        accent.backgroundColor = NSColor.clear.cgColor
        separator.backgroundColor = NSColor.clear.cgColor
        _ = separated
        layer?.addSublayer(ambient)
        layer?.addSublayer(accent)
        layer?.addSublayer(separator)

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .monospacedSystemFont(ofSize: 7, weight: .semibold)
        labelField.textColor = .tertiaryLabelColor
        labelField.lineBreakMode = .byTruncatingTail

        let currentField = NSTextField(labelWithString: current)
        currentField.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        // The one spot of colour per zone: the live temperature carries its zone hue (nozzle warm,
        // bed gold, chamber violet) so the tile itself can stay neutral.
        currentField.textColor = tint
        let targetField = NSTextField(labelWithString: target)
        // Quiet target: small and faint so the eye catches the big current value, the target just hints.
        targetField.font = .monospacedDigitSystemFont(ofSize: 7, weight: .regular)
        targetField.textColor = .quaternaryLabelColor
        let values = NSStackView(views: [currentField, targetField])
        values.orientation = .horizontal
        values.alignment = .firstBaseline
        values.spacing = 3

        labelField.translatesAutoresizingMaskIntoConstraints = false
        values.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)
        addSubview(values)
        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            labelField.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            values.centerXAnchor.constraint(equalTo: centerXAnchor),
            values.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 5),
            values.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            values.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        ambient.frame = bounds
        accent.frame = NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1)
        separator.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
    }
}

/// A one-line label that stays put (clipped) at rest, but when the pointer hovers over it and the
/// text is wider than the view, gently scrolls back and forth so a long job name can be read in full
/// without the card having to grow taller.
@MainActor
private final class MarqueeLabel: NSView {
    private let text = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!
    private var timer: Timer?
    private var offset: CGFloat = 0
    private var direction: CGFloat = -1
    private var pause = 0

    var stringValue: String {
        get { text.stringValue }
        set { text.stringValue = newValue; resetScroll() }
    }
    var font: NSFont? {
        get { text.font }
        set { text.font = newValue }
    }
    var textColor: NSColor? {
        get { text.textColor }
        set { text.textColor = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byClipping
        text.maximumNumberOfLines = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(text)
        leading = text.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            leading,
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalTo: text.heightAnchor)
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }

    private var overflow: CGFloat { max(0, text.fittingSize.width - bounds.width) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { startScroll() }
    override func mouseExited(with event: NSEvent) { resetScroll() }
    // Never leave a timer running against a card that scrolled out of the popover.
    override func viewDidMoveToWindow() { if window == nil { resetScroll() } }

    private func startScroll() {
        guard timer == nil, overflow > 4 else { return }
        pause = 18
        let t = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        if pause > 0 { pause -= 1; return }
        let limit = overflow
        offset += direction * 0.7
        if offset <= -limit { offset = -limit; direction = 1; pause = 22 }
        else if offset >= 0 { offset = 0; direction = -1; pause = 22 }
        leading.constant = offset
    }

    private func resetScroll() {
        timer?.invalidate(); timer = nil
        offset = 0; direction = -1; pause = 0; leading.constant = 0
    }
}

/// A metric shown as a small text label plus a monospaced value, e.g. `L 245/245°`, `Stół 65/65°`.
@MainActor
/// Compact inline temperature metric for the dashboard (label + reading on one line). The taller
/// `thermalZones` tiles are used in the detail view, not here — the fleet card stays dense.
private final class LabeledMetricView: NSView {
    private let labelField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "—")
    var label: String { get { labelField.stringValue } set { labelField.stringValue = newValue } }
    var value: String { get { valueField.stringValue } set { valueField.stringValue = newValue } }
    var valueColor: NSColor { get { valueField.textColor ?? .secondaryLabelColor } set { valueField.textColor = newValue } }
    var zoneColor: NSColor = GantryTheme.secondary   // kept for API compatibility; ignored inline

    init() {
        super.init(frame: .zero)
        labelField.font = .systemFont(ofSize: 9, weight: .semibold)
        labelField.textColor = .tertiaryLabelColor
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueField.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        valueField.textColor = .secondaryLabelColor
        valueField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let stack = NSStackView(views: [labelField, valueField])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
}

/// A colour swatch whose fill rises from the bottom in proportion to the remaining filament — the
/// emptier the spool, the shorter the coloured fill. The unfilled part shows a faded tint.
@MainActor
final class FilamentSwatchView: NSView {
    private let fillLayer = CAShapeLayer()
    private let fraction: CGFloat

    init(color: NSColor, fraction: CGFloat) {
        self.fraction = max(0, min(1, fraction))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = color.withAlphaComponent(0.20).cgColor
        fillLayer.fillColor = color.cgColor
        fillLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        fillLayer.frame = bounds
        // Fill rises from the bottom with a gentle wavy top (like liquid), not a flat cut.
        let w = bounds.width, h = bounds.height
        let fillH = h * fraction
        let amp = min(0.4, fillH / 2)
        let waves: CGFloat = 1.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: fillH))
        let n = 28
        for i in 0...n {
            let x = w * CGFloat(i) / CGFloat(n)
            let y = fillH + amp * sin(2 * .pi * waves * CGFloat(i) / CGFloat(n))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: w, y: 0))
        path.closeSubpath()
        fillLayer.path = path
    }
}

@MainActor
private final class EmptyFilamentSwatchView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.018).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.075).cgColor
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).addClip()
        NSColor.white.withAlphaComponent(0.035).setStroke()
        for offset in stride(from: -bounds.height, through: bounds.width + bounds.height, by: 9) {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: offset, y: 0))
            line.line(to: NSPoint(x: offset + bounds.height, y: bounds.height))
            line.lineWidth = 4
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// One filament slot swatch. The active slot gets a thin white ring; empty slots stay grey and keep
/// their position so the group never collapses.
@MainActor
final class FilamentSlotView: NSView {
    private let onTap: ((NSView) -> Void)?

    init(slot: FilamentSlot, isExternal: Bool, showRemaining: Bool = false,
         location: SpoolLocation? = nil, onTap: ((NSView) -> Void)? = nil, isSingle: Bool = false) {
        self.onTap = onTap
        super.init(frame: .zero)
        // A manually-assigned physical spool wins over the (often unknown) AMS reading: its % and colour
        // come from Spoolbase, so a gauge-less EXT/AMS slot still shows a real level and grams.
        let assignedSpool = location.flatMap { SpoolbaseShared.spools.spool(at: $0) }
        let assignedDef = assignedSpool.flatMap { s in SpoolbaseShared.filaments.filaments.first { $0.id == s.filamentDefinitionID } }
        let present = slot.isPresent || assignedSpool != nil
        let effectivePct: Int? = assignedSpool?.percent ?? slot.remainingPercent
        let materialText: String = slot.isPresent ? (slot.material ?? "—") : (assignedDef?.type ?? assignedDef?.name ?? "—")
        var color: NSColor
        if let assignedDef {
            // The user explicitly chose this spool's filament, so its colour wins over the AMS reading.
            color = NSColor(hex: assignedDef.colorHex)
        } else if slot.isPresent {
            color = NSColor(hex: slot.colorHex ?? "8E8E93FF")
        } else {
            color = NSColor.secondaryLabelColor.withAlphaComponent(0.18)
        }
        if AppSettings.shared.monochrome { color = color.mutedTowardGrey() }
        // Flexible width so the slots stretch to fill their module (distribution .fillEqually).
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        // In the detail card the swatch fills from the bottom in proportion to the remaining amount
        // (less filament → shorter fill); elsewhere it's a solid colour chip.
        let swatch: NSView
        if showRemaining, present, let pct = effectivePct {
            swatch = FilamentSwatchView(color: color, fraction: CGFloat(pct) / 100)
        } else if present {
            swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 5
            swatch.layer?.backgroundColor = color.cgColor
        } else {
            swatch = EmptyFilamentSwatchView()
        }
        if slot.isActive {
            swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
            swatch.layer?.borderWidth = 1.5
        } else {
            // A faint light outline so the chip is always visible — even an empty/0% dark spool that
            // would otherwise vanish on the flat dark card (no group box behind it anymore).
            swatch.layer?.borderColor = GantryTheme.line.cgColor
            swatch.layer?.borderWidth = 1
        }
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
        // Keep swatches compact and readable: don't let a slot stretch wider than a tidy chip,
        // so a 4-slot AMS reads as neat squares instead of big blocks. The fill-width constraint
        // below is lowered in priority so this cap wins and the chip stays centered in its cell.
        // Multi-slot AMS keeps a compact per-slot cap so four slots read as neat squares. A single slot
        // (AMS HT / EXT) instead takes a fixed fraction of its column — set in the activate block below,
        // once the swatch is in the view hierarchy — so it scales with the card and never jumps.
        if !isSingle {
            let maxWidth = swatch.widthAnchor.constraint(lessThanOrEqualToConstant: isExternal ? 92 : 56)
            maxWidth.priority = .required
            maxWidth.isActive = true
        }

        // The remaining % lives INSIDE the colour chip, in a contrasting ink (white on a dark spool,
        // black on a light/yellow one) so it is legible whatever the filament colour is — no separate
        // row needed. A faint opposite-colour shadow keeps it readable where the fill meets the dim
        // empty part of the chip.
        if showRemaining, present, let pct = effectivePct {
            // The fill rises from the bottom by `pct`. The centred number is only over the SOLID colour
            // once the fill reaches the middle; below that it sits over the dim (dark) empty part, which
            // always wants light ink. So pick contrast by what's actually behind the text, not by the
            // spool colour alone — that fixes "black 0% on a light spool over a dark chip".
            let overSolid = CGFloat(pct) / 100 >= 0.5
            let inkIsDark = overSolid && color.contrastingTextColor == .black
            let ink: NSColor = inkIsDark ? .black : NSColor.white.withAlphaComponent(0.95)
            let shadow = NSShadow()
            shadow.shadowColor = (inkIsDark ? NSColor.white : NSColor.black).withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = .zero
            let inChip = NSTextField(labelWithString: "")
            inChip.attributedStringValue = NSAttributedString(string: "\(pct)%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: ink,
                .shadow: shadow
            ])
            inChip.alignment = .center
            inChip.translatesAutoresizingMaskIntoConstraints = false
            swatch.addSubview(inChip)
            NSLayoutConstraint.activate([
                inChip.centerXAnchor.constraint(equalTo: swatch.centerXAnchor),
                inChip.centerYAnchor.constraint(equalTo: swatch.centerYAnchor),
                inChip.leadingAnchor.constraint(greaterThanOrEqualTo: swatch.leadingAnchor, constant: 2),
                inChip.trailingAnchor.constraint(lessThanOrEqualTo: swatch.trailingAnchor, constant: -2)
            ])
        }

        // Slot id stays quiet at the leading edge; material is the primary, centered caption.
        let slotID = NSTextField(labelWithString: isExternal ? "" : slot.label)
        slotID.font = .monospacedSystemFont(ofSize: 7.5, weight: .medium)
        slotID.textColor = GantryTheme.muted
        let material = NSTextField(labelWithString: present ? materialText : "—")
        material.font = .systemFont(ofSize: 10, weight: .semibold)
        material.alignment = .center
        material.textColor = present ? GantryTheme.text : GantryTheme.muted
        material.lineBreakMode = .byTruncatingTail
        material.toolTip = "\(slot.label) • \(materialText) • \(effectivePct.map { "\($0)%" } ?? "—")"
        let meta = NSView()
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.heightAnchor.constraint(equalToConstant: 11).isActive = true
        slotID.translatesAutoresizingMaskIntoConstraints = false
        material.translatesAutoresizingMaskIntoConstraints = false
        meta.addSubview(slotID)
        meta.addSubview(material)
        NSLayoutConstraint.activate([
            slotID.leadingAnchor.constraint(equalTo: meta.leadingAnchor),
            slotID.centerYAnchor.constraint(equalTo: meta.centerYAnchor),
            material.centerXAnchor.constraint(equalTo: meta.centerXAnchor),
            material.centerYAnchor.constraint(equalTo: meta.centerYAnchor),
            material.leadingAnchor.constraint(greaterThanOrEqualTo: slotID.trailingAnchor, constant: 2),
            material.trailingAnchor.constraint(lessThanOrEqualTo: meta.trailingAnchor)
        ])

        // Remaining % now sits inside the swatch (above), so the slot is just chip + material caption.
        var slotViews: [NSView] = [swatch, meta]
        // Grams on the spool: the assigned Spoolbase weight, or the AMS NFC weight — shown only when the
        // user turned on "grams on spool" for the cards (Settings).
        if AppSettings.shared.cardShowSpoolGrams,
           let gramsValue = (assignedSpool.map { $0.remainingWeightGrams } ?? slot.remainingWeightGrams),
           gramsValue > 0 {
            let grams = NSTextField(labelWithString: "\(Int(gramsValue)) g")
            grams.font = .systemFont(ofSize: 8.5, weight: .medium)
            grams.textColor = GantryTheme.muted
            grams.alignment = .center
            slotViews.append(grams)
        }
        let stack = NSStackView(views: slotViews)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            swatch.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 1, constant: 0).withPriority(.defaultLow),
            meta.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        // A single slot (AMS HT / EXT) targets 35% of its column, but never below a legible minimum, so
        // next to a wide AMS it still reads like a slot rather than a sliver — and never wider than the
        // column. Multi-slot AMS keeps its compact per-slot cap set earlier.
        if isSingle {
            let target = swatch.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.35)
            target.priority = .defaultHigh
            let floor = swatch.widthAnchor.constraint(greaterThanOrEqualToConstant: 60)
            floor.priority = .init(999)
            let ceiling = swatch.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
            ceiling.priority = .required
            NSLayoutConstraint.activate([target, floor, ceiling])
        }

        // External spools report remain=0 as "unknown" (Bambu doesn't gauge them), so a low-filament
        // dot there is a false alarm. A chipless AMS spool is the same: remain reads 0 but is not real,
        // so only warn when the level is trustworthy — an RFID tag (weight) or an assigned Spoolbase
        // spool (issue #27).
        let trustedLevel = slot.remainingWeightGrams != nil || assignedSpool != nil
        if present, !isExternal, trustedLevel, (effectivePct ?? 100) <= 15 {
            let warning = NSView()
            warning.wantsLayer = true
            warning.layer?.backgroundColor = NSColor.systemRed.cgColor
            warning.layer?.cornerRadius = 3
            warning.layer?.borderWidth = 1
            warning.layer?.borderColor = NSColor.controlBackgroundColor.cgColor
            warning.translatesAutoresizingMaskIntoConstraints = false
            swatch.addSubview(warning)
            NSLayoutConstraint.activate([
                warning.widthAnchor.constraint(equalToConstant: 6),
                warning.heightAnchor.constraint(equalToConstant: 6),
                warning.topAnchor.constraint(equalTo: swatch.topAnchor, constant: 3),
                warning.trailingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: -3)
            ])
        }

        // Click a slot to open its spool-assignment popover (Spoolbase).
        if onTap != nil {
            toolTip = AppSettings.shared.text("Kliknij, aby przypisać rolkę", "Click to assign a spool")
            addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleTap)))
        }
    }
    required init?(coder: NSCoder) { nil }

    @objc private func handleTap() { onTap?(self) }
}

/// A physical filament module: a tonal card with a name + per-module humidity/temperature header and
/// its slots, so an AMS, AMS HT, CFS or EXT reads as one distinct unit.
@MainActor
final class FilamentGroupView: NSView {
    init(group: FilamentGroup, settings: AppSettings, showRemaining: Bool = false,
         printerSerial: String = "", groupIndex: Int = 0,
         onSlotTapped: ((SpoolLocation, String, String?, String?, NSView) -> Void)? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        // Flat prototype: no box around a filament group (fasolki + header read on their own).
        layer?.cornerRadius = 0
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        // Fill the width the dock allots (proportional to slot count), never hug.
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        let name = NSTextField(labelWithString: Self.shortName(group.displayName))
        name.font = .systemFont(ofSize: 10, weight: .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        // In a narrow card the header can't fit the name plus both metrics. Humidity/temperature are
        // the data worth keeping, so let the name shrink first (metrics resist compression, below).
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // Per-module humidity (droplet) and temperature (thermometer) as small icon + value clusters.
        // The spacer between name and metrics must collapse before the name is compressed, so a tight
        // header never shows a truncated "AMS…" while a gap sits unused next to it.
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var headerViews: [NSView] = [name, headerSpacer]
        let mono = AppSettings.shared.monochrome
        if let humidity = group.humidityPercent {
            let text = humidity <= 5 ? "\(humidity)/5" : "\(humidity)%"
            // Humidity reads green (dry/healthy), a genuinely damp module goes warm — matching the demo.
            // Monochrome mode keeps it grey.
            let tint = mono ? NSColor.secondaryLabelColor
                            : (Self.isHumidityHigh(group.humidityPercent) ? GantryTheme.statusPaused : GantryTheme.humidity)
            headerViews.append(Self.metric(symbol: "drop.fill", text: text, tint: tint))
        }
        if let temp = group.temperatureCelsius {
            headerViews.append(Self.metric(symbol: "thermometer.medium", text: "\(Int(temp.rounded()))°",
                                           tint: mono ? .secondaryLabelColor : GantryTheme.sensorTemp))
        }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let feeder: SpoolLocation.Feeder = group.isExternal ? .ext : .ams
        let slotViews = group.slots.enumerated().map { (slotIndex, slot) -> FilamentSlotView in
            let location = SpoolLocation(printerSerial: printerSerial.isEmpty ? nil : printerSerial,
                                         feeder: feeder, amsIndex: groupIndex, slot: slotIndex)
            let title = group.isExternal ? group.displayName : "\(Self.shortName(group.displayName)) \(slot.label)"
            let tap: ((NSView) -> Void)? = (onSlotTapped == nil || printerSerial.isEmpty) ? nil : { anchor in
                onSlotTapped?(location, title, slot.material, slot.colorHex, anchor)
            }
            return FilamentSlotView(slot: slot, isExternal: group.isExternal, showRemaining: showRemaining,
                                    location: printerSerial.isEmpty ? nil : location, onTap: tap, isSingle: group.slots.count == 1)
        }
        // Each slot fills its share of the module. A single spool's chip fills the column; its inner
        // swatch then takes a fixed fraction of that width (see FilamentSlotView), so a lone slot is a
        // wide rectangle and two side-by-side single groups (HT + EXT) match — and never jump, because
        // the width is a definite proportion rather than an ambiguous fill.
        let slots = NSStackView(views: slotViews)
        slots.orientation = .horizontal
        slots.alignment = .top
        slots.distribution = .fillEqually
        slots.spacing = 5

        let stack = NSStackView(views: [header, slots])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            slots.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

    /// A tight header that never truncates to "AM…": "AMS A" → "AMS" (the group letter already shows
    /// on the slot as "A1"); "AMS HT" → "HT" (keep the meaningful type). CFS/MMU/EXT stay as-is.
    private static func shortName(_ displayName: String) -> String {
        guard displayName.hasPrefix("AMS ") else { return displayName }
        let suffix = String(displayName.dropFirst(4))
        return suffix.count == 1 ? "AMS" : suffix
    }

    private static func metric(symbol: String, text: String, tint: NSColor) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        image.contentTintColor = tint
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = tint
        // The metric value must survive a tight header intact — the module name yields space first.
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        image.setContentCompressionResistancePriority(.required, for: .horizontal)
        let cluster = NSStackView(views: [image, label])
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 3
        cluster.setContentHuggingPriority(.required, for: .horizontal)
        return cluster
    }

    static func isHumidityHigh(_ value: Int?) -> Bool {
        guard let value else { return false }
        return value <= 5 ? value >= 4 : value >= 40
    }
}

/// Lays filament modules out in rows of up to two, side by side, each module's width proportional to
/// its slot count so a 4-slot AMS is wide and a single EXT stays narrow — matching the reference.
@MainActor
final class FilamentDockView: NSView {
    private let column = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

    func setGroups(_ groups: [FilamentGroup], settings: AppSettings, showRemaining: Bool = false,
                   printerSerial: String = "",
                   onSlotTapped: ((SpoolLocation, String, String?, String?, NSView) -> Void)? = nil) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var index = 0
        while index < groups.count {
            let rowGroups = Array(groups[index ..< min(index + 2, groups.count)])
            let rowStartIndex = index
            index += 2
            let views = rowGroups.enumerated().map { (offset, group) in
                FilamentGroupView(group: group, settings: settings, showRemaining: showRemaining,
                                  printerSerial: printerSerial, groupIndex: rowStartIndex + offset,
                                  onSlotTapped: onSlotTapped)
            }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fill
            row.spacing = 6
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            // An external module holds a single spool; never let it get crushed below the width its
            // "EXT" header + swatch need, even in a narrow two-column card.
            for (view, group) in zip(views, rowGroups) where group.isExternal {
                view.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
            }
            // A module that carries a humidity/temperature header needs room for "AMS A  41%  33°";
            // a single-slot AMS HT beside EXT would otherwise split 50/50 and truncate to "AM…".
            for (view, group) in zip(views, rowGroups)
            where !group.isExternal && (group.humidityPercent != nil || group.temperatureCelsius != nil) {
                view.widthAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
            }
            // Second module's width is proportional to its slot count vs the first (AMS wide, EXT
            // narrow) — but only as a preference, so the external minimum above always wins.
            // An external module counts for less than a real AMS slot, so even AMS HT (1 slot) beside
            // EXT (1 slot) stays the wider, primary module instead of splitting the row in half.
            if views.count == 2 {
                // A thin vertical rule between two devices (AMS / AMS HT / EXT) so they read as
                // separate units on the flat card.
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.backgroundColor = GantryTheme.line.cgColor
                sep.translatesAutoresizingMaskIntoConstraints = false
                row.insertArrangedSubview(sep, at: 1)
                NSLayoutConstraint.activate([
                    sep.widthAnchor.constraint(equalToConstant: 1),
                    sep.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
                    sep.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2)
                ])
                // A multi-slot module (AMS) gets a column three times as wide as a single-slot one, so an
                // AMS beside EXT reads ~3:1; two single groups (AMS HT + EXT) stay 50/50.
                func weight(_ g: FilamentGroup) -> CGFloat {
                    g.declaredCapacity > 1 ? 3 : 1
                }
                let proportional = views[1].widthAnchor.constraint(equalTo: views[0].widthAnchor, multiplier: weight(rowGroups[1]) / weight(rowGroups[0]))
                proportional.priority = .defaultHigh
                proportional.isActive = true
            } else if let only = views.first {
                // A single module owns the complete bento; the slot itself remains centered and
                // capped, so EXT reads as intentional rather than as a tiny detached tile.
                only.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            }
        }
    }
}

@MainActor
private final class ClosureButton: NSButton {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        closure = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(clicked)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func clicked() { closure() }
}

private extension NSColor {
    convenience init(hex: String) {
        let clean = String(hex.prefix(6))
        let value = UInt64(clean, radix: 16) ?? 0x808080
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    var contrastingTextColor: NSColor {
        guard let rgb = usingColorSpace(.deviceRGB) else { return .labelColor }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.58 ? .black : .white
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
