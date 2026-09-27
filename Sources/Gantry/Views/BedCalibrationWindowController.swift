import AppKit

/// Clicking the bed's four corners on a still from the camera, once per printer.
///
/// The corners are clicked in a fixed order (back left, back right, front right, front left, as seen
/// from the front of the printer), each can be dragged afterwards, and as soon as all four are in the
/// picture shows a 50 mm grid and the running job's objects drawn where Gantry now believes they are.
/// If the grid lies on the bed and the outlines sit on the parts, the calibration is right.
///
/// A printer whose bed drops during a print gets an optional second set: lower the bed by a known
/// distance, take a new picture and click the same corners again.
@MainActor
final class BedCalibrationWindowController: NSViewController {
    private let store: PrinterStore
    private let printer: SavedPrinter
    private var panel: PanelWindowController?
    private let canvas = CalibrationCanvas()
    private let widthField = NSTextField()
    private let depthField = NSTextField()
    private let loweredField = NSTextField()
    private let movingBed = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let level = NSSegmentedControl()
    private let prompt = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var loading = false

    static func show(store: PrinterStore, printer: SavedPrinter) {
        let editor = BedCalibrationWindowController(store: store, printer: printer)
        _ = editor.view
        editor.panel = PanelWindowController.present(
            editor.view, name: AppSettings.shared.t("Bed calibration") + " · " + printer.name,
            size: NSSize(width: 860, height: 720), onDismiss: { _ = editor; editor.panel = nil })
        editor.refresh()
    }

