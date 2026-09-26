import AppKit

@MainActor
final class DefectMaskEditor: NSViewController {
    private let serial: String
    private let fetch: () async -> Data?
    private var jpeg: Data?
    private var panel: PanelWindowController?
    private let canvas = MaskCanvas()
    private let enabled = NSButton(checkboxWithTitle: "Używaj zaznaczenia", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var loading = false

    static func show(serial: String, name: String, fetch: @escaping () async -> Data?) {
        let editor = DefectMaskEditor(serial: serial, fetch: fetch)
        _ = editor.view
        editor.panel = PanelWindowController.present(editor.view, name: "Obszar wykrywania · " + name,
            size: NSSize(width: 780, height: 650), onDismiss: { _ = editor; editor.panel = nil })
        editor.refresh()
    }
    init(serial: String, fetch: @escaping () async -> Data?) {
        self.serial = serial; self.fetch = fetch
        super.init(nibName: nil, bundle: nil)
        canvas.mask = DefectMask.load(serial: serial)
        enabled.state = canvas.mask.enabled ? .on : .off
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView()
        let instructions = NSTextField(wrappingLabelWithString: "Klikaj punkty na zdjęciu, potem wybierz „Zakończ obrys”. Obejmij cały wydruk i jego otoczenie, również zakres ruchu stołu. Po przestawieniu kamery popraw zaznaczenie.")
        let tools = NSStackView(views: [button("Obszar druku", #selector(region)), button("Pomiń fragment", #selector(exclude)), button("Zakończ obrys", #selector(finish)), button("Cofnij", #selector(undoPoint))])
        let options = NSStackView(views: [button("Cały obraz", #selector(clear)), button("Odśwież zdjęcie", #selector(refresh)), enabled])
        let footer = NSStackView(views: [button("Porównaj cały obraz / maskę", #selector(compare)), button("Zapisz dla tej drukarki", #selector(save))])
        let stack = NSStackView(views: [instructions, tools, canvas, options, message, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16), canvas.widthAnchor.constraint(equalTo: stack.widthAnchor), canvas.heightAnchor.constraint(equalToConstant: 330), instructions.widthAnchor.constraint(equalTo: stack.widthAnchor), message.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        message.stringValue = "Zaznaczenie jest opcjonalne. Porównanie ocenia jedną klatkę i nie wysyła alarmów."
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    @objc private func region() { canvas.pending = []; canvas.excluding = false; message.stringValue = "Klikaj narożniki obszaru druku. Poprzedni obszar zostanie zastąpiony po zakończeniu." }
    @objc private func exclude() { canvas.pending = []; canvas.excluding = true; message.stringValue = "Obrysuj fragment, który ma być pomijany." }
    @objc private func finish() {
        guard DefectMask.valid(canvas.pending) else { message.stringValue = "Dodaj co najmniej trzy punkty tworzące obszar."; return }
        if canvas.excluding { canvas.mask.excluded.append(canvas.pending) } else { canvas.mask.region = canvas.pending }
        canvas.pending = []; canvas.needsDisplay = true
        message.stringValue = "Obrys gotowy. Porównaj wynik przed włączeniem zaznaczenia."
    }
    @objc private func undoPoint() {
        if !canvas.pending.isEmpty { canvas.pending.removeLast() }
        else if !canvas.mask.excluded.isEmpty { canvas.mask.excluded.removeLast() }
        else { canvas.mask.region = [] }
        canvas.needsDisplay = true
    }
    @objc private func clear() { canvas.mask.region = []; canvas.mask.excluded = []; canvas.pending = []; canvas.needsDisplay = true }
    @objc private func refresh() {
        guard !loading else { return }; loading = true
        message.stringValue = "Pobieram zdjęcie…"
        Task { @MainActor in
            defer { loading = false }
            guard let data = await fetch(), let image = NSImage(data: data) else { message.stringValue = "Brak obrazu. Sprawdź kamerę i ponów pobranie."; return }
            jpeg = data; canvas.image = image; canvas.needsDisplay = true
            message.stringValue = "Zdjęcie zatrzymane do zaznaczania. Podgląd na żywo pozostaje bez zmian."
        }
    }
    private func draft() throws -> DefectMask {
        guard canvas.pending.isEmpty else { throw DefectMask.Failure.invalid }
        guard let image = canvas.image else { throw DefectMask.Failure.image }
        var value = canvas.mask; value.enabled = enabled.state == .on
        value.aspect = image.size.width / image.size.height
        return value
    }
    @objc private func save() {
        do {
            guard let jpeg else { throw DefectMask.Failure.image }
            let value = try draft(); _ = try value.applying(to: jpeg)
            try value.save(serial: serial); canvas.mask = value
            message.stringValue = value.isActive ? "Zapisano. Analiza tej drukarki używa zaznaczenia. Porównywanie z pełnymi klatkami wzorcowymi jest wtedy pomijane." : "Zapisano. Analizowany będzie cały obraz."
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func compare() {
        do {
            guard let jpeg else { throw DefectMask.Failure.image }
            var value = try draft(); value.enabled = true
            let processed = try value.applying(to: jpeg)
            let full = try DefectTrial.judge(jpeg: jpeg)
            let masked = try DefectTrial.judge(jpeg: processed, useReferences: !value.isActive)
            let alert = NSAlert(); alert.messageText = "Porównanie tej samej klatki"
            alert.informativeText = "Cały obraz: \(DefectTrial.headline(full))\nZ maską: \(DefectTrial.headline(masked))\n\nTo wynik modelu dla jednej klatki, nie potwierdzenie skuteczności maski. Przy masce nie porównujemy z niezamaskowanymi wzorcami."
            let images = NSStackView()
            for (title, data) in [("Cały obraz", jpeg), ("Z maską", processed)] {
                let image = NSImageView(frame: NSRect(x: 0, y: 0, width: 270, height: 190)); image.image = NSImage(data: data); image.imageScaling = .scaleProportionallyUpOrDown
                image.widthAnchor.constraint(equalToConstant: 270).isActive = true; image.heightAnchor.constraint(equalToConstant: 190).isActive = true
                let column = NSStackView(views: [NSTextField(labelWithString: title), image]); column.orientation = .vertical; images.addArrangedSubview(column)
            }
            alert.accessoryView = images; alert.addButton(withTitle: "Zamknij"); ModalHost.run(alert)
        } catch { message.stringValue = error.localizedDescription }
    }
}

@MainActor
private final class MaskCanvas: NSView {
    var image: NSImage?
    var mask = DefectMask()
    var pending: [DefectMask.Point] = [] { didSet { needsDisplay = true } }
    var excluding = false
    private var imageRect: NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil), rect = imageRect
        guard image != nil, rect.contains(p) else { return }
        pending.append(.init(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        let rect = imageRect
        image?.draw(in: rect)
        guard let ctx = NSGraphicsContext.current?.cgContext, image != nil else { return }
        ctx.saveGState()
        if !mask.region.isEmpty {
            let shade = CGMutablePath(); shade.addRect(rect); shade.addPath(DefectMask.path(mask.region, in: rect))
            ctx.addPath(shade); ctx.setFillColor(NSColor.black.withAlphaComponent(0.65).cgColor); ctx.fillPath(using: .evenOdd)
        }
        for polygon in mask.excluded { ctx.addPath(DefectMask.path(polygon, in: rect)); ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor); ctx.fillPath() }
        for polygon in [mask.region] + mask.excluded {
            guard !polygon.isEmpty else { continue }; ctx.addPath(DefectMask.path(polygon, in: rect)); ctx.setStrokeColor(NSColor.systemGreen.cgColor); ctx.setLineWidth(2); ctx.strokePath()
        }
        if !pending.isEmpty {
            ctx.addPath(DefectMask.path(pending, in: rect)); ctx.setStrokeColor(NSColor.systemYellow.cgColor); ctx.setLineWidth(2); ctx.strokePath()
            for p in pending { ctx.setFillColor(NSColor.systemYellow.cgColor); ctx.fillEllipse(in: CGRect(x: rect.minX + p.x * rect.width - 3, y: rect.minY + p.y * rect.height - 3, width: 6, height: 6)) }
        }
        ctx.restoreGState()
    }
}
