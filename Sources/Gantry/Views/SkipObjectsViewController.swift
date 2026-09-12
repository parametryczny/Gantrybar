import AppKit

@MainActor
final class SkipObjectsViewController: NSViewController {
    private let store: PrinterStore
    private let serial: String
    private let onBack: () -> Void
    private let bed = PrintBedView()
    private let list = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let action = NSButton()
    private let spinner = NSProgressIndicator()
    private var layout: PrintObjectLayout?
    private var selected = Set<String>()
    private var confirming = false
    private var loadingFinished = false

    init(store: PrinterStore, serial: String, onBack: @escaping () -> Void) {
        self.store = store; self.serial = serial; self.onBack = onBack
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 650))
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: 480).isActive = true
        root.heightAnchor.constraint(equalToConstant: 650).isActive = true

        let back = NSButton(title: AppSettings.shared.t(" Back"), target: self, action: #selector(backPressed))
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        back.imagePosition = .imageLeading; back.bezelStyle = .accessoryBar
        let title = NSTextField(labelWithString: AppSettings.shared.t("Skip object"))
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let header = NSStackView(views: [back, title, NSView()])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 10

        let hint = NSTextField(wrappingLabelWithString: AppSettings.shared.t(
            "Select the failed object on the bed. Gantry will leave the remaining objects printing."))
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor

        bed.wantsLayer = true; bed.layer?.cornerRadius = 12; bed.layer?.masksToBounds = true
        bed.heightAnchor.constraint(equalToConstant: 330).isActive = true
        bed.onToggle = { [weak self] id in self?.toggle(id) }

        list.orientation = .vertical; list.alignment = .leading; list.spacing = 4
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.documentView = list
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.stringValue = AppSettings.shared.t("Loading objects…")
        let statusRow = NSStackView(views: [spinner, status, NSView()])
        statusRow.orientation = .horizontal; statusRow.alignment = .centerY; statusRow.spacing = 7

        action.title = AppSettings.shared.t("Select an object")
        action.bezelStyle = .rounded; action.isEnabled = false
        action.target = self; action.action = #selector(skipPressed)
        action.setContentHuggingPriority(.required, for: .horizontal)
        let bottom = NSStackView(views: [statusRow, NSView(), action])
        bottom.orientation = .horizontal; bottom.alignment = .centerY

        let stack = NSStackView(views: [header, hint, bed, scroll, bottom])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bed.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // UI-level failsafe: even if a future transport bug fails to resume its continuation, the
        // modal must never leave the user staring at an endless spinner.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(65))
            guard let self, !loadingFinished else { return }
            finishLoading(.unavailable(AppSettings.shared.t("The printer did not respond in time.")))
        }
        Task { [weak self] in
            guard let self else { return }
            let loaded = await store.loadPrintObjectLayout(serial: serial)
            guard !Task.isCancelled, !loadingFinished else { return }
            finishLoading(loaded)
        }
    }

    private func finishLoading(_ result: PrintObjectLoadResult) {
        loadingFinished = true
        spinner.stopAnimation(nil); spinner.isHidden = true
        switch result {
        case .loaded(let loaded) where loaded.objects.count > 1:
            layout = loaded
            bed.layout = loaded; bed.selected = selected
            status.isHidden = false
            status.stringValue = AppSettings.shared.t("Choose one or more objects")
            rebuildList()
        case .loaded:
            layout = nil
            status.stringValue = ""; status.isHidden = true
            bed.emptyMessage = AppSettings.shared.t("This print does not expose multiple objects.")
            bed.needsDisplay = true
        case .unavailable(let reason):
            layout = nil
            status.stringValue = ""; status.isHidden = true
            bed.emptyMessage = reason
            bed.needsDisplay = true
        }
        updateAction()
    }

    private func rebuildList() {
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        guard let layout else { return }
        for object in layout.objects {
            let skipped = layout.skippedObjectIDs.contains(object.id)
            let current = layout.currentObjectID == object.id
            let button = NSButton(checkboxWithTitle: object.name + (current ? "  ·  " + AppSettings.shared.t("printing now") : ""),
                                  target: self, action: #selector(objectChecked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(object.id)
            button.state = selected.contains(object.id) ? .on : .off
            button.isEnabled = !skipped
            if skipped { button.title += "  ·  " + AppSettings.shared.t("skipped") }
            list.addArrangedSubview(button)
        }
    }

    private func toggle(_ id: String) {
        guard let layout, !layout.skippedObjectIDs.contains(id) else { return }
        if !selected.insert(id).inserted { selected.remove(id) }
        confirming = false; bed.selected = selected; rebuildList(); updateAction()
    }
    @objc private func objectChecked(_ sender: NSButton) { if let id = sender.identifier?.rawValue { toggle(id) } }

    private func updateAction() {
        action.isEnabled = !selected.isEmpty
        if selected.isEmpty { action.title = AppSettings.shared.t("Select an object") }
        else if confirming { action.title = AppSettings.shared.t("Confirm skipping ({0})", selected.count) }
        else { action.title = AppSettings.shared.t("Skip selected ({0})", selected.count) }
    }

    @objc private func skipPressed() {
        guard !selected.isEmpty else { return }
        if !confirming {
            confirming = true
            status.stringValue = AppSettings.shared.t("This cannot be undone during the current print.")
            updateAction(); return
        }
        store.skipPrintObjects(serial: serial, ids: selected)
        onBack()
    }
    @objc private func backPressed() { onBack() }
}

