import AppKit

/// Per-printer automations editor: a list of rules, each a trigger → action, including custom Bambu
/// commands and shell scripts. Runs are manual (Run button) or fired by the trigger engine in the
/// store. Opened from the detail card.
@MainActor
final class AutomationsWindowController: NSWindowController {
    private let store: PrinterStore
    private let serial: String
    private var automations: [PrinterAutomation]
    private let listStack = NSStackView()

    init(store: PrinterStore, serial: String) {
        self.store = store
        self.serial = serial
        self.automations = AutomationStore.shared.automations(for: serial)

        let name = store.printers.first(where: { $0.serial == serial })?.name ?? serial
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = AppSettings.shared.text("Automatyzacje — \(name)", "Automations — \(name)")
        window.contentMinSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        rebuildList()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: AppSettings.shared.text("Automatyzacje", "Automations"))
        title.font = .systemFont(ofSize: 15, weight: .bold)
        let subtitle = NSTextField(labelWithString: AppSettings.shared.text(
            "Wyzwalacz → akcja. Reguły warunkowe odpalają się raz na wydruk. Skrypty działają z Twoimi uprawnieniami.",
            "Trigger → action. Conditional rules fire once per print. Scripts run with your privileges."))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2

        let addButton = NSButton(title: AppSettings.shared.text("＋ Dodaj automatyzację", "＋ Add automation"),
                                 target: self, action: #selector(addAutomation))
        addButton.bezelStyle = .rounded

        let header = NSStackView(views: [title, subtitle, addButton])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = AutomationsFlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(listStack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = flipped
        scroll.translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            flipped.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            flipped.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 4),
            listStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 16),
            listStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -16),
            listStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -16)
        ])
    }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if automations.isEmpty {
            let empty = NSTextField(labelWithString: AppSettings.shared.text(
                "Brak automatyzacji. Dodaj pierwszą przyciskiem powyżej.",
                "No automations yet. Add one with the button above."))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            listStack.addArrangedSubview(empty)
            return
        }
        for auto in automations {
            let row = AutomationRowView(
                automation: auto,
                onChange: { [weak self] updated in self?.update(updated) },
                onDelete: { [weak self] id in self?.delete(id) },
                onRun: { [weak self] a in self?.run(a) })
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    @objc private func addAutomation() {
        var auto = PrinterAutomation(name: AppSettings.shared.text("Nowa automatyzacja", "New automation"))
        auto.trigger = .atLayer(1)
        auto.action = .light(false)
        automations.append(auto)
        persist()
        rebuildList()
    }

    private func update(_ updated: PrinterAutomation) {
        guard let i = automations.firstIndex(where: { $0.id == updated.id }) else { return }
        automations[i] = updated
        persist()
    }

    private func delete(_ id: UUID) {
        automations.removeAll { $0.id == id }
        ScriptRunner.shared.stop(id)
        persist()
        rebuildList()
    }

    private func run(_ auto: PrinterAutomation) {
        // Scripts get an explicit confirmation; they run with the user's privileges.
        if auto.action.isScript, !ScriptRunner.shared.isRunning(auto.id) {
            let alert = NSAlert()
            alert.messageText = AppSettings.shared.text("Uruchomić skrypt „\(auto.name)”?",
                                                        "Run script “\(auto.name)”?")
            alert.informativeText = AppSettings.shared.text(
                "Skrypt uruchomi się z Twoimi uprawnieniami.",
                "The script will run with your privileges.")
            alert.addButton(withTitle: AppSettings.shared.text("Uruchom", "Run"))
            alert.addButton(withTitle: AppSettings.shared.text("Anuluj", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if auto.action.isScript, ScriptRunner.shared.isRunning(auto.id) {
            ScriptRunner.shared.stop(auto.id)
        } else {
            store.runAutomation(auto, serial: serial)
        }
        rebuildList()
    }

    private func persist() { AutomationStore.shared.set(automations, for: serial) }
}

private final class AutomationsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - One automation row (inline editor)

@MainActor
private final class AutomationRowView: NSView {
    private var automation: PrinterAutomation
    private let onChange: (PrinterAutomation) -> Void
    private let onDelete: (UUID) -> Void
    private let onRun: (PrinterAutomation) -> Void

    private let enabledCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let nameField = NSTextField()
    private let triggerPopup = NSPopUpButton()
    private let triggerValueContainer = NSView()
    private let actionPopup = NSPopUpButton()
    private let actionValueContainer = NSView()
    private var actionValueHeight: NSLayoutConstraint?
    private let runButton = NSButton()

    private static let triggerTitles = [("Ręczny", "Manual"), ("Po warstwie", "At layer"),
                                        ("Po %", "At %"), ("Gdy stan", "On state")]
    private static let actionTitles = [("Światło wł.", "Light on"), ("Światło wył.", "Light off"),
                                       ("Pauza", "Pause"), ("Wznów", "Resume"), ("Stop", "Stop"),
                                       ("Powiadomienie", "Notification"), ("Własna komenda", "Custom command"),
                                       ("Skrypt", "Script")]
    private static let stateOptions: [PrinterState] = [.printing, .paused, .finished, .error, .idle]

    init(automation: PrinterAutomation,
         onChange: @escaping (PrinterAutomation) -> Void,
         onDelete: @escaping (UUID) -> Void,
         onRun: @escaping (PrinterAutomation) -> Void) {
        self.automation = automation
        self.onChange = onChange
        self.onDelete = onDelete
        self.onRun = onRun
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func t(_ pl: String, _ en: String) -> String { AppSettings.shared.text(pl, en) }

    private func build() {
        enabledCheck.state = automation.enabled ? .on : .off
        enabledCheck.target = self
        enabledCheck.action = #selector(fieldsChanged)

        nameField.stringValue = automation.name
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.bezelStyle = .roundedBezel
        nameField.target = self
        nameField.action = #selector(fieldsChanged)
        nameField.delegate = nil

        runButton.bezelStyle = .rounded
        runButton.target = self
        runButton.action = #selector(runTapped)

        let deleteButton = NSButton(title: "🗑", target: self, action: #selector(deleteTapped))
        deleteButton.bezelStyle = .rounded

        let topRow = NSStackView(views: [enabledCheck, nameField, runButton, deleteButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for (pl, en) in Self.triggerTitles { triggerPopup.addItem(withTitle: t(pl, en)) }
        triggerPopup.target = self
        triggerPopup.action = #selector(triggerChanged)
        for (pl, en) in Self.actionTitles { actionPopup.addItem(withTitle: t(pl, en)) }
        actionPopup.target = self
        actionPopup.action = #selector(actionChanged)

        let triggerLabel = NSTextField(labelWithString: t("Wyzwalacz:", "Trigger:"))
        triggerLabel.font = .systemFont(ofSize: 11)
        triggerLabel.textColor = .secondaryLabelColor
        let triggerRow = NSStackView(views: [triggerLabel, triggerPopup, triggerValueContainer])
        triggerRow.orientation = .horizontal
        triggerRow.alignment = .centerY
        triggerRow.spacing = 6

        let actionLabel = NSTextField(labelWithString: t("Akcja:", "Action:"))
        actionLabel.font = .systemFont(ofSize: 11)
        actionLabel.textColor = .secondaryLabelColor
        let actionRow = NSStackView(views: [actionLabel, actionPopup])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 6

        let stack = NSStackView(views: [topRow, triggerRow, actionRow, actionValueContainer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionValueContainer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        syncTriggerSelection()
        syncActionSelection()
        syncRunButton()
    }

    // MARK: Trigger

    private func syncTriggerSelection() {
        switch automation.trigger {
        case .manual: triggerPopup.selectItem(at: 0)
        case .atLayer: triggerPopup.selectItem(at: 1)
        case .atProgress: triggerPopup.selectItem(at: 2)
        case .onState: triggerPopup.selectItem(at: 3)
        }
        rebuildTriggerValue()
    }

    private func rebuildTriggerValue() {
        triggerValueContainer.subviews.forEach { $0.removeFromSuperview() }
        let control: NSView?
        switch triggerPopup.indexOfSelectedItem {
        case 1, 2:
            let field = NSTextField()
            field.bezelStyle = .roundedBezel
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
            if case .atLayer(let n) = automation.trigger { field.integerValue = n }
            if case .atProgress(let p) = automation.trigger { field.integerValue = p }
            field.target = self
            field.action = #selector(fieldsChanged)
            control = field
        case 3:
            let popup = NSPopUpButton()
            for s in Self.stateOptions { popup.addItem(withTitle: s.label) }
            if case .onState(let raw) = automation.trigger,
               let idx = Self.stateOptions.firstIndex(where: { $0.rawValue == raw }) { popup.selectItem(at: idx) }
            popup.target = self
            popup.action = #selector(fieldsChanged)
            control = popup
        default:
            control = nil
        }
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            triggerValueContainer.addSubview(control)
            NSLayoutConstraint.activate([
                control.topAnchor.constraint(equalTo: triggerValueContainer.topAnchor),
                control.bottomAnchor.constraint(equalTo: triggerValueContainer.bottomAnchor),
                control.leadingAnchor.constraint(equalTo: triggerValueContainer.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: triggerValueContainer.trailingAnchor)
            ])
        }
    }

    private func currentTrigger() -> AutomationTrigger {
        switch triggerPopup.indexOfSelectedItem {
        case 1: return .atLayer(max(1, (triggerValueContainer.subviews.first as? NSTextField)?.integerValue ?? 1))
        case 2: return .atProgress(min(100, max(0, (triggerValueContainer.subviews.first as? NSTextField)?.integerValue ?? 50)))
        case 3:
            let idx = (triggerValueContainer.subviews.first as? NSPopUpButton)?.indexOfSelectedItem ?? 0
            return .onState(Self.stateOptions[min(idx, Self.stateOptions.count - 1)].rawValue)
        default: return .manual
        }
    }

    // MARK: Action

    private func syncActionSelection() {
        let index: Int
        switch automation.action {
        case .light(let on): index = on ? 0 : 1
        case .pause: index = 2
        case .resume: index = 3
        case .stop: index = 4
        case .notify: index = 5
        case .command: index = 6
        case .script: index = 7
        }
        actionPopup.selectItem(at: index)
        rebuildActionValue()
    }

    private func rebuildActionValue() {
        actionValueContainer.subviews.forEach { $0.removeFromSuperview() }
        actionValueHeight?.isActive = false   // clear any previous fixed height so a new editor can grow
        actionValueHeight = nil
        let index = actionPopup.indexOfSelectedItem
        let control: NSView?
        switch index {
        case 5: // notify
            let field = NSTextField()
            field.bezelStyle = .roundedBezel
            field.placeholderString = t("Treść powiadomienia", "Notification text")
            if case .notify(let s) = automation.action { field.stringValue = s }
            field.target = self
            field.action = #selector(fieldsChanged)
            control = field
        case 6, 7: // command / script — multiline
            let textView = NSTextView()
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.string = {
                if case .command(let s) = automation.action { return s }
                if case .script(let s) = automation.action { return s }
                return ""
            }()
            textView.delegate = self
            let scroll = NSScrollView()
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.heightAnchor.constraint(equalToConstant: index == 7 ? 110 : 60).isActive = true
            textView.minSize = NSSize(width: 0, height: 60)
            textView.maxSize = NSSize(width: 10_000, height: 10_000)
            textView.isVerticallyResizable = true
            textView.textContainer?.widthTracksTextView = true
            control = scroll
        default:
            control = nil
        }
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            actionValueContainer.addSubview(control)
            NSLayoutConstraint.activate([
                control.topAnchor.constraint(equalTo: actionValueContainer.topAnchor),
                control.bottomAnchor.constraint(equalTo: actionValueContainer.bottomAnchor),
                control.leadingAnchor.constraint(equalTo: actionValueContainer.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: actionValueContainer.trailingAnchor)
            ])
        } else {
            let zero = actionValueContainer.heightAnchor.constraint(equalToConstant: 0)
            zero.isActive = true
            actionValueHeight = zero
        }
    }

    private func currentAction() -> AutomationAction {
        switch actionPopup.indexOfSelectedItem {
        case 0: return .light(true)
        case 1: return .light(false)
        case 2: return .pause
        case 3: return .resume
        case 4: return .stop
        case 5: return .notify((actionValueContainer.subviews.first as? NSTextField)?.stringValue ?? "")
        case 6: return .command(actionText())
        case 7: return .script(actionText())
        default: return .light(false)
        }
    }

    private func actionText() -> String {
        guard let scroll = actionValueContainer.subviews.first as? NSScrollView,
              let tv = scroll.documentView as? NSTextView else { return "" }
        return tv.string
    }

    private func syncRunButton() {
        let running = automation.action.isScript && ScriptRunner.shared.isRunning(automation.id)
        runButton.title = running ? t("Stop", "Stop") : t("Uruchom", "Run")
    }

    // MARK: Actions

    @objc private func triggerChanged() { rebuildTriggerValue(); fieldsChanged() }
    @objc private func actionChanged() { rebuildActionValue(); fieldsChanged() }

    @objc private func fieldsChanged() {
        automation.enabled = enabledCheck.state == .on
        automation.name = nameField.stringValue.isEmpty ? t("Automatyzacja", "Automation") : nameField.stringValue
        automation.trigger = currentTrigger()
        automation.action = currentAction()
        onChange(automation)
    }

    @objc private func runTapped() {
        fieldsChanged()
        onRun(automation)
        syncRunButton()
    }

    @objc private func deleteTapped() { onDelete(automation.id) }
}

extension AutomationRowView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { fieldsChanged() }
}
