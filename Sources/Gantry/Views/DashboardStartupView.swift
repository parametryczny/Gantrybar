import AppKit

/// Lightweight launch scrim, independent of dashboard layout and connection retries.
@MainActor
final class DashboardStartupView: NSView {
    private let card = NSView()
    private let spinner = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let skip = NSButton()
    private let guide = NSButton()
    private let onSkip: () -> Void
    private let onGuide: () -> Void

    init(frame: NSRect, onGuide: @escaping () -> Void = {}, onSkip: @escaping () -> Void) {
        self.onSkip = onSkip
        self.onGuide = onGuide
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        card.wantsLayer = true
        card.layer?.backgroundColor = GantryTheme.card.cgColor
        card.layer?.cornerRadius = GantryTheme.cardRadius
        card.layer?.borderWidth = 1
        card.layer?.borderColor = GantryTheme.line.cgColor
        addSubview(card)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = true
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = GantryTheme.text
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        count.textColor = GantryTheme.accent
        for label in [title, count] { label.alignment = .center }
        skip.bezelStyle = .rounded
        skip.controlSize = .small
        skip.target = self
        skip.action = #selector(skipPressed)
        guide.bezelStyle = .rounded
        guide.controlSize = .small
        guide.target = self
        guide.action = #selector(guidePressed)
        for child in [spinner, title, count, skip, guide] { card.addSubview(child) }
    }

    required init?(coder: NSCoder) { nil }

    func update(_ progress: StartupConnectionProgress, settings: AppSettings) {
        title.stringValue = settings.t("Connecting to printers…")
        count.stringValue = settings.t("{0} of {1} printers ready", progress.ready, progress.total)
        skip.title = settings.t("Show dashboard now")
        guide.title = settings.t("How to read Gantry")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            spinner.stopAnimation(nil)
        } else {
            spinner.startAnimation(nil)
        }
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { spinner.stopAnimation(nil) }
    }

    override func layout() {
        super.layout()
        let width = min(340, max(1, bounds.width - 32))
        let height = min(212, max(1, bounds.height - 52))
        card.frame = NSRect(x: floor((bounds.width - width) / 2),
                            y: floor((bounds.height - height) / 2) - 10, width: width, height: height)
        spinner.isHidden = height < 140
        count.isHidden = height < 140
        spinner.frame = NSRect(x: (width - 28) / 2, y: height - 50, width: 28, height: 28)
        title.frame = NSRect(x: 12, y: height - 83, width: width - 24, height: 22)
        if height < 140 { title.frame.origin.y = max(42, height - 40) }
        count.frame = NSRect(x: 12, y: height - 107, width: width - 24, height: 18)
        guide.isHidden = height < 195
        guide.frame = NSRect(x: (width - min(220, width - 24)) / 2, y: 47,
                            width: min(220, width - 24), height: 24)
        skip.frame = NSRect(x: (width - min(220, width - 24)) / 2, y: 16,
                            width: min(220, width - 24), height: 24)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    @objc private func skipPressed() { onSkip() }
    @objc private func guidePressed() { onGuide() }
    override func mouseDown(with event: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }
}
