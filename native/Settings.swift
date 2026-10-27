import AppKit

// The menu keeps the saved values visible. Only the message needs a draft editor.
final class PreferencesMenuController: NSObject, NSMenuDelegate {
    var isReady = false {
        didSet {
            guard isReady != oldValue else { return }
            editor?.isReady = isReady
            refresh()
        }
    }
    var onChange: (() -> Void)?

    /// A preferences problem for the main menu: a short row title, with details for its tooltip.
    /// A failed read shows first; a failed write stays until a later save succeeds.
    var problem: (title: String, detail: String)? {
        if let readError { return ("Couldn’t read preferences", readError) }
        if let writeError { return ("Couldn’t save preferences", writeError) }
        return nil
    }

    /// The watcher reads the same settings.json, so a failed read also holds its checks.
    var readFailed: Bool { readError != nil }

    var items: [NSMenuItem] { [retryItem, scanItem, messageItem, soundItem] }

    private let store: PreferencesStore
    private let retryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let scanItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let messageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let soundItem = NSMenuItem(title: "Whip Sound", action: nil, keyEquivalent: "")
    private let retryMenu = NSMenu(title: "Retry interval")
    private let scanMenu = NSMenu(title: "Check interval")
    private let messageMenu = NSMenu(title: "Retry message")
    private let retryChoices = [60, 120, 180, 300, 600, 900, 1800, 3600]
    private let scanChoices = [15, 30, 60, 120, 300, 600]
    private var editor: RetryMessageEditor?
    private var readError: String?
    private var writeError: String?

    init(store: PreferencesStore) {
        self.store = store
        super.init()
        soundItem.target = self
        soundItem.action = #selector(toggleSound(_:))
        soundItem.toolTip = "Play a short whip sound when a retry is sent. Uses your Mac’s current volume."
        for (item, menu) in [(retryItem, retryMenu), (scanItem, scanMenu), (messageItem, messageMenu)] {
            menu.autoenablesItems = false
            menu.delegate = self
            item.submenu = menu
        }
        // The titles keep one wording in every state. Until the saved file is
        // read, they show the bundled defaults, disabled.
        apply(store.defaults)
    }