private final class PrintBedView: NSView {
    var layout: PrintObjectLayout? { didSet { needsDisplay = true } }
    var selected = Set<String>() { didSet { needsDisplay = true } }
    var emptyMessage = ""
    var onToggle: ((String) -> Void)?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.07, alpha: 0.92).setFill(); bounds.fill()
        guard let layout else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            let size = emptyMessage.size(withAttributes: attrs)
            emptyMessage.draw(at: NSPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attrs)
            return
        }
        if let data = layout.previewPNG, let image = NSImage(data: data) {
            image.draw(in: bounds.insetBy(dx: 8, dy: 8), from: .zero, operation: .sourceOver, fraction: 0.72)
        } else {
            NSColor.white.withAlphaComponent(0.045).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 12), xRadius: 10, yRadius: 10).fill()
        }
        for object in layout.objects where object.polygon.count >= 3 {
            let path = pathFor(object, layout: layout)
            let skipped = layout.skippedObjectIDs.contains(object.id)
            let active = layout.currentObjectID == object.id
            let chosen = selected.contains(object.id)
            (skipped ? NSColor.gray : chosen ? NSColor.systemRed : active ? NSColor.systemGreen : NSColor.systemOrange)
                .withAlphaComponent(chosen ? 0.32 : 0.16).setFill(); path.fill()
            (skipped ? NSColor.gray : chosen ? NSColor.systemRed : active ? NSColor.systemGreen : NSColor.systemOrange).setStroke()
            path.lineWidth = chosen ? 3 : 1.5; path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let layout else { return }
        let point = convert(event.locationInWindow, from: nil)
        for object in layout.objects.reversed() where object.polygon.count >= 3 {
            if pathFor(object, layout: layout).contains(point) { onToggle?(object.id); return }
        }
    }

    private func pathFor(_ object: PrintObject, layout: PrintObjectLayout) -> NSBezierPath {
        let b = layout.bedBounds.count >= 4 ? layout.bedBounds : [0, 0, 256, 256]
        let dx = max(0.001, b[2]-b[0]), dy = max(0.001, b[3]-b[1])
        let area = bounds.insetBy(dx: 14, dy: 14)
        let path = NSBezierPath()
        for (i, p) in object.polygon.enumerated() {
            let point = NSPoint(x: area.minX + CGFloat((p.x-b[0])/dx) * area.width,
                                y: area.maxY - CGFloat((p.y-b[1])/dy) * area.height)
            i == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.close(); return path
    }
}