    init(store: PrinterStore, printer: SavedPrinter) {
        self.store = store
        self.printer = printer
        super.init(nibName: nil, bundle: nil)
        canvas.calibration = BedCalibration.load(serial: printer.serial) ?? BedCalibration.defaults(for: printer)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let s = AppSettings.shared
        view = NSView()
        let instructions = NSTextField(wrappingLabelWithString: s.t("Click the four corners of the print surface in the order shown, as seen from the front of the printer. Drag a point to correct it. When all four are in, a 50 mm grid and the current objects are drawn on the picture: they should lie on the bed and on the parts."))
        prompt.font = .systemFont(ofSize: 13, weight: .semibold)
        prompt.textColor = .systemYellow

        for (field, value) in [(widthField, canvas.calibration.bedWidth), (depthField, canvas.calibration.bedDepth),
                               (loweredField, canvas.calibration.lowered)] {
            field.stringValue = String(format: "%.0f", value)
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
            field.target = self
            field.action = #selector(fieldsChanged)
        }
        movingBed.title = s.t("The bed slides front to back under the camera (A1, Prusa MK, Ender)")
        movingBed.state = canvas.calibration.movingBed ? .on : .off
        movingBed.target = self
        movingBed.action = #selector(fieldsChanged)
        let size = NSStackView(views: [NSTextField(labelWithString: s.t("Bed width")), widthField, NSTextField(labelWithString: "mm"),
                                       NSTextField(labelWithString: s.t("Bed depth")), depthField, NSTextField(labelWithString: "mm")])
        size.spacing = 6

        level.segmentCount = 2
        level.setLabel(s.t("Bed at the top"), forSegment: 0)
        level.setLabel(s.t("Bed lowered (optional)"), forSegment: 1)
        level.selectedSegment = 0
        level.target = self
        level.action = #selector(levelChanged)
        let lowered = NSStackView(views: [level, NSTextField(labelWithString: s.t("lowered by")), loweredField, NSTextField(labelWithString: "mm")])
        lowered.spacing = 6

        let tools = NSStackView(views: [button(s.t("Undo point"), #selector(undoPoint)), button(s.t("Clear"), #selector(clearPoints)),
                                        button(s.t("Refresh picture"), #selector(refresh)), NSView(),
                                        button(s.t("Remove calibration"), #selector(removeCalibration)),
                                        button(s.t("Save"), #selector(save))])
        tools.spacing = 8
        let stack = NSStackView(views: [instructions, prompt, canvas, size, movingBed, lowered, message, tools])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16),
            canvas.widthAnchor.constraint(equalTo: stack.widthAnchor),
            canvas.heightAnchor.constraint(equalToConstant: 400),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tools.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        canvas.onChange = { [weak self] in self?.updatePrompt() }
        updatePrompt()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func updatePrompt() {
        let s = AppSettings.shared
        let names = [s.t("back left"), s.t("back right"), s.t("front right"), s.t("front left")]
        let points = canvas.editingLow ? canvas.calibration.low : canvas.calibration.top
        if points.count < 4 {
            prompt.stringValue = s.t("Click corner {0} of 4: {1}", points.count + 1, names[points.count])
        } else if canvas.editingLow {
            prompt.stringValue = s.t("Lowered bed clicked. Save when the grid lies on the bed.")
        } else {
            prompt.stringValue = s.t("All four corners are in. Check the grid and the outlines, then save.")
        }
    }

    @objc private func fieldsChanged() {
        canvas.calibration.bedWidth = max(50, Double(widthField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? canvas.calibration.bedWidth)
        canvas.calibration.bedDepth = max(50, Double(depthField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? canvas.calibration.bedDepth)
        canvas.calibration.lowered = max(1, Double(loweredField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? canvas.calibration.lowered)
        canvas.calibration.movingBed = movingBed.state == .on
        canvas.needsDisplay = true
    }

    @objc private func levelChanged() {
        canvas.editingLow = level.selectedSegment == 1
        if canvas.editingLow {
            message.stringValue = AppSettings.shared.t("Lower the bed by the distance entered (for example with Z in the control panel), refresh the picture and click the same four corners again.")
        }
        updatePrompt()
    }

    @objc private func undoPoint() {
        if canvas.editingLow { if !canvas.calibration.low.isEmpty { canvas.calibration.low.removeLast() } }
        else if !canvas.calibration.top.isEmpty { canvas.calibration.top.removeLast() }
        canvas.needsDisplay = true
        updatePrompt()
    }

    @objc private func clearPoints() {
        if canvas.editingLow { canvas.calibration.low = [] } else { canvas.calibration.top = []; canvas.calibration.low = [] }
        canvas.needsDisplay = true
        updatePrompt()
    }

    @objc private func refresh() {
        guard !loading else { return }
        loading = true
        let s = AppSettings.shared
        message.stringValue = s.t("Taking a picture…")
        let store = self.store
        let printer = self.printer
        Task { @MainActor [weak self] in
            let frame = await CameraSnapshot.latestFrame(printer: printer, store: store)
            guard let self else { return }
            self.loading = false
            guard let frame, let image = NSImage(data: frame.jpeg) else {
                self.message.stringValue = s.t("No picture. Check the camera and try again.")
                return
            }
            self.canvas.image = image
            self.canvas.needsDisplay = true
            self.message.stringValue = s.t("Picture held for clicking. The live view is not affected.")
            await self.loadOutlines()
        }
    }

    /// The running job's objects, to draw over the picture as a check.
    private func loadOutlines() async {
        let telemetry = store.telemetry[printer.serial] ?? PrinterTelemetry()
        guard telemetry.state == .printing || telemetry.state == .paused else { return }
        if printer.kind == .klipper {
            canvas.outlines = telemetry.printObjects.map { $0.polygon.map { BedCalibration.Point(x: $0.x, y: $0.y) } }
        } else if case .loaded(let layout) = await store.loadPrintObjectLayout(serial: printer.serial) {
            canvas.outlines = FootprintAnalysis.outlines(from: layout, calibration: canvas.calibration)
        }
        canvas.needsDisplay = true
    }

    @objc private func removeCalibration() {
        BedCalibration.remove(serial: printer.serial)
        canvas.calibration = BedCalibration.defaults(for: printer)
        canvas.needsDisplay = true
        updatePrompt()
        message.stringValue = AppSettings.shared.t("Calibration removed. Failure detection looks at the whole picture again.")
    }

    @objc private func save() {
        let s = AppSettings.shared
        fieldsChanged()
        guard canvas.calibration.top.count == 4 else {
            message.stringValue = s.t("Click all four corners before saving.")
            return
        }
        if !canvas.calibration.low.isEmpty && canvas.calibration.low.count != 4 {
            message.stringValue = s.t("Click all four corners of the lowered bed, or clear them.")
            return
        }
        if let image = canvas.image, image.size.height > 0 { canvas.calibration.aspect = image.size.width / image.size.height }
        do {
            try canvas.calibration.save(serial: printer.serial)
            message.stringValue = canvas.calibration.movingBed
                ? s.t("Saved. A sliding bed moves under the camera, so detection does not use this calibration.")
                : s.t("Saved. Failure detection now knows where the bed and the objects are.")
        } catch {
            message.stringValue = error.localizedDescription
        }
    }
}

@MainActor
private final class CalibrationCanvas: NSView {
    var image: NSImage?
    var calibration = BedCalibration()
    var outlines: [[BedCalibration.Point]] = []
    var editingLow = false
    var onChange: (() -> Void)?
    private var dragging: Int?

    private var imageRect: NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private var points: [BedCalibration.Point] {
        get { editingLow ? calibration.low : calibration.top }
        set { if editingLow { calibration.low = newValue } else { calibration.top = newValue } }
    }

    private func relative(_ p: NSPoint) -> BedCalibration.Point {
        let rect = imageRect
        return BedCalibration.Point(x: min(1, max(0, (p.x - rect.minX) / rect.width)), y: min(1, max(0, (p.y - rect.minY) / rect.height)))
    }

    private func onScreen(_ p: BedCalibration.Point) -> NSPoint {
        let rect = imageRect
        return NSPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard image != nil, imageRect.contains(location) else { return }
        if let index = points.indices.first(where: { hypot(onScreen(points[$0]).x - location.x, onScreen(points[$0]).y - location.y) < 10 }) {
            dragging = index
            return
        }
        guard points.count < 4 else { return }
        points.append(relative(location))
        needsDisplay = true
        onChange?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        points[dragging] = relative(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        onChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        image?.draw(in: imageRect)
        guard image != nil else { return }

        func polyline(_ list: [BedCalibration.Point], close: Bool, color: NSColor, width: CGFloat = 2) {
            guard list.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: onScreen(list[0]))
            for p in list.dropFirst() { path.line(to: onScreen(p)) }
            if close { path.close() }
            path.lineWidth = width
            color.setStroke()
            path.stroke()
        }

        if let homography = calibration.homography(droppedBy: 0), calibration.top.count == 4 {
            // A 50 mm grid over the bed as Gantry now sees it.
            var x = 0.0
            while x <= calibration.bedWidth + 0.1 {
                let line = [BedCalibration.Point(x: x, y: 0), BedCalibration.Point(x: x, y: calibration.bedDepth)].compactMap { homography.apply($0) }
                polyline(line, close: false, color: NSColor.systemGreen.withAlphaComponent(0.5), width: 1)
                x += 50
            }
            var y = 0.0
            while y <= calibration.bedDepth + 0.1 {
                let line = [BedCalibration.Point(x: 0, y: y), BedCalibration.Point(x: calibration.bedWidth, y: y)].compactMap { homography.apply($0) }
                polyline(line, close: false, color: NSColor.systemGreen.withAlphaComponent(0.5), width: 1)
                y += 50
            }
            for outline in outlines {
                polyline(outline.compactMap { homography.apply($0) }, close: true, color: .systemBlue, width: 2)
            }
        }
        polyline(calibration.top, close: calibration.top.count == 4, color: .systemGreen)
        polyline(calibration.low, close: calibration.low.count == 4, color: .systemOrange)

        let labels = ["1", "2", "3", "4"]
        for (list, color) in [(calibration.top, NSColor.systemGreen), (calibration.low, NSColor.systemOrange)] {
            for (index, p) in list.enumerated() {
                let centre = onScreen(p)
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)).fill()
                NSAttributedString(string: labels[index], attributes: [
                    .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .bold)
                ]).draw(at: NSPoint(x: centre.x + 7, y: centre.y + 3))
            }
        }
    }
}