    // Called as the menu opens, so preferences also reflect edits made by the CLI.
    // Reading is local and changes nothing, so the titles follow settings.json even
    // while the helper prepares; choices stay disabled until it is ready. After a
    // failed read, the titles keep the last values read, disabled, and the main menu
    // explains the error. This method never publishes a change back to its owner.
    func refresh() {
        do {
            apply(try store.read())
            readError = nil
        } catch {
            for item in items { item.isEnabled = false }
            readError = error.localizedDescription
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func editMessage() {
        guard isReady else { return }
        if let editor, editor.window?.isVisible == true {
            editor.bringForward()
            return
        }
        do {
            let saved = try store.read()
            apply(saved)
            readError = nil
            if editor == nil {
                let editor = RetryMessageEditor(defaultMessage: store.defaults.message)
                editor.onSave = { [weak self] message in
                    guard let self, self.isReady else {
                        throw MessageEditorError.unavailable
                    }
                    try self.saveMessage(message)
                }
                self.editor = editor
            }
            editor?.isReady = true
            editor?.present(message: saved.message)
        } catch {
            for item in items { item.isEnabled = false }
            readError = error.localizedDescription
            onChange?()
        }
    }

    private func apply(_ settings: RetrySettings) {
        retryItem.title = "Retry Every \(duration(settings.retrySeconds))"
        scanItem.title = "Check Every \(duration(settings.scanSeconds))"
        let isDefault = settings.message == store.defaults.message
        messageItem.title = "Retry Message: \(isDefault ? "Default" : "Custom")"
        soundItem.state = settings.soundEnabled ? .on : .off
        for item in items { item.isEnabled = isReady }
        populate(retryMenu, choices: retryChoices, selected: settings.retrySeconds,
                 defaultValue: store.defaults.retrySeconds, action: #selector(selectRetry(_:)))
        populate(scanMenu, choices: scanChoices, selected: settings.scanSeconds,
                 defaultValue: store.defaults.scanSeconds, action: #selector(selectScan(_:)))
        messageMenu.removeAllItems()
        messageMenu.minimumWidth = 0
        let preview = isDefault ? settings.message.replacingOccurrences(of: ". ", with: ".\n") : settings.message
        for line in previewLines(preview) {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            // Disabled menu titles are dimmed by AppKit even with an attributed
            // color. A static native label keeps the message readable.
            let label = NSTextField(labelWithString: line)
            label.font = .menuFont(ofSize: 0)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityLabel(line)
            let size = label.intrinsicContentSize
            // NSTextField's truncating cell needs a little drawing allowance
            // beyond its intrinsic width to keep short sentences intact.
            let width = min(ceil(size.width) + 8, 320)
            messageMenu.minimumWidth = max(messageMenu.minimumWidth, width + 32)
            let view = NSView(frame: NSRect(x: 0, y: 0, width: width + 32, height: 22))
            label.frame = NSRect(x: 16, y: (22 - ceil(size.height)) / 2,
                                 width: width, height: ceil(size.height))
            label.autoresizingMask = [.width]
            view.addSubview(label)
            item.view = view
            messageMenu.addItem(item)
        }
        messageMenu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit Message…", action: #selector(openMessageEditor(_:)), keyEquivalent: "")
        edit.target = self
        messageMenu.addItem(edit)
        let reset = NSMenuItem(title: "Use Default Message", action: #selector(useDefaultMessage(_:)), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = !isDefault
        messageMenu.addItem(reset)
    }

    private func populate(_ menu: NSMenu, choices: [Int], selected: Int, defaultValue: Int, action: Selector) {
        menu.removeAllItems()
        for value in choices {
            let title = duration(value) + (value == defaultValue ? " (Default)" : "")
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: value)
            item.state = value == selected ? .on : .off
            menu.addItem(item)
        }
        if !choices.contains(selected) {
            menu.addItem(.separator())
            let custom = NSMenuItem(title: "\(duration(selected)) (Custom)", action: action, keyEquivalent: "")
            custom.target = self
            custom.representedObject = NSNumber(value: selected)
            custom.state = .on
            menu.addItem(custom)
        }
    }

    /// Title-style durations with spelled-out units: "15 Seconds", "1 Minute", "1 Hour".
    private func duration(_ seconds: Int) -> String {
        let (count, unit) = seconds % 3600 == 0 ? (seconds / 3600, "Hour")
            : seconds % 60 == 0 ? (seconds / 60, "Minute") : (seconds, "Second")
        return "\(count) \(unit)\(count == 1 ? "" : "s")"
    }

    // Keep menus small even when the saved message spans thousands of characters.
    // Character boundaries preserve composed emoji in the preview.
    private func previewLines(_ message: String) -> [String] {
        var remaining = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        for lineNumber in 0..<2 where !remaining.isEmpty {
            let limit = remaining.index(remaining.startIndex, offsetBy: 48, limitedBy: remaining.endIndex)
                ?? remaining.endIndex
            let newline = remaining.firstIndex(where: { $0.isNewline }) ?? remaining.endIndex
            var end = min(limit, newline)
            if end == limit, end < remaining.endIndex, !remaining[end].isWhitespace,
               let space = remaining[..<end].lastIndex(where: { $0.isWhitespace }),
               remaining.distance(from: remaining.startIndex, to: space) >= 16 {
                end = space
            }
            let line = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            remaining = String(remaining[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(line + (lineNumber == 1 && !remaining.isEmpty ? "…" : ""))
        }
        return lines
    }

    private func update(_ mutate: (inout RetrySettings) -> Void) throws {
        do {
            let saved = try store.update(mutate)
            readError = nil
            writeError = nil
            apply(saved)
            onChange?()
        } catch {
            // A refresh can recover a read failure, but must not hide a failed write.
            writeError = error.localizedDescription
            refresh()
            onChange?()
            throw error
        }
    }

    private func saveMessage(_ message: String) throws {
        try update { $0.message = message }
    }

    @objc private func selectRetry(_ sender: NSMenuItem) {
        guard isReady, let value = sender.representedObject as? NSNumber else { return }
        do { try update { $0.retrySeconds = value.intValue } }
        catch { /* The main menu displays the local write error. */ }
    }

    @objc private func selectScan(_ sender: NSMenuItem) {
        guard isReady, let value = sender.representedObject as? NSNumber else { return }
        do { try update { $0.scanSeconds = value.intValue } }
        catch { /* The main menu displays the local write error. */ }
    }

    @objc private func openMessageEditor(_ sender: NSMenuItem) { editMessage() }

    @objc private func toggleSound(_ sender: NSMenuItem) {
        guard isReady else { return }
        do {
            try update { $0.soundEnabled.toggle() }
            // Turning the sound on plays it once, so the choice is heard at once.
            if soundItem.state == .on { WhipCrack.play() }
        } catch { /* The main menu displays the local write error. */ }
    }

    @objc private func useDefaultMessage(_ sender: NSMenuItem) {
        guard isReady else { return }
        do { try saveMessage(store.defaults.message) }
        catch { /* The main menu displays the local write error. */ }
    }
}

private enum MessageEditorError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Preferences are temporarily unavailable. Try saving again when preparation finishes." }
}

private final class RetryMessageEditor: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onSave: ((String) throws -> Void)?
    var isReady = false {
        didSet { updateControls() }
    }

    private let defaultMessage: String
    private let message = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let defaultButton = NSButton(title: "Use Default", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var originalMessage = ""
    private var feedback: String?
    private var saveError: String?

    init(defaultMessage: String) {
        self.defaultMessage = defaultMessage
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Retry Message"
        window.contentMinSize = NSSize(width: 400, height: 226)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildEditor()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present(message savedMessage: String) {
        if window?.isVisible != true {
            originalMessage = savedMessage
            message.string = savedMessage
            message.undoManager?.removeAllActions()
            message.setSelectedRange(NSRange(location: 0, length: 0))
            message.scrollRangeToVisible(NSRange(location: 0, length: 0))
            feedback = nil
            saveError = nil
            updateControls()
        }
        bringForward()
    }

    func bringForward() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildEditor() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        message.frame = NSRect(x: 0, y: 0, width: 428, height: 124)
        message.isRichText = false
        message.importsGraphics = false
        message.allowsUndo = true
        message.isAutomaticQuoteSubstitutionEnabled = false
        message.isAutomaticDashSubstitutionEnabled = false
        message.isAutomaticTextReplacementEnabled = false
        message.isAutomaticSpellingCorrectionEnabled = false
        message.font = .systemFont(ofSize: NSFont.systemFontSize)
        message.textColor = .textColor
        message.backgroundColor = .textBackgroundColor
        message.textContainerInset = NSSize(width: 8, height: 8)
        message.minSize = NSSize(width: 0, height: 110)
        message.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        message.isVerticallyResizable = true
        message.isHorizontallyResizable = false
        message.autoresizingMask = [.width]
        message.textContainer?.widthTracksTextView = true
        message.setAccessibilityLabel("Retry message")
        message.setAccessibilityHelp("Message sent to continue unfinished work. Press Command Return to save.")
        message.delegate = self
        scroll.documentView = message
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.maximumNumberOfLines = 2
        let buttons = NSView()
        for (button, action) in [(defaultButton, #selector(useDefault)),
                                 (cancelButton, #selector(cancel)), (saveButton, #selector(save))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            buttons.addSubview(button)
        }
        defaultButton.toolTip = "Fill in the default message. Save to apply."
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.toolTip = "Save message (Command Return)"
        for view in [scroll, status, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            status.heightAnchor.constraint(equalToConstant: 34),
            buttons.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttons.heightAnchor.constraint(equalToConstant: 32),
            defaultButton.leadingAnchor.constraint(equalTo: buttons.leadingAnchor),
            defaultButton.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: buttons.trailingAnchor),
            saveButton.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
        message.nextKeyView = defaultButton
        defaultButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = message
        window?.initialFirstResponder = message
        updateControls()
    }

    private var validationError: String? {
        if message.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a retry message."
        }
        if message.string.unicodeScalars.count > 4000 {
            return "Keep the message to 4,000 characters or fewer."
        }
        return nil
    }

    private func updateControls() {
        message.isEditable = true
        defaultButton.isEnabled = message.string != defaultMessage
        saveButton.isEnabled = isReady && validationError == nil && message.string != originalMessage
        let error = saveError ?? validationError
        status.stringValue = error ?? (isReady ? feedback ?? "" : "Preferences are temporarily unavailable.")
        status.textColor = error == nil ? .secondaryLabelColor : .systemRed
        status.toolTip = status.stringValue.isEmpty ? nil : status.stringValue
    }

    func textDidChange(_ notification: Notification) {
        feedback = nil
        saveError = nil
        updateControls()
    }

    @objc private func useDefault() {
        message.string = defaultMessage
        message.undoManager?.removeAllActions()
        feedback = originalMessage == defaultMessage
            ? "Default message is already saved."
            : "Default message filled in. Save to apply."
        saveError = nil
        updateControls()
    }

    @objc private func cancel() { window?.close() }

    override func cancelOperation(_ sender: Any?) { cancel() }

    @objc private func save() {
        guard isReady, validationError == nil, message.string != originalMessage else {
            updateControls()
            return
        }
        do {
            guard let onSave else { throw MessageEditorError.unavailable }
            try onSave(message.string)
            originalMessage = message.string
            window?.close()
        } catch {
            saveError = "Couldn’t save the message. \(error.localizedDescription)"
            updateControls()
        }
    }
}
