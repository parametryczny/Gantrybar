import AppKit
import Combine

private let printerCardPasteboardType = NSPasteboard.PasteboardType("pl.gantry.printer-card")

/// Flipped so a scroll's document anchors its content to the top-left; short content then
/// sits at the top instead of the bottom of the clip view.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
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
    private var subscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var timerSubscription: AnyCancellable?
    private var cardsBySerial: [String: PrinterCardView] = [:]
    private var compactRowsBySerial: [String: CompactPrinterRowView] = [:]
    private var expandedCardsBySerial: [String: PrinterCardView] = [:]
    private var expandedCompactSerials: Set<String> = []
    private var renderedSerials: [String] = []
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
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 650))
        root.wantsLayer = true
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
        summaryLabel.textColor = .secondaryLabelColor
        // The GANTRY wordmark (white PNG) is the header.
        let wordmark = NSImageView(image: GantryLogo.wordmarkImage(height: 15))
        wordmark.setContentHuggingPriority(.required, for: .horizontal)
        wordmark.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleStack = NSStackView(views: [wordmark, summaryLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        let addButton = iconButton("plus", tooltip: "Dodaj drukarkę / Add printer", action: #selector(addPressed))
        let refreshButton = iconButton("arrow.clockwise", tooltip: "Połącz ponownie / Reconnect", action: #selector(refreshPressed))
        resetButton.title = "ZRESETUJ"
        resetButton.target = self
        resetButton.action = #selector(resetPressed)
        resetButton.bezelStyle = .recessed
        resetButton.controlSize = .small
        resetButton.font = .systemFont(ofSize: 10, weight: .medium)
        resetButton.toolTip = "Usuń zakończone zadania i stare nazwy plików"
        resetButton.cell?.wraps = false
        resetButton.widthAnchor.constraint(equalToConstant: 67).isActive = true
        compactButton.target = self
        compactButton.action = #selector(toggleCompactMode)
        compactButton.bezelStyle = .recessed
        compactButton.controlSize = .small
        compactButton.font = .systemFont(ofSize: 10, weight: .medium)
        compactButton.cell?.wraps = false
        compactButton.widthAnchor.constraint(equalToConstant: 58).isActive = true
        compactButton.isHidden = true
        let header = NSStackView(views: [titleStack, NSView(), compactButton, resetButton, refreshButton, addButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9

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
            ? "\(store.printers.count) drukarek • \(online) online"
            : "\(store.printers.count) printers • \(online) online"
        let supportsCompactMode = store.printers.count >= 4
        // Full view fits up to 8 printers; above 8 default to compact. A manual toggle overrides.
        let useCompactMode = supportsCompactMode && (compactModeChosen ? prefersCompactMode : store.printers.count > 8)
        let expandedColumnCount = !useCompactMode && store.printers.count >= 9 ? 3 : 2
        // Wide enough that a two-column card fits an AMS/AMS HT name + humidity + temperature beside a
        // compact EXT without truncating (a 224 px card was too tight; ~254 px clears it).
        let panelWidth: CGFloat = expandedColumnCount == 3 ? 810 : 540
        // The popover size is reported once at the end of render() from the cards' real measured
        // height — reporting an estimate here too made the popover oscillate between the two values.
        compactButton.isHidden = !supportsCompactMode
        compactButton.title = settings.text(useCompactMode ? "Rozwiń" : "Zwiń", useCompactMode ? "Expand" : "Collapse")
        compactButton.toolTip = settings.text(
            useCompactMode ? "Pokaż pełne kafelki drukarek" : "Pokaż zwartą listę drukarek",
            useCompactMode ? "Show full printer cards" : "Show compact printer list"
        )
        cardsStack.spacing = useCompactMode ? 3 : 8
        if store.printers.isEmpty {
            detachCardRows()
            cardsBySerial.removeAll()
            compactRowsBySerial.removeAll()
            renderedSerials.removeAll()
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
        if desiredSerials != renderedSerials || renderedCompactMode != useCompactMode {
            detachCardRows()
            if renderedCompactMode != useCompactMode {
                cardsBySerial.removeAll()
                compactRowsBySerial.removeAll()
                expandedCardsBySerial.removeAll()
            }
            renderedSerials = desiredSerials
            renderedCompactMode = useCompactMode

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
                let contentWidth = panelWidth - 24
                for start in stride(from: 0, to: cards.count, by: expandedColumnCount) {
                    let slice = Array(cards[start..<min(start + expandedColumnCount, cards.count)])
                    let row = NSStackView(views: slice)
                    row.orientation = .horizontal
                    row.alignment = .top
                    row.spacing = 8
                    let cardWidth = (contentWidth - CGFloat(max(0, slice.count - 1)) * row.spacing) / CGFloat(slice.count)
                    slice.forEach { $0.setLayoutWidth(cardWidth) }
                    // Keep every card in a row the same height as the tallest one, so a short card
                    // (e.g. no AMS) stretches to match instead of leaving the row visually uneven.
                    if let tallest = slice.first {
                        for card in slice.dropFirst() {
                            let equal = card.heightAnchor.constraint(equalTo: tallest.heightAnchor)
                            equal.isActive = true
                            rowHeightConstraints.append(equal)
                        }
                    }
                    cardsStack.addArrangedSubview(row)
                }
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
            let size = NSSize(width: panelWidth, height: min(1000, chromeAndInsets + measuredContent))
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
        resetButton.title = settings.text("Wyczyść", "Clear")
        resetButton.toolTip = settings.text(
            "Usuń zakończone zadania i stare nazwy plików",
            "Clear completed jobs and old file names"
        )
        let useCompactMode = store.printers.count >= 4 && prefersCompactMode
        compactButton.title = settings.text(useCompactMode ? "Rozwiń" : "Zwiń", useCompactMode ? "Expand" : "Collapse")
    }

    private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!, target: self, action: action)
        button.bezelStyle = .circular
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
private final class CompactPrinterRowView: NSGlassEffectView, NSDraggingSource {
    let serial: String
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
        super.init(frame: .zero)

        style = .regular
        cornerRadius = 10
        tintColor = .clear
        registerForDraggedTypes([printerCardPasteboardType])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked)))
        layoutWidthConstraint = widthAnchor.constraint(equalToConstant: 456)
        layoutWidthConstraint?.isActive = true
        heightAnchor.constraint(equalToConstant: 31).isActive = true

        let rowContent = NSView()
        rowContent.wantsLayer = true
        contentView = rowContent

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
        statusLabel.textColor = stale ? .systemOrange : stateColor(telemetry.state)
        stateIcon.image = NSImage(systemSymbolName: telemetry.state.symbol, accessibilityDescription: baseStatus)
        stateIcon.contentTintColor = stateColor(telemetry.state)

        switch telemetry.state {
        case .error:
            tintColor = .systemRed.withAlphaComponent(0.09)
        case .finished:
            tintColor = .systemGreen.withAlphaComponent(0.08)
        default:
            tintColor = .clear
        }
    }

    private func stateColor(_ state: PrinterState) -> NSColor {
        switch state {
        case .printing: .systemBlue
        case .idle, .finished: .systemGreen
        case .paused: .systemOrange
        case .error: .systemRed
        case .offline: .secondaryLabelColor
        }
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
private final class PrinterCardView: NSGlassEffectView, NSDraggingSource {
    let serial: String
    private let onShowDetails: () -> Void
    private let stateEmphasisLayer = CALayer()
    private let dropIndicatorLayer = CALayer()
    private let nameLabel = NSTextField(labelWithString: "")
    private let manufacturerLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let stateDot = NSImageView()
    private let jobLabel = MarqueeLabel()
    private let progress = BrutalistProgressView()
    private let percentLabel = NSTextField(labelWithString: "0%")
    private static let finishTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short   // respects the system 12/24-hour setting
        formatter.dateStyle = .none
        return formatter
    }()
    private let etaMetric = CompactMetricView(symbol: "clock", tooltip: "ETA")
    private let layerMetric = CompactMetricView(symbol: "square.3.layers.3d", tooltip: "Layer")
    // Nozzle/bed/chamber use explicit text labels (Dysza/L/P, Stół, Komora) instead of glued
    // temperatures so the two-nozzle order is unambiguous.
    private let leftNozzleMetric = LabeledMetricView()
    private let rightNozzleMetric = LabeledMetricView()
    private let bedMetric = LabeledMetricView()
    private let chamberMetric = LabeledMetricView()
    private let nozzleRow = NSStackView()
    private let envRow = NSStackView()
    private let filamentDock = FilamentDockView()
    private var layoutWidthConstraint: NSLayoutConstraint?
    private var dragHandle: PrinterDragHandle?
    private var renderedGroups: [FilamentGroup] = []
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
        style = .regular
        cornerRadius = 18
        tintColor = NSColor.controlBackgroundColor.withAlphaComponent(0.12)
        let cardContent = NSView()
        cardContent.wantsLayer = true
        stateEmphasisLayer.cornerRadius = 18
        stateEmphasisLayer.opacity = 0
        stateEmphasisLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
            "borderWidth": NSNull(),
            "opacity": NSNull()
        ]
        cardContent.layer?.insertSublayer(stateEmphasisLayer, at: 0)
        contentView = cardContent
        registerForDraggedTypes([printerCardPasteboardType])
        // Minimum, not fixed: the card grows when AMS chips wrap onto extra rows (multiple AMS units).
        heightAnchor.constraint(greaterThanOrEqualToConstant: 174).isActive = true

        dropIndicatorLayer.backgroundColor = NSColor.systemBlue.cgColor
        dropIndicatorLayer.cornerRadius = 1.5
        dropIndicatorLayer.opacity = 0
        dropIndicatorLayer.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        cardContent.layer?.addSublayer(dropIndicatorLayer)

        stateDot.widthAnchor.constraint(equalToConstant: 15).isActive = true
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        manufacturerLabel.font = .systemFont(ofSize: 10, weight: .regular)
        manufacturerLabel.textColor = .tertiaryLabelColor
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
        titleCluster.alignment = .firstBaseline
        titleCluster.spacing = 5
        // A small "bento" pill next to the name opens the detail view directly (also in the ⋯ menu).
        let detailsChip = NSView()
        detailsChip.wantsLayer = true
        detailsChip.layer?.cornerRadius = 9
        detailsChip.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        let detailsIcon = NSImageView(image: NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: nil) ?? NSImage())
        detailsIcon.contentTintColor = .white
        detailsIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        let detailsText = NSTextField(labelWithString: AppSettings.shared.text("Szczegóły", "Details"))
        detailsText.font = .systemFont(ofSize: 10, weight: .bold)
        detailsText.textColor = .white
        let detailsInner = NSStackView(views: [detailsIcon, detailsText])
        detailsInner.orientation = .horizontal
        detailsInner.alignment = .centerY
        detailsInner.spacing = 3
        detailsInner.translatesAutoresizingMaskIntoConstraints = false
        detailsChip.addSubview(detailsInner)
        NSLayoutConstraint.activate([
            detailsInner.topAnchor.constraint(equalTo: detailsChip.topAnchor, constant: 3),
            detailsInner.bottomAnchor.constraint(equalTo: detailsChip.bottomAnchor, constant: -3),
            detailsInner.leadingAnchor.constraint(equalTo: detailsChip.leadingAnchor, constant: 8),
            detailsInner.trailingAnchor.constraint(equalTo: detailsChip.trailingAnchor, constant: -8)
        ])
        detailsChip.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(detailsPressed)))
        detailsChip.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [stateDot, titleCluster, detailsChip, NSView(), handle, actions])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7

        jobLabel.font = .systemFont(ofSize: 10, weight: .regular)
        jobLabel.textColor = .secondaryLabelColor
        progress.heightAnchor.constraint(equalToConstant: 11).isActive = true
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        percentLabel.alignment = .right
        percentLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let progressRow = NSStackView(views: [progress, percentLabel])
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = 6

        // Time remaining + layer count ride on the status line ("Drukowanie … ⏱ 33m ⧉ 35/75"),
        // reclaiming a whole row of card height so more printers fit before the panel scrolls.
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [statusLabel, statusSpacer, etaMetric, layerMetric])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 10
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

        let stack = NSStackView(views: [header, statusRow, jobLabel, progressRow, nozzleRow, envRow, filamentDock])
        stack.orientation = .vertical
        stack.alignment = .leading
        // Tighter vertical rhythm so more cards fit before the panel scrolls.
        stack.spacing = 2

        let content = cardContent
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -11),
            // Pin content to the top so cards stretched to match a taller row-mate keep their
            // header aligned with the neighbour's (extra height falls to the bottom, not the middle).
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -7),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            jobLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nozzleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            envRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filamentDock.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        update(printer: printer, telemetry: .init(), message: nil, settings: AppSettings.shared)
        self.onMove = onMove
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        stateEmphasisLayer.frame = contentView?.bounds ?? bounds
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
        // The `model` field is filled only by network discovery (e.g. the Bambu SSDP "BL-P001" code),
        // never by the user, and reads as meaningless noise next to their own printer name — hide it.
        manufacturerLabel.stringValue = ""
        manufacturerLabel.isHidden = true
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
        stateDot.image = NSImage(systemSymbolName: telemetry.state.symbol, accessibilityDescription: telemetry.state.label)
        stateDot.contentTintColor = stateColor(telemetry.state)
        updateCardEmphasis(for: telemetry.state)
        if telemetry.state == .error {
            tintColor = .systemRed.withAlphaComponent(0.065)
        } else if telemetry.state == .finished {
            tintColor = .systemGreen.withAlphaComponent(0.075)
        } else if stale {
            tintColor = .systemOrange.withAlphaComponent(0.045)
        } else {
            tintColor = .clear
        }

        if telemetry.state == .error {
            let errorDescription = HMSResolver.shared.description(for: telemetry.hmsCodes, serial: printer.serial, language: settings.language)
                ?? (telemetry.errorCode != 0
                    ? String(format: settings.text("Kod błędu: 0x%llX", "Error code: 0x%llX"), telemetry.errorCode)
                    : settings.text("Drukarka zgłosiła błąd", "Printer reported an error"))
            jobLabel.stringValue = errorDescription
            jobLabel.toolTip = errorDescription
        } else {
            jobLabel.stringValue = telemetry.jobName?.isEmpty == false
                ? telemetry.jobName!
                : settings.text("BRAK AKTYWNEGO ZADANIA", "NO ACTIVE JOB")
            jobLabel.toolTip = telemetry.jobName
        }
        progress.value = telemetry.progress
        progress.tintColor = stateColor(telemetry.state)
        percentLabel.stringValue = "\(telemetry.progress)%"

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

        // Physical filament modules, laid out as side-by-side groups that wrap in pairs. Parsers that
        // have not adopted the group model yet (Moonraker CFS/MMU) still fill the flat slot list, so
        // synthesize groups from it until they are migrated.
        let groups = telemetry.filamentGroups.isEmpty
            ? Self.legacyGroups(from: telemetry.amsSlots)
            : telemetry.filamentGroups
        if renderedGroups != groups {
            renderedGroups = groups
            filamentDock.isHidden = groups.isEmpty
            filamentDock.setGroups(groups, settings: settings)
        }
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

        switch state {
        case .error:
            stateEmphasisLayer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.075).cgColor
            stateEmphasisLayer.borderColor = NSColor.systemRed.withAlphaComponent(0.55).cgColor
            stateEmphasisLayer.borderWidth = 1
            stateEmphasisLayer.opacity = 1
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.28
            pulse.toValue = 1.0
            pulse.duration = 1.2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stateEmphasisLayer.add(pulse, forKey: "errorPulse")
        case .finished:
            stateEmphasisLayer.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.045).cgColor
            stateEmphasisLayer.borderColor = NSColor.systemGreen.withAlphaComponent(0.28).cgColor
            stateEmphasisLayer.borderWidth = 1
            stateEmphasisLayer.opacity = 1
        default:
            stateEmphasisLayer.backgroundColor = NSColor.clear.cgColor
            stateEmphasisLayer.borderColor = NSColor.clear.cgColor
            stateEmphasisLayer.borderWidth = 0
            stateEmphasisLayer.opacity = 0
        }
    }

    private func stateColor(_ state: PrinterState) -> NSColor {
        switch state {
        case .printing: .systemBlue
        case .idle, .finished: .systemGreen
        case .paused: .systemOrange
        case .error: .systemRed
        case .offline: .secondaryLabelColor
        }
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
        guard let current else { return .secondaryLabelColor }
        let target = target ?? 0
        if target > 5, current < target - 3 { return Self.heatingColor }        // ramping up
        if current > max(target, 0) + 5, current > 30 { return Self.coolingColor } // above setpoint, still warm
        return .secondaryLabelColor                                              // at temperature / idle
    }
}

