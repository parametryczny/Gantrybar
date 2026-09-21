import AppKit

/// Building blocks for the settings window, in the shape macOS itself uses.
///
/// Nothing here paints a background, a border, a card or a tab pill. The window's own material, the
/// system label colours and the stock controls carry the entire look. That is the whole point of this
/// file: the previous window drew its own `#0C0D0E` canvas, its own rounded sections with hairline
/// borders, its own pill tab bar and its own footer with a Done button, and all of that is what made
/// it read as a stranger sitting on the desktop rather than as part of the system.
///
/// The layout is the classic preferences grid: captions right-aligned in the first column, controls
/// left-aligned in the second, both sharing one vertical axis down the whole pane. `NSGridView` is
/// the AppKit class built for exactly this, so the alignment is not maintained by hand.

/// Counts writes that can change a pane's height.
///
/// A pane switch is dominated by laying the pane out and asking for its fitting size, and almost
/// nothing a user clicks in here changes any height: a boolean toggle rewrites no text at all. So the
/// writes that *would* change a height report themselves, and a refresh that touched none of them
/// leaves the pane's measured height alone. Ticking a checkbox therefore costs no layout pass, while
/// switching language or showing the dashboard QR block still re-measures properly.
@MainActor
enum SettingsLayoutTouches {
    private(set) static var count = 0
    static func touch() { count += 1 }
}

@MainActor
enum SettingsMetrics {
    /// Captions column. Wide enough for the longest Polish caption at 13 pt without wrapping.
    static let captionColumn: CGFloat = 164
    /// Controls column, and therefore the wrapping width of every explanatory line.
    static let controlColumn: CGFloat = 336
    static let paneInset: CGFloat = 20
    static let rowSpacing: CGFloat = 9
    static let columnSpacing: CGFloat = 10
    /// Left inset of an explanation under a checkbox, so it lines up with the checkbox's own title
    /// rather than with the box.
    static let checkboxTextInset: CGFloat = 21
}

/// A caption for the left column. A plain system label: no custom colour, no uppercase, no tracking.
@MainActor
func settingsCaption(_ text: String = "") -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 13)
    field.textColor = .labelColor
    field.alignment = .right
    return field
}

/// The small grey line that explains a control. Given a definite width so the pane has a definite
/// height, which is what lets the window size itself to each pane.
@MainActor
func settingsNote(_ text: String = "", width: CGFloat = SettingsMetrics.controlColumn) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: 11)
    field.textColor = .secondaryLabelColor
    field.translatesAutoresizingMaskIntoConstraints = false
    field.widthAnchor.constraint(equalToConstant: width).isActive = true
    return field
}

/// A section heading spanning both columns.
@MainActor
func settingsHeading(_ text: String = "") -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 13, weight: .semibold)
    field.textColor = .labelColor
    return field
}

/// One checkbox, optionally with an explanation under it.
///
/// This replaces the 44 pt switch row the old window used for every boolean. Under a right-aligned
/// category caption, a column of checkboxes is the layout Apple's own panes use, and it costs about a
/// fifth of the height: the six notification switches alone were 264 points and are now near 120.
/// The API deliberately mirrors the old row, so the controller's refresh and action code did not have
/// to be rewritten alongside the chrome.
@MainActor
final class SettingsCheckbox: NSView {
    private let box: NSButton
    let subtitleLabel: NSTextField
    private let stack: NSStackView

    init(target: AnyObject?, action: Selector?, width: CGFloat = SettingsMetrics.controlColumn) {
        box = NSButton(checkboxWithTitle: "", target: target, action: action)
        box.font = .systemFont(ofSize: 13)
        subtitleLabel = settingsNote(width: width - SettingsMetrics.checkboxTextInset)
        subtitleLabel.isHidden = true
        stack = NSStackView(views: [box, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // The explanation hangs under the checkbox's title, not under its box.
        stack.setCustomSpacing(3, after: box)
        subtitleLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor,
                                               constant: SettingsMetrics.checkboxTextInset).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    /// A checkbox carries its own label, so there is no separate caption to keep in step.
    var title: String {
        get { box.title }
        set {
            guard box.title != newValue else { return }
            box.title = newValue
            SettingsLayoutTouches.touch()
        }
    }

    var isOn: Bool {
        get { box.state == .on }
        set { box.state = newValue ? .on : .off }
    }

    var checkbox: NSButton { box }

    func setSubtitle(_ text: String) {
        guard subtitleLabel.stringValue != text else { return }
        subtitleLabel.stringValue = text
        subtitleLabel.isHidden = text.isEmpty
        SettingsLayoutTouches.touch()
    }

    /// A disabled checkbox greys its own title, so unlike the old switch row there is no need to dim
    /// the whole line by hand. The explanation is dimmed to match, because it is a separate label.
    func setEnabled(_ enabled: Bool) {
        box.isEnabled = enabled
        subtitleLabel.alphaValue = enabled ? 1 : 0.45
    }

    /// The first baseline of the checkbox's own title, so a caption beside it lines up with the title
    /// and not with an explanation two lines further down.
    override var firstBaselineOffsetFromTop: CGFloat {
        box.firstBaselineOffsetFromTop
    }
}

/// Assembles one pane's grid. Rows are added in reading order and the grid keeps the two columns
/// aligned across every section, including across the separators.
@MainActor
final class SettingsGrid {
    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private var built = false

    init() {
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = SettingsMetrics.rowSpacing
        grid.columnSpacing = SettingsMetrics.columnSpacing
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 0).width = SettingsMetrics.captionColumn
    }

    /// A caption and its control on one line.
    ///
    /// `baseline` off centres the control against the caption instead of sharing its text baseline,
    /// which is what stepper-style and image-only controls need: they carry no baseline of their own,
    /// so AppKit would fall back to their bottom edge and the caption would sit visibly high.
    func field(_ caption: NSTextField, _ control: NSView, baseline: Bool = true) {
        let row = grid.addRow(with: [caption, control])
        guard !baseline else { return }
        row.rowAlignment = .none
        row.yPlacement = .center
    }

    /// A caption and a column of controls under one another, the layout for a run of related
    /// checkboxes. The caption lines up with the first one.
    func group(_ caption: NSTextField, _ views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [caption, stack])
    }

