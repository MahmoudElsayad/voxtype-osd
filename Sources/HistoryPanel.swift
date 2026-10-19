import AppKit

/// A menu bar icon that opens the transcription history. Clicking a row copies its text.
///
/// The panel never activates this app, so focus stays in the app the user was typing in and the
/// copied text can be pasted there straight away.
final class HistoryPanel: NSObject {
    private static let width: CGFloat = 360
    private static let maxHeight: CGFloat = 440

    private let history: History
    private let rewrite: RewriteSwitch
    private let settings: SettingsStore
    private let catalog = ModelCatalog()
    private var showingSettings = false
    private let audioInput = AudioInputController()
    private var inputTimer: Timer?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = KeyPanel(
        contentRect: NSRect(x: 0, y: 0, width: HistoryPanel.width, height: 120),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    private var outsideClickMonitor: Any?

    init(history: History, rewrite: RewriteSwitch, settings: SettingsStore) {
        self.history = history
        self.rewrite = rewrite
        self.settings = settings
        super.init()

        if let button = statusItem.button {
            updateIcon()
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.close() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(close), name: NSWindow.didResignKeyNotification, object: panel)
    }

    /// Call after the history changes so an open panel shows the new entry.
    func historyChanged() {
        if panel.isVisible, !showingSettings { render() }
    }

    /// A waveform, or a wand while the rewrite is on.
    private func updateIcon() {
        let name = rewrite.isOn ? "wand.and.sparkles" : "waveform"
        let description = rewrite.isOn ? "Voxtype history, rewrite on" : "Voxtype history"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        statusItem.button?.image?.isTemplate = true
    }

    @objc private func toggleRewrite() {
        rewrite.isOn.toggle()
        updateIcon()
        historyChanged()
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { return showMenu() }
        panel.isVisible ? close() : open()
    }

    private func showMenu() {
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: "Rewrite transcription", action: #selector(toggleRewrite), keyEquivalent: "")
        toggle.target = self
        toggle.state = rewrite.isOn ? .on : .off
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !history.entries.isEmpty
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit VoxtypeOSD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func clearHistory() {
        history.clear()
        historyChanged()
    }

    private func open() {
        render()
        position()
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.close()
        }
    }

    @objc private func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        showingSettings = false
        inputTimer?.invalidate()
        inputTimer = nil
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    private func position() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        let x = min(max(anchor.midX - size.width / 2, visible.minX + Theme.gap), visible.maxX - size.width - Theme.gap)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - 4 - size.height))
    }

    private func render() {
        let card: NSView = showingSettings
            ? SettingsCard(
                store: settings, catalog: catalog, width: Self.width, audioInput: audioInput,
                onDone: { [weak self] in self?.showSettings(false) },
                onChange: { [weak self] in self?.render() })
            : HistoryCard(
                entries: history.entries, rewriteOn: rewrite.isOn, width: Self.width, maxHeight: Self.maxHeight,
                onToggleRewrite: { [weak self] in self?.toggleRewrite() },
                onOpenSettings: { [weak self] in self?.showSettings(true) },
                onCopy: { [weak self] text, row in self?.copy(text, from: row) })
        // Read the size first: becoming the content view resizes the card to the current panel.
        let size = card.frame.size
        let top = panel.frame.maxY
        panel.setContentSize(size)
        panel.contentView = card
        if panel.isVisible { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
    }

    private func showSettings(_ show: Bool) {
        showingSettings = show
        inputTimer?.invalidate()
        inputTimer = nil
        if show {
            audioInput.refresh()
            audioInput.loadRecordingInput()
            inputTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.audioInput.refresh()
            }
        }
        render()
        if show {
            catalog.refreshCodexIfStale { [weak self] in
                guard let self else { return }
                // First successful discovery supplies a default only for an unchosen Codex model.
                if self.settings.settings.rewriteProvider == .codex,
                   self.settings.settings.rewriteModel.isEmpty,
                   let model = self.catalog.codexModels.first {
                    self.settings.update { $0.rewriteModel = model.slug; $0.rewriteEffort = nil }
                }
                if self.showingSettings { self.render() }
            }
            catalog.refreshIfStale { [weak self] in
                if self?.showingSettings == true { self?.render() }
            }
        }
    }

    private func copy(_ text: String, from row: HistoryRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.close() }
    }
}

/// A borderless panel that can take keyboard focus without activating the app.
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The history card: a header with the count, the rewrite switch and Settings, then one row per transcription.
final class HistoryCard: NSView {
    override var isFlipped: Bool { true }

