import AppKit

/// Building blocks for the settings window: a row (title, optional explanation, trailing control),
/// a card that stacks rows behind hairline separators, and the pill tab bar at the top.
///
/// The whole window is assembled from these three pieces so every screen lines up: one column of
/// controls flush right, one column of labels flush left, and a single rhythm of 44 pt rows.

/// A single settings line. The control is optional so the same row also carries plain information.
@MainActor
class SettingsRowView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let textStack: NSStackView

    init(control: NSView?, minHeight: CGFloat = 44) {
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = GantryTheme.text
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = GantryTheme.muted
        subtitleLabel.isHidden = true
        textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        var constraints: [NSLayoutConstraint] = [
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
            titleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor)
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                // A definite trailing edge, not a minimum, so the wrapping subtitle knows its width.
                textStack.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -12)
            ]
        } else {
            constraints.append(textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }

    /// The explanation under the title. Empty text collapses the line instead of leaving a gap.
    func setSubtitle(_ text: String) {
        subtitleLabel.stringValue = text
        subtitleLabel.isHidden = text.isEmpty
    }
}

/// A row whose control is a switch. Stored separately because a subclass has to initialise its own
/// properties before `super.init`, so the switch is built locally and handed up.
@MainActor
final class SettingsToggleRow: SettingsRowView {
    private let switchControl: NSSwitch

    init(target: AnyObject?, action: Selector?, minHeight: CGFloat = 44) {
        let control = NSSwitch()
        switchControl = control
        super.init(control: control, minHeight: minHeight)
        control.target = target
        control.action = action
    }

    required init?(coder: NSCoder) { nil }

    var toggle: NSSwitch { switchControl }
    var isOn: Bool {
        get { switchControl.state == .on }
        set { switchControl.state = newValue ? .on : .off }
    }
    /// Dims the whole row, not just the control, so a disabled section reads as inactive.
    func setEnabled(_ enabled: Bool) {
        switchControl.isEnabled = enabled
        alphaValue = enabled ? 1 : 0.45
    }
}

/// A row that hosts arbitrary content across the full width (QR code, token fields, peer list).
@MainActor
final class SettingsContentRow: NSView {
    init(_ content: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 11, left: 14, bottom: 12, right: 14)) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// The pill tab bar. Selection is a background on the chosen button rather than a sliding indicator,
/// which keeps it correct without animation bookkeeping when the labels change language.
@MainActor
final class SettingsTabBar: NSView {
    private var buttons: [NSButton] = []
    private let stack = NSStackView()
    private(set) var selectedIndex = 0
    var onSelect: ((Int) -> Void)?

    init(count: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = GantryTheme.line.cgColor

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            heightAnchor.constraint(equalToConstant: 40)
        ])

        for index in 0..<count {
            let button = NSButton(title: "", target: self, action: #selector(tabClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            // A soft drop shadow lifts the active segment the way a macOS segmented control does.
            button.layer?.shadowColor = NSColor.black.cgColor
            button.layer?.shadowOffset = CGSize(width: 0, height: -1)
            button.layer?.shadowRadius = 2.5
            button.font = .systemFont(ofSize: 12.5, weight: .medium)
            button.setButtonType(.momentaryChange)
            buttons.append(button)
            stack.addArrangedSubview(button)
            // `.fillEqually` only equalises along the axis, so without this the buttons keep their
            // short intrinsic height and the corner radius reads as a capsule instead of a pill.
            button.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
        applySelection()
    }

    required init?(coder: NSCoder) { nil }

    func setTitles(_ titles: [String]) {
        for (button, title) in zip(buttons, titles) { button.title = title }
        applySelection()   // re-tint, since setting a title resets the attributed colour
    }

    func select(_ index: Int) {
        guard index >= 0, index < buttons.count else { return }
        selectedIndex = index
        applySelection()
    }

    @objc private func tabClicked(_ sender: NSButton) {
        select(sender.tag)
        onSelect?(sender.tag)
    }

    private func applySelection() {
        for (index, button) in buttons.enumerated() {
            let active = index == selectedIndex
            button.layer?.backgroundColor = active ? NSColor.white.withAlphaComponent(0.13).cgColor : NSColor.clear.cgColor
            button.layer?.shadowOpacity = active ? 0.3 : 0
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: active ? .semibold : .medium),
                             .foregroundColor: active ? GantryTheme.text : GantryTheme.secondary])
        }
    }
}

/// Top-down document view so a settings page scrolls from the top.
final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