@MainActor
private final class PrinterDragHandle: NSImageView {
    private let onDrag: (NSEvent) -> Void
    private var didBeginDrag = false

    init(onDrag: @escaping (NSEvent) -> Void) {
        self.onDrag = onDrag
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: "Move printer")
        contentTintColor = .secondaryLabelColor
        toolTip = AppSettings.shared.text("Przeciągnij w górę/dół, aby zmienić kolejność drukarek",
                                          "Drag up/down to reorder printers")
        widthAnchor.constraint(equalToConstant: 17).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    required init?(coder: NSCoder) { nil }

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
        target = self
        action = #selector(showActions)
        toolTip = AppSettings.shared.text("Więcej działań", "More actions")
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
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

    init(symbol: String, tooltip: String) {
        super.init(frame: .zero)
        self.toolTip = tooltip
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        image.contentTintColor = .tertiaryLabelColor
        image.widthAnchor.constraint(equalToConstant: 11).isActive = true
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let stack = NSStackView(views: [image, valueLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
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

@MainActor
private final class BrutalistProgressView: NSView {
    var value = 0 { didSet { needsDisplay = true } }
    var tintColor: NSColor = .systemBlue { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = bounds.insetBy(dx: 0, dy: 3)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        trackPath.fill()

        let fraction = CGFloat(max(0, min(value, 100))) / 100
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        tintColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3.5, yRadius: 3.5).fill()

        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        let outline = NSBezierPath(roundedRect: track.integral, xRadius: 3.5, yRadius: 3.5)
        outline.lineWidth = 1
        outline.stroke()

        let markerX = min(max(track.minX + track.width * fraction, track.minX + 1), track.maxX - 2)
        let marker = NSRect(x: markerX - 1, y: 0, width: 3, height: bounds.height)
        NSColor.controlBackgroundColor.setFill()
        marker.fill()
        let center = NSRect(x: markerX, y: 0, width: 1, height: bounds.height)
        NSColor.labelColor.setFill()
        center.fill()
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
private final class LabeledMetricView: NSView {
    private let labelField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "—")
    var label: String { get { labelField.stringValue } set { labelField.stringValue = newValue } }
    var value: String { get { valueField.stringValue } set { valueField.stringValue = newValue } }
    var valueColor: NSColor { get { valueField.textColor ?? .secondaryLabelColor } set { valueField.textColor = newValue } }

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

/// One filament slot swatch. The active slot gets a thin white ring; empty slots stay grey and keep
/// their position so the group never collapses.
@MainActor
private final class FilamentSlotView: NSView {
    init(slot: FilamentSlot, isExternal: Bool) {
        super.init(frame: .zero)
        let present = slot.isPresent
        let color = present
            ? NSColor(hex: slot.colorHex ?? "8E8E93FF")
            : NSColor.secondaryLabelColor.withAlphaComponent(0.18)
        // Flexible width so the slots stretch to fill their module (distribution .fillEqually).
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 6
        swatch.layer?.backgroundColor = color.cgColor
        if slot.isActive {
            swatch.layer?.borderColor = NSColor.white.cgColor
            swatch.layer?.borderWidth = 2
        } else if present {
            swatch.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
            swatch.layer?.borderWidth = 0.5
        } else {
            swatch.layer?.borderColor = NSColor.separatorColor.cgColor
            swatch.layer?.borderWidth = 0.5
        }
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.heightAnchor.constraint(equalToConstant: 27).isActive = true
        // Keep swatches compact and readable: don't let a slot stretch wider than a tidy chip,
        // so a 4-slot AMS reads as neat squares instead of big blocks. The fill-width constraint
        // below is lowered in priority so this cap wins and the chip stays centered in its cell.
        let maxWidth = swatch.widthAnchor.constraint(lessThanOrEqualToConstant: 50)
        maxWidth.priority = .required
        maxWidth.isActive = true

        // Label sits UNDER the swatch (mockup style), not inside it.
        let title = NSTextField(labelWithString: slot.label)
        title.font = .systemFont(ofSize: 10, weight: .medium)
        title.alignment = .center
        title.textColor = slot.isActive ? .labelColor : .secondaryLabelColor
        title.toolTip = "\(slot.label) • \(slot.material ?? "—") • \(slot.remainingPercent.map { "\($0)%" } ?? "—")"

        let stack = NSStackView(views: [swatch, title])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            swatch.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 1, constant: 0).withPriority(.defaultLow)
        ])

        // External spools report remain=0 as "unknown" (Bambu doesn't gauge them), so a low-filament
        // dot there is a false alarm — only warn for real AMS/CFS slots.
        if present, !isExternal, (slot.remainingPercent ?? 100) <= 15 {
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
    }
    required init?(coder: NSCoder) { nil }
}

/// A physical filament module: a tonal card with a name + per-module humidity/temperature header and
/// its slots, so an AMS, AMS HT, CFS or EXT reads as one distinct unit.
@MainActor
private final class FilamentGroupView: NSView {
    init(group: FilamentGroup, settings: AppSettings) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        // Minimal: a soft fill groups the module without a boxed-in border competing for attention.
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        // Fill the width the dock allots (proportional to slot count), never hug.
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        let name = NSTextField(labelWithString: group.displayName)
        name.font = .systemFont(ofSize: 11, weight: .semibold)
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
        if let humidity = group.humidityPercent {
            let text = humidity <= 5 ? "\(humidity)/5" : "\(humidity)%"
            // Quiet but still legible over a translucent panel; only a genuinely damp module goes orange.
            headerViews.append(Self.metric(symbol: "drop.fill", text: text,
                                            tint: Self.isHumidityHigh(group.humidityPercent) ? .systemOrange : .tertiaryLabelColor))
        }
        if let temp = group.temperatureCelsius {
            headerViews.append(Self.metric(symbol: "thermometer.medium", text: "\(Int(temp.rounded()))°", tint: .tertiaryLabelColor))
        }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let slots = NSStackView(views: group.slots.map { FilamentSlotView(slot: $0, isExternal: group.isExternal) })
        slots.orientation = .horizontal
        slots.alignment = .top
        slots.distribution = .fillEqually   // slots stretch to fill the module width
        slots.spacing = 8

        let stack = NSStackView(views: [header, slots])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            slots.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

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
private final class FilamentDockView: NSView {
    private let column = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
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

    func setGroups(_ groups: [FilamentGroup], settings: AppSettings) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var index = 0
        while index < groups.count {
            let rowGroups = Array(groups[index ..< min(index + 2, groups.count)])
            index += 2
            let views = rowGroups.map { FilamentGroupView(group: $0, settings: settings) }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fill
            row.spacing = 8
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            // An external module holds a single spool; never let it get crushed below the width its
            // "EXT" header + swatch need, even in a narrow two-column card.
            for (view, group) in zip(views, rowGroups) where group.isExternal {
                view.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
            }
            // Second module's width is proportional to its slot count vs the first (AMS wide, EXT
            // narrow) — but only as a preference, so the external minimum above always wins.
            // An external module counts for less than a real AMS slot, so even AMS HT (1 slot) beside
            // EXT (1 slot) stays the wider, primary module instead of splitting the row in half.
            if views.count == 2 {
                func weight(_ g: FilamentGroup) -> CGFloat {
                    CGFloat(max(1, g.declaredCapacity)) * (g.isExternal ? 0.5 : 1)
                }
                let proportional = views[1].widthAnchor.constraint(equalTo: views[0].widthAnchor, multiplier: weight(rowGroups[1]) / weight(rowGroups[0]))
                proportional.priority = .defaultHigh
                proportional.isActive = true
            } else if let only = views.first, rowGroups[0].isExternal {
                // A lone external (printer with no AMS, e.g. A1 mini) shouldn't balloon across the
                // whole card — keep it a compact tile on the left and let a spacer take the slack.
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                row.addArrangedSubview(spacer)
                let compact = only.widthAnchor.constraint(equalToConstant: 132)
                compact.priority = .defaultHigh
                compact.isActive = true
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

