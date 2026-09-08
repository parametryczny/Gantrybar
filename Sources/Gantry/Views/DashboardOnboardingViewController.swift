import AppKit
import Combine

/// Both dashboard presentations use this same guide and the real PrinterCardView with live data.
/// Preview hit testing is blocked; no command, assignment, or printer setting can be changed here.
@MainActor
final class DashboardOnboardingViewController: NSViewController {
    private let store: PrinterStore
    private let previewProvider: () -> [(SavedPrinter, PrinterTelemetry)]
    private let onClose: () -> Void
    private var subscription: AnyCancellable?
    private var refreshPending = false
    private var step = 0
    private var preview: PrinterCardView?
    private var selectedSerial: String?
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let source = NSPopUpButton(frame: .zero, pullsDown: false)
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let back = NSButton()
    private let next = NSButton()
    private let close = NSButton()
    private let scroll = NSScrollView()
    private let document = GuidePreviewDocument()
    private let focus = NSView()

    init(store: PrinterStore, previewProvider: (() -> [(SavedPrinter, PrinterTelemetry)])? = nil,
         onClose: @escaping () -> Void) {
        self.store = store
        self.previewProvider = previewProvider ?? {
            store.dashboardPrinters.compactMap { printer in
                guard let data = store.telemetry[printer.serial], data.state != .offline else { return nil }
                return (printer, data)
            }
        }
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        subscription = store.objectWillChange.sink { [weak self] _ in
            guard let self, !self.refreshPending else { return }
            self.refreshPending = true
            DispatchQueue.main.async { [weak self] in
                self?.refreshPending = false
                self?.refresh()
            }
        }
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 590))
        view.wantsLayer = true
        view.layer?.backgroundColor = GantryTheme.card.cgColor
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = GantryTheme.text
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = GantryTheme.secondary
        for label in [empty, note, count] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = GantryTheme.secondary
        }
        empty.alignment = .center
        note.alignment = .center
        source.controlSize = .small
        source.target = self
        source.action = #selector(selectPrinter)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: AppSettings.shared.t("Close"))
        close.isBordered = false
        close.target = self
        close.action = #selector(closeGuide)
        for button in [back, next] { button.bezelStyle = .rounded; button.target = self }
        back.action = #selector(previousStep)
        next.action = #selector(nextStep)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        document.addSubview(empty)
        document.addSubview(note)
        focus.wantsLayer = true
        focus.layer?.cornerRadius = 6
        focus.layer?.borderColor = GantryTheme.accent.withAlphaComponent(0.8).cgColor
        focus.layer?.borderWidth = 1
        document.addSubview(focus)
        for child in [titleLabel, descriptionLabel, source, scroll, count, back, next, close] { view.addSubview(child) }
        refresh()
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let s = AppSettings.shared
        view.appearance = s.appearance
        let titles = [s.t("Print progress"), s.t("Temperatures"), s.t("Filament / AMS"), s.t("Warnings and maintenance")]
        let descriptions = [
            s.t("The segmented bar and percentage show print progress. The clock shows remaining time and estimated finish; the layer icon shows current and total layers."),
            s.t("These are the same temperature fields as on your printer card. Values, targets and heating or cooling indicators come from the printer."),
            s.t("These are your actual AMS/EXT modules, slots and assigned rolls. Slot layout, material, colour and remaining amount follow the dashboard settings. This preview does not change assignments."),
            s.t("🔧 marks maintenance; ! marks an alert reported by the printer. They appear only when relevant. Open their details on the dashboard; offline means data is no longer arriving.")
        ]
        titleLabel.stringValue = titles[step]
        descriptionLabel.stringValue = descriptions[step]
        count.stringValue = "\(step + 1) / 4"
        back.title = s.t("Previous step")
        next.title = s.t(step == 3 ? "Done" : "Next")
        back.isEnabled = step > 0
        close.toolTip = s.t("Close")
        let snapshots = previewProvider()
        let available = snapshots.map { $0.0 }
        if !available.contains(where: { $0.serial == selectedSerial }) {
            selectedSerial = snapshots.first(where: { !$0.1.filamentGroups.isEmpty })?.0.serial
                ?? available.first?.serial
        }
        source.removeAllItems()
        for printer in available {
            source.addItem(withTitle: s.t("Live data · {0}", printer.name))
            source.lastItem?.representedObject = printer.serial
        }
        source.selectItem(at: available.firstIndex(where: { $0.serial == selectedSerial }) ?? -1)
        source.isHidden = available.isEmpty
        if let (printer, telemetry) = snapshots.first(where: { $0.0.serial == selectedSerial }) {
            if preview?.serial != printer.serial {
                preview?.removeFromSuperview()
                let card = PrinterCardView(printer: printer, onEdit: {}, onReconnect: {}, onOpenCamera: {},
                    onShowDetails: {}, onShowMaintenance: {}, onOpenSlicer: { _ in }, onCopyIP: {},
                    onRemove: {}, onMove: { _, _, _ in })
                card.isGuidePreview = true
                card.unregisterDraggedTypes()
                card.translatesAutoresizingMaskIntoConstraints = false
                document.addSubview(card, positioned: .below, relativeTo: focus)
                NSLayoutConstraint.activate([
                    card.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 6),
                    card.topAnchor.constraint(equalTo: document.topAnchor, constant: 6)
                ])
                preview = card
            }
            preview?.update(printer: printer, telemetry: telemetry, message: nil, settings: s)
            empty.isHidden = true
            note.stringValue = s.t("Read-only view · same widgets and settings as your dashboard")
        } else {
            preview?.removeFromSuperview()
            preview = nil
            empty.isHidden = false
            empty.stringValue = s.t("Waiting for printer data. Your actual card will appear here after connecting.")
            note.stringValue = ""
        }
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width, h = view.bounds.height
        titleLabel.frame = NSRect(x: 20, y: h - 49, width: max(1, w - 70), height: 28)
        close.frame = NSRect(x: w - 43, y: h - 45, width: 24, height: 24)
        descriptionLabel.frame = NSRect(x: 20, y: h - 133, width: w - 40, height: 76)
        source.frame = NSRect(x: 20, y: h - 168, width: w - 40, height: 26)
        scroll.frame = NSRect(x: 14, y: 58, width: w - 28, height: max(1, h - 240))
        scroll.tile()
        let docWidth = scroll.contentSize.width
        var cardHeight: CGFloat = 0
        if let preview {
            preview.setLayoutWidth(max(1, docWidth - 12))
            cardHeight = preview.fittingSize.height
        }
        document.setFrameSize(NSSize(width: docWidth, height: max(scroll.contentSize.height, cardHeight + 74)))
        document.layoutSubtreeIfNeeded()
        note.frame = NSRect(x: 8, y: cardHeight + 23, width: docWidth - 16, height: 42)
        empty.frame = NSRect(x: 24, y: 36, width: docWidth - 48, height: 70)
        if let preview, let rect = preview.onboardingFocusRect(step: step), !rect.isEmpty {
            focus.isHidden = false
            focus.frame = document.convert(rect, from: preview).insetBy(dx: -3, dy: -3)
        } else { focus.isHidden = true }
        count.frame = NSRect(x: 20, y: 22, width: 60, height: 20)
        back.frame = NSRect(x: w - 200, y: 17, width: 80, height: 30)
        next.frame = NSRect(x: w - 110, y: 17, width: 90, height: 30)
    }

    @objc private func selectPrinter() {
        selectedSerial = source.selectedItem?.representedObject as? String
        refresh()
    }
    @objc private func previousStep() { step = max(0, step - 1); refresh() }
    @objc private func nextStep() { if step == 3 { onClose() } else { step += 1; refresh() } }
    @objc private func closeGuide() { onClose() }
}

private final class GuidePreviewDocument: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
}