    init(entries: [Transcription], rewriteOn: Bool, width: CGFloat, maxHeight: CGFloat,
         onToggleRewrite: @escaping () -> Void, onOpenSettings: @escaping () -> Void,
         onCopy: @escaping (String, HistoryRow) -> Void)
    {
        super.init(frame: .zero)
        styleAsCard(self)

        let headerHeight: CGFloat = 40
        let title = themedLabel("HISTORY", font: Theme.label, color: Theme.textMuted, kern: 0.88)
        title.frame.origin = NSPoint(x: 16, y: (headerHeight - title.frame.height) / 2)
        addSubview(title)
        let count = themedLabel("\(entries.count)", font: Theme.data, color: Theme.textMuted)
        count.frame.origin = NSPoint(x: title.frame.maxX + 8, y: (headerHeight - count.frame.height) / 2)
        addSubview(count)
        let gear = iconButton("gearshape", description: "Settings", action: onOpenSettings)
        gear.frame.origin = NSPoint(x: width - 12 - gear.frame.width, y: (headerHeight - gear.frame.height) / 2)
        addSubview(gear)
        let toggle = RewriteToggle(isOn: rewriteOn, onToggle: onToggleRewrite)
        toggle.frame.origin = NSPoint(x: gear.frame.minX - 12 - toggle.frame.width, y: (headerHeight - toggle.frame.height) / 2)
        addSubview(toggle)
        let divider = NSView(frame: NSRect(x: 0, y: headerHeight, width: width, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.border.cgColor
        addSubview(divider)

        let listTop = headerHeight + 1
        let list = FlippedView()
        var y: CGFloat = 0
        for (index, entry) in entries.enumerated() {
            let row = HistoryRow(entry: entry, offersOriginal: rewriteOn, width: width, onCopy: onCopy)
            row.frame.origin = NSPoint(x: 0, y: y)
            list.addSubview(row)
            y += row.frame.height
            if index < entries.count - 1 {
                let line = NSView(frame: NSRect(x: 16, y: y, width: width - 32, height: 1))
                line.wantsLayer = true
                line.layer?.backgroundColor = Theme.borderSoft.cgColor
                list.addSubview(line)
                y += 1
            }
        }
        if entries.isEmpty {
            let empty = themedLabel("Nothing here.", font: Theme.body, color: Theme.textMuted)
            empty.frame.origin = NSPoint(x: 16, y: 16)
            list.addSubview(empty)
            y = empty.frame.height + 32
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: y)

        let listHeight = min(y, maxHeight - listTop)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: listTop, width: width, height: listHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = y > listHeight
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        addSubview(scroll)

        frame.size = NSSize(width: width, height: listTop + listHeight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// One transcription: its time, copy controls, and a two-line preview. Hover highlights, click copies.
///
/// While the rewrite switch is on, a rewritten row also offers ORIGINAL, which copies the
/// transcription from before the rewrite.
final class HistoryRow: NSView {
    private static let padding: CGFloat = 16
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    private let entry: Transcription
    private let onCopy: (String, HistoryRow) -> Void
    private let time: NSTextField
    private let copied: NSTextField
    private let copyButton: NSButton
    private var originalButton: NSButton?
    private var hovered = false { didSet { updateColors() } }

    override var isFlipped: Bool { true }

    init(entry: Transcription, offersOriginal: Bool, width: CGFloat,
         onCopy: @escaping (String, HistoryRow) -> Void)
    {
        self.entry = entry
        self.onCopy = onCopy
        let formatter = Calendar.current.isDateInToday(entry.date) ? Self.timeFormatter : Self.dayFormatter
        let stamp = formatter.string(from: entry.date) + (entry.original == nil ? "" : "  ·  rewritten")
        time = themedLabel(stamp, font: Theme.dataSmall, color: Theme.textMuted)
        copied = themedLabel("COPIED", font: Theme.label, color: Theme.accentWashText, kern: 0.88)
        copyButton = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")!,
            target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy: \(entry.text)")

        let inner = width - Self.padding * 2
        time.frame.origin = NSPoint(x: Self.padding, y: 12)
        addSubview(time)
        copied.frame.origin = NSPoint(x: width - Self.padding - copied.frame.width, y: 12)
        copied.isHidden = true
        addSubview(copied)

        copyButton.isBordered = false
        copyButton.imageScaling = .scaleProportionallyDown
        copyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        copyButton.contentTintColor = Theme.iconMuted
        copyButton.toolTip = "Copy"
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.frame = NSRect(x: width - Self.padding - 20 + 4, y: 8, width: 20, height: 20)
        addSubview(copyButton)

        if offersOriginal, entry.original != nil {
            let button = NSButton(title: "", target: self, action: #selector(copyOriginalClicked))
            button.isBordered = false
            button.attributedTitle = Self.buttonTitle("ORIGINAL", color: Theme.textMuted)
            button.sizeToFit()
            button.toolTip = "Copy the transcription from before the rewrite"
            button.setAccessibilityLabel("Copy original")
            button.frame.origin = NSPoint(x: copyButton.frame.minX - 4 - button.frame.width, y: 8 + (20 - button.frame.height) / 2)
            addSubview(button)
            originalButton = button
        }

        let text = NSTextField(wrappingLabelWithString: entry.text)
        text.font = Theme.body
        text.textColor = Theme.text
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byWordWrapping
        text.cell?.truncatesLastVisibleLine = true
        text.preferredMaxLayoutWidth = inner
        text.isSelectable = false
        let textHeight = text.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height
        text.frame = NSRect(x: Self.padding, y: time.frame.maxY + 4, width: inner, height: textHeight)
        addSubview(text)

        frame.size = NSSize(width: width, height: text.frame.maxY + 12)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replaces the copy controls with COPIED, or ORIGINAL COPIED when the original was taken.
    func showCopied(original: Bool = false) {
        copyButton.isHidden = true
        originalButton?.isHidden = true
        copied.stringValue = original ? "ORIGINAL COPIED" : "COPIED"
        copied.attributedStringValue = NSAttributedString(string: copied.stringValue, attributes: [
            .font: Theme.label, .foregroundColor: Theme.accentWashText, .kern: 0.88,
        ])
        copied.sizeToFit()
        copied.frame.origin.x = frame.width - Self.padding - copied.frame.width
        copied.isHidden = false
    }

    private func copyFinal() {
        onCopy(entry.text, self)
        showCopied()
    }

    @objc private func copyClicked() { copyFinal() }

    @objc private func copyOriginalClicked() {
        guard let original = entry.original else { return }
        onCopy(original, self)
        showCopied(original: true)
    }

    private static func buttonTitle(_ title: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Theme.label, .foregroundColor: color, .kern: 0.88])
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { copyFinal() }
    override func accessibilityPerformPress() -> Bool {
        copyFinal()
        return true
    }

    /// Muted text drops below 4.5:1 on the hover surface, so it moves to the secondary role there.
    private func updateColors() {
        layer?.backgroundColor = hovered ? Theme.surfaceRaised.cgColor : nil
        time.textColor = hovered ? Theme.textSecondary : Theme.textMuted
        copyButton.contentTintColor = hovered ? Theme.text : Theme.iconMuted
        originalButton?.attributedTitle = Self.buttonTitle("ORIGINAL", color: hovered ? Theme.textSecondary : Theme.textMuted)
    }
}

/// "REWRITE" with an ON or OFF chip. Clicking anywhere on it flips the switch.
final class RewriteToggle: NSView {
    private let onToggle: () -> Void

    override var isFlipped: Bool { true }

    init(isOn: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Rewrite transcription")
        setAccessibilityValue(isOn)
        toolTip = "Rewrite each transcription with the selected provider before it is typed"

        let name = themedLabel("REWRITE", font: Theme.label, color: Theme.textMuted, kern: 0.88)
        let state = themedLabel(isOn ? "ON" : "OFF", font: Theme.label,
                          color: isOn ? Theme.accentWashText : Theme.textMuted, kern: 0.88)
        let chip = NSView(frame: NSRect(x: 0, y: 0, width: state.frame.width + 12, height: 20))
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 4
        chip.layer?.backgroundColor = isOn ? Theme.accentSurface.cgColor : nil
        chip.layer?.borderColor = (isOn ? Theme.accentSurface : Theme.border).cgColor
        chip.layer?.borderWidth = 1
        state.frame.origin = NSPoint(x: 6, y: (20 - state.frame.height) / 2)
        chip.addSubview(state)

        name.frame.origin = NSPoint(x: 0, y: (20 - name.frame.height) / 2)
        chip.frame.origin = NSPoint(x: name.frame.maxX + 8, y: 0)
        addSubview(name)
        addSubview(chip)
        frame.size = NSSize(width: chip.frame.maxX, height: 20)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseUp(with event: NSEvent) { onToggle() }
    override func accessibilityPerformPress() -> Bool {
        onToggle()
        return true
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

func themedLabel(_ string: String, font: NSFont, color: NSColor, kern: CGFloat = 0) -> NSTextField {
    let field = NSTextField(labelWithAttributedString: NSAttributedString(string: string, attributes: [
        .font: font, .foregroundColor: color, .kern: kern,
    ]))
    field.sizeToFit()
    return field
}

/// The flat Warm Charcoal card both panel pages share.
func styleAsCard(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = Theme.surface.cgColor
    view.layer?.borderColor = Theme.border.cgColor
    view.layer?.borderWidth = 1
    view.layer?.cornerRadius = 8
    view.layer?.masksToBounds = true
}

/// A 20-point borderless SF Symbol button in the muted icon color.
func iconButton(_ symbol: String, description: String, action: @escaping () -> Void) -> NSButton {
    let button = ClosureButton(
        image: NSImage(systemSymbolName: symbol, accessibilityDescription: description)!, target: nil, action: nil)
    button.onClick = action
    button.isBordered = false
    button.imageScaling = .scaleProportionallyDown
    button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    button.contentTintColor = Theme.iconMuted
    button.toolTip = description
    button.frame.size = NSSize(width: 20, height: 20)
    return button
}

final class ClosureButton: NSButton {
    var onClick: () -> Void = {} {
        didSet {
            target = self
            action = #selector(clicked)
        }
    }

    @objc private func clicked() { onClick() }
}
