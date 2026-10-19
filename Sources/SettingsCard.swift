import AppKit

/// The Settings page of the menu bar panel.
/// Every change is saved at once; the panel redraws after a key change.
final class SettingsCard: NSView, NSTextViewDelegate {
    private static let padding: CGFloat = 16
    private let store: SettingsStore
    private let catalog: ModelCatalog
    private let onChange: () -> Void

    override var isFlipped: Bool { true }

    init(store: SettingsStore, catalog: ModelCatalog, width: CGFloat, audioInput: AudioInputController? = nil,
         onDone: @escaping () -> Void, onChange: @escaping () -> Void)
    {
        self.store = store
        self.catalog = catalog
        self.onChange = onChange
        super.init(frame: .zero)
        styleAsCard(self)

        let settings = store.settings
        let headerHeight: CGFloat = 40
        let title = themedLabel("SETTINGS", font: Theme.label, color: Theme.textMuted, kern: 0.88)
        title.frame.origin = NSPoint(x: Self.padding, y: (headerHeight - title.frame.height) / 2)
        addSubview(title)
        let done = textButton("DONE", action: onDone)
        done.frame.origin = NSPoint(x: width - Self.padding - done.frame.width, y: (headerHeight - done.frame.height) / 2)
        addSubview(done)
        var y = divider(at: headerHeight, width: width, inset: 0)

        if let audioInput {
            let row = AudioInputRow(controller: audioInput, width: width)
            row.frame.origin.y = y
            addSubview(row)
            y = divider(at: row.frame.maxY, width: width, inset: 0)
        }

        y = keyRow(at: y, width: width, title: "PUSH-TO-TALK", caption: "Hold to talk",
                   value: settings.pushToTalk.title,
                   choices: TriggerKey.allCases.map { key in (key.title, key == settings.pushToTalk, { [weak self] in
                       self?.update { settings in
                           if settings.handsFree == key { settings.handsFree = settings.pushToTalk }
                           settings.pushToTalk = key
                       }
                   }) })
        y = divider(at: y, width: width, inset: Self.padding)
        y = keyRow(at: y, width: width, title: "HANDS-FREE", caption: "Press with push-to-talk",
                   value: settings.handsFree.title,
                   choices: TriggerKey.allCases.filter { $0 != settings.pushToTalk }.map { key in
                       (key.title, key == settings.handsFree, { [weak self] in self?.update { $0.handsFree = key } })
                   })
        y = divider(at: y, width: width, inset: Self.padding)
        y = keyRow(at: y, width: width, title: "CANCEL", caption: "Discard the current run",
                   value: settings.cancel.title,
                   choices: CancelKey.allCases.map { key in
                       (key.title, key == settings.cancel, { [weak self] in self?.update { $0.cancel = key } })
                   })
        y = divider(at: y, width: width, inset: 0)

        y = keyRow(at: y, width: width, title: "REWRITE PROVIDER", caption: "Choose the login to use",
                   value: settings.rewriteProvider.title,
                   choices: RewriteProvider.allCases.map { provider in
                       (provider.title, provider == settings.rewriteProvider, { [weak self] in
                           self?.update { settings in
                               guard settings.rewriteProvider != provider else { return }
                               settings.rewriteProvider = provider
                               settings.rewriteModel = catalog.models(for: provider).first?.slug ?? ""
                               settings.rewriteEffort = nil
                           }
                       })
                   })
        y = divider(at: y, width: width, inset: Self.padding)

        // A model missing from the catalog, for example after it was retired, still shows by name.
        let model = catalog.model(settings.rewriteModel, provider: settings.rewriteProvider)
        y = keyRow(at: y, width: width, title: "REWRITE MODEL", caption: settings.rewriteProvider == .claude ? "Uses your Claude Code login" : catalog.codexStatus,
                   value: model?.name ?? (settings.rewriteModel.isEmpty ? "Default" : settings.rewriteModel),
                   choices: catalog.models(for: settings.rewriteProvider).map { choice in (choice.name, choice.slug == settings.rewriteModel, { [weak self] in
                       self?.update { settings in
                           settings.rewriteModel = choice.slug
                           if let effort = settings.rewriteEffort, !choice.efforts.contains(effort) { settings.rewriteEffort = nil }
                       }
                   }) })
        y = divider(at: y, width: width, inset: Self.padding)
        let defaultTitle = "Default" + (model?.defaultEffort.map { " (\(Self.effortTitle($0)))" } ?? "")
        let efforts = model?.efforts ?? (settings.rewriteProvider == .claude ? ModelCatalog.cliEfforts : [])
        y = keyRow(at: y, width: width, title: "REWRITE EFFORT", caption: "Higher can be slower",
                   value: settings.rewriteEffort.map(Self.effortTitle) ?? defaultTitle,
                   choices: [(defaultTitle, settings.rewriteEffort == nil, { [weak self] in self?.update { $0.rewriteEffort = nil } })]
                       + efforts.map { effort in (Self.effortTitle(effort), effort == settings.rewriteEffort, { [weak self] in
                           self?.update { $0.rewriteEffort = effort }
                       }) })
        y = divider(at: y, width: width, inset: Self.padding)

        let wordsTitle = themedLabel("REWRITE WORDS", font: Theme.label, color: Theme.textMuted, kern: 0.88)
        wordsTitle.frame.origin = NSPoint(x: Self.padding, y: y + 12)
        addSubview(wordsTitle)
        let wordsCaption = themedLabel("Names the rewrite should spell correctly, one per line",
                                       font: Theme.caption, color: Theme.textMuted)
        wordsCaption.frame.origin = NSPoint(x: Self.padding, y: wordsTitle.frame.maxY + 2)
        addSubview(wordsCaption)

        let field = NSRect(x: Self.padding, y: wordsCaption.frame.maxY + 8, width: width - Self.padding * 2, height: 96)
        addSubview(wordsEditor(frame: field, words: settings.vocabulary))
        frame.size = NSSize(width: width, height: field.maxY + Self.padding)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func textDidChange(_ notification: Notification) {
        guard let text = (notification.object as? NSTextView)?.string else { return }
        let words = text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store.update { $0.vocabulary = words }
    }

    private static func effortTitle(_ effort: String) -> String {
        ["none": "None", "minimal": "Minimal", "ultra": "Ultra", "low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra High", "max": "Max"][effort] ?? effort
    }

    private func update(_ change: (inout Settings) -> Void) {
        store.update(change)
        onChange()
    }

    private func keyRow(at y: CGFloat, width: CGFloat, title: String, caption: String, value: String,
                        choices: [(String, Bool, () -> Void)]) -> CGFloat
    {
        let height: CGFloat = 52
        let name = themedLabel(title, font: Theme.label, color: Theme.textMuted, kern: 0.88)
        name.frame.origin = NSPoint(x: Self.padding, y: y + 10)
        addSubview(name)
        let chip = MenuChip(title: value, choices: choices, maxWidth: width - Self.padding * 2 - name.frame.width - 12)
        chip.setAccessibilityLabel("\(title): \(value)")
        chip.frame.origin = NSPoint(x: width - Self.padding - chip.frame.width, y: y + 4)
        addSubview(chip)

        let note = themedLabel(caption, font: Theme.caption, color: Theme.textMuted)
        note.lineBreakMode = .byTruncatingTail
        note.frame.origin = NSPoint(x: Self.padding, y: y + 33)
        note.frame.size.width = max(0, min(note.frame.width, width - Self.padding * 2))
        addSubview(note)
        return y + height
    }

    private func divider(at y: CGFloat, width: CGFloat, inset: CGFloat) -> CGFloat {
        let line = NSView(frame: NSRect(x: inset, y: y, width: width - inset * 2, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = (inset == 0 ? Theme.border : Theme.borderSoft).cgColor
        addSubview(line)
        return y + 1
    }

    /// The scroll view does not draw a layer border, so a plain bordered box holds it.
    private func wordsEditor(frame: NSRect, words: [String]) -> NSView {
        let box = NSView(frame: frame)
        box.wantsLayer = true
        box.layer?.borderColor = Theme.border.cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 4

        let scroll = NSScrollView(frame: box.bounds.insetBy(dx: 1, dy: 1))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        box.addSubview(scroll)

        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.string = words.joined(separator: "\n")
        text.font = Theme.body
        text.textColor = Theme.text
        text.backgroundColor = .clear
        text.drawsBackground = false
        text.insertionPointColor = Theme.accent
        text.selectedTextAttributes = [.backgroundColor: Theme.selection, .foregroundColor: Theme.text]
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.autoresizingMask = [.width]
        text.setAccessibilityLabel("Rewrite words, one per line")
        text.delegate = self
        scroll.documentView = text
        return box
    }
}

/// A bordered value chip that opens a menu of choices, the current one checked.
final class MenuChip: NSView {
    private let choices: [(String, Bool, () -> Void)]
    var isEnabled = true { didSet { setAccessibilityEnabled(isEnabled); alphaValue = isEnabled ? 1 : 0.65 } }

    override var isFlipped: Bool { true }

    init(title: String, choices: [(String, Bool, () -> Void)], maxWidth: CGFloat = 220) {
        self.choices = choices
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderColor = Theme.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
        setAccessibilityRole(.popUpButton)
        setAccessibilityValue(title)
        toolTip = title

        let text = themedLabel(title, font: Theme.body, color: Theme.textSecondary)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.frame.size.width = max(12, min(text.frame.width, maxWidth - 38))
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = Theme.iconMuted
        chevron.frame.size = NSSize(width: 10, height: 10)

        let height: CGFloat = 26
        text.frame.origin = NSPoint(x: 10, y: (height - text.frame.height) / 2)
        chevron.frame.origin = NSPoint(x: text.frame.maxX + 8, y: (height - 10) / 2)
        addSubview(text)
        addSubview(chevron)
        frame.size = NSSize(width: chevron.frame.maxX + 10, height: height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { showMenu() }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        showMenu()
        return true
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, selected, choose) in choices {
            let item = ClosureMenuItem(title: title, onSelect: choose)
            item.state = selected ? .on : .off
            item.isEnabled = isEnabled
            menu.addItem(item)
        }
        return menu
    }

    private func showMenu() {
        guard isEnabled else { return }
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: frame.height + 4), in: self)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let onSelect: () -> Void

    init(title: String, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        super.init(title: title, action: #selector(selected), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func selected() { onSelect() }
}

/// An uppercase text-only button in the muted label style.
func textButton(_ title: String, action: @escaping () -> Void) -> NSButton {
    let button = ClosureButton(title: "", target: nil, action: nil)
    button.onClick = action
    button.isBordered = false
    button.attributedTitle = NSAttributedString(string: title, attributes: [
        .font: Theme.label, .foregroundColor: Theme.textSecondary, .kern: 0.88,
    ])
    button.sizeToFit()
    return button
}

/// Only this row changes when a microphone connects or macOS selects another input.
final class AudioInputRow: NSView {
    private let controller: AudioInputController
    private struct State: Equatable {
        let title: String
        let caption: String
        let enabled: Bool
        let snapshot: AudioInputSnapshot
    }
    private var lastState: State?
    override var isFlipped: Bool { true }

    init(controller: AudioInputController, width: CGFloat) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        controller.onChange = { [weak self] in self?.render() }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        let state = State(title: controller.title, caption: controller.caption,
                          enabled: controller.canSelect, snapshot: controller.snapshot)
        guard state != lastState else { return }
        lastState = state
        subviews.forEach { $0.removeFromSuperview() }
        let name = themedLabel("MICROPHONE", font: Theme.label, color: Theme.textMuted, kern: 0.88)
        name.frame.origin = NSPoint(x: 16, y: 10)
        addSubview(name)
        let chip = MenuChip(title: state.title, choices: state.snapshot.devices.map { device in
            (device.name, device.id == state.snapshot.defaultID, { [weak controller] in controller?.select(device.id) })
        }, maxWidth: bounds.width - 32)
        chip.isEnabled = state.enabled
        chip.setAccessibilityLabel("Microphone: \(state.title)")
        chip.frame.origin = NSPoint(x: 16, y: 28)
        addSubview(chip)
        let note = NSTextField(wrappingLabelWithString: state.caption)
        note.font = Theme.caption
        note.textColor = controller.error == nil ? Theme.textMuted : Theme.errorText
        note.frame = NSRect(x: 16, y: 62, width: bounds.width - 32, height: 30)
        note.toolTip = state.caption
        addSubview(note)
    }
}