    /// Content with no caption, spanning both columns. Used for a heading, a list or a QR code.
    func wide(_ view: NSView, leading: CGFloat = 0) {
        let row = grid.addRow(with: [view])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.rowAlignment = .none
        grid.cell(for: view)?.xPlacement = .leading
        guard leading != 0 else { return }
        grid.cell(for: view)?.customPlacementConstraints = [
            view.leadingAnchor.constraint(equalTo: grid.leadingAnchor, constant: leading)
        ]
    }

    /// A control with no caption, sitting in the control column where it lines up with the controls
    /// above and below it.
    func aligned(_ view: NSView) {
        grid.addRow(with: [NSGridCell.emptyContentView, view])
    }

    /// Vertical air between sections, over and above the standard row spacing.
    func gap(_ height: CGFloat = 8) {
        grid.addRow(with: []).height = height
    }

    /// A full-width hairline, the system's own separator rather than a hand-coloured one.
    func separator() {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        let row = grid.addRow(with: [box])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.rowAlignment = .none
        grid.cell(for: box)?.xPlacement = .fill
        row.topPadding = 4
        row.bottomPadding = 4
    }

    /// Starts a new section: air, a hairline, more air, then the heading.
    func section(_ heading: NSTextField) {
        gap(4)
        separator()
        wide(heading)
    }

    func build() -> NSGridView {
        built = true
        return grid
    }
}

/// One pane of the settings window.
///
/// The pane reports its own fitting size as `preferredContentSize`, which is what makes the window
/// grow and shrink around each pane the way a system settings window does. Every wrapping label in
/// here has a definite width for the same reason: without one the pane has no determinate height and
/// the window would settle on whatever AppKit guessed first.
@MainActor
final class SettingsPane: NSViewController {
    let paneIdentifier: String
    let symbolName: String
    private let content: NSGridView
    /// Filled in by the controller's refresh, because the toolbar label follows the app's language.
    var paneTitle: String = ""

    init(identifier: String, symbolName: String, content: NSGridView) {
        self.paneIdentifier = identifier
        self.symbolName = symbolName
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        // Autoresizing on purpose, and this is load-bearing. `NSTabView` positions and sizes its
        // children by setting frames, so a root view that had opted out of autoresizing kept whatever
        // frame it was first given: the pane came out the right size but at the previous pane's
        // offset, which is why the content sat far from the top and ran off the bottom edge.
        root.autoresizingMask = [.width, .height]
        // A pane taller than the screen used to make a window that ran off the bottom edge, with its
        // last rows out of reach. The window caps its height at what the display can show and the
        // pane scrolls the rest; a pane that fits still sizes the window exactly, and never scrolls.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        root.addSubview(scroll)
        let inset = SettingsMetrics.paneInset
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -inset),
            content.widthAnchor.constraint(equalToConstant: SettingsMetrics.captionColumn
                                           + SettingsMetrics.columnSpacing
                                           + SettingsMetrics.controlColumn)
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updatePreferredSize()
    }

    /// Set whenever the controller refills this pane, because that is the only thing that can change
    /// its height: a section appearing, a longer explanation in another language, a printer joining
    /// the fleet. Measuring is the expensive half of a pane switch, so an unchanged pane reuses the
    /// height it already reported instead of laying itself out again.
    var contentDirty = true

    /// Re-measures, but only when there is a reason to.
    func updatePreferredSize() {
        guard contentDirty || preferredContentSize.height < 1 else { return }
        contentDirty = false
        view.layoutSubtreeIfNeeded()
        // The root holds a scroll view now, and a scroll view is content to be any size at all, so the
        // pane's real height is its content plus the inset above and below it.
        let fitting = content.fittingSize
        let size = NSSize(width: fitting.width + 2 * SettingsMetrics.paneInset,
                          height: fitting.height + 2 * SettingsMetrics.paneInset)
        guard size.height > 1, preferredContentSize != size else { return }
        preferredContentSize = size
    }
}

/// Compact minus/value/plus control used for discrete UI scale presets.
@MainActor
final class SettingsScaleControl: NSView {
    private let minus = NSButton(title: "−", target: nil, action: nil)
    private let plus = NSButton(title: "+", target: nil, action: nil)
    private let value = NSTextField(labelWithString: "100%")
    var onStep: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        for button in [minus, plus] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 15, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        minus.target = self
        minus.action = #selector(stepDown)
        plus.target = self
        plus.action = #selector(stepUp)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .center
        value.widthAnchor.constraint(equalToConstant: 46).isActive = true

        let stack = NSStackView(views: [minus, value, plus])
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

    func configure(percent: Int, steps: [Int], enabled: Bool = true) {
        value.stringValue = "\(percent)%"
        let index = steps.firstIndex(of: percent) ?? 0
        minus.isEnabled = enabled && index > 0
        plus.isEnabled = enabled && index < steps.count - 1
    }

    @objc private func stepDown() { onStep?(-1) }
    @objc private func stepUp() { onStep?(1) }
}
