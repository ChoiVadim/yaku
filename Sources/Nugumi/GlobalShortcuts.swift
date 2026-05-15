import AppKit
import Carbon.HIToolbox
import Foundation

enum GlobalShortcutAction: String, CaseIterable {
    case translateOrReply
    case translateSelection
    case screenshotArea
    case toggleInvisibility

    var id: UInt32 {
        switch self {
        case .translateOrReply: return 1
        case .translateSelection: return 2
        case .screenshotArea: return 3
        case .toggleInvisibility: return 4
        }
    }

    var defaultsKey: String {
        "globalShortcut.\(rawValue)"
    }

    var menuTitle: String {
        switch self {
        case .translateOrReply: return "Translate selected text"
        case .translateSelection: return "Rewrite my text"
        case .screenshotArea: return "Translate screen area"
        case .toggleInvisibility: return "Toggle invisibility mode"
        }
    }

    var recorderTitle: String {
        "Set \(menuTitle) shortcut"
    }

    var defaultShortcut: GlobalShortcut {
        switch self {
        case .translateOrReply:
            return GlobalShortcut(
                keyCode: UInt32(kVK_ANSI_1),
                modifiers: [.control],
                keyEquivalent: "1",
                keyDisplay: "1"
            )
        case .translateSelection:
            return GlobalShortcut(
                keyCode: UInt32(kVK_ANSI_2),
                modifiers: [.control],
                keyEquivalent: "2",
                keyDisplay: "2"
            )
        case .screenshotArea:
            return GlobalShortcut(
                keyCode: UInt32(kVK_ANSI_3),
                modifiers: [.control],
                keyEquivalent: "3",
                keyDisplay: "3"
            )
        case .toggleInvisibility:
            return GlobalShortcut(
                keyCode: UInt32(kVK_ANSI_Backslash),
                modifiers: [.control, .shift],
                keyEquivalent: "\\",
                keyDisplay: "\\"
            )
        }
    }
}

struct GlobalShortcut: Codable, Equatable {
    static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    let keyCode: UInt32
    private let modifiersRawValue: UInt
    let keyEquivalent: String
    let keyDisplay: String

    init(
        keyCode: UInt32,
        modifiers: NSEvent.ModifierFlags,
        keyEquivalent: String,
        keyDisplay: String
    ) {
        self.keyCode = keyCode
        self.modifiersRawValue = modifiers.intersection(Self.supportedModifiers).rawValue
        self.keyEquivalent = keyEquivalent
        self.keyDisplay = keyDisplay
    }

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.supportedModifiers)
        guard !modifiers.isEmpty else {
            return nil
        }

        let characters = event.charactersIgnoringModifiers
        let keyDisplay = ShortcutKeyFormatter.displayName(
            keyCode: UInt32(event.keyCode),
            characters: characters
        )
        guard !keyDisplay.isEmpty else {
            return nil
        }

        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyEquivalent: ShortcutKeyFormatter.menuEquivalent(
                keyCode: UInt32(event.keyCode),
                characters: characters
            ),
            keyDisplay: keyDisplay
        )
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue).intersection(Self.supportedModifiers)
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) {
            result |= UInt32(controlKey)
        }
        if modifiers.contains(.option) {
            result |= UInt32(optionKey)
        }
        if modifiers.contains(.shift) {
            result |= UInt32(shiftKey)
        }
        if modifiers.contains(.command) {
            result |= UInt32(cmdKey)
        }
        return result
    }

    var menuKeyEquivalent: String {
        keyEquivalent
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        modifiers
    }

    var displayString: String {
        var prefix = ""
        if modifiers.contains(.control) {
            prefix += "⌃"
        }
        if modifiers.contains(.option) {
            prefix += "⌥"
        }
        if modifiers.contains(.shift) {
            prefix += "⇧"
        }
        if modifiers.contains(.command) {
            prefix += "⌘"
        }
        return prefix + keyDisplay
    }

    var isValid: Bool {
        !modifiers.isEmpty && !keyDisplay.isEmpty
    }

    static func == (lhs: GlobalShortcut, rhs: GlobalShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }
}

@MainActor
final class DoubleControlPressDetector {
    private let interval: TimeInterval
    private let onDetected: @MainActor () -> Void
    private var monitor: Any?
    private var lastControlDownDate: Date?
    private var wasControlDown = false
    var isEnabled = true {
        didSet {
            if isEnabled != oldValue {
                resetState()
            }
        }
    }

    init(interval: TimeInterval = 0.30, onDetected: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.onDetected = onDetected
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        resetState()
    }

    private func resetState() {
        lastControlDownDate = nil
        wasControlDown = false
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled else { return }

        let isControlDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
        defer { wasControlDown = isControlDown }
        guard isControlDown, !wasControlDown else { return }

        let now = Date()
        if let last = lastControlDownDate, now.timeIntervalSince(last) <= interval {
            lastControlDownDate = nil
            onDetected()
        } else {
            lastControlDownDate = now
        }
    }
}

enum GlobalShortcutStore {
    static func shortcut(
        for action: GlobalShortcutAction,
        defaults: UserDefaults = .standard
    ) -> GlobalShortcut {
        guard let data = defaults.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data),
              shortcut.isValid
        else {
            return action.defaultShortcut
        }
        return shortcut
    }

    static func set(
        _ shortcut: GlobalShortcut,
        for action: GlobalShortcutAction,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return
        }
        defaults.set(data, forKey: action.defaultsKey)
    }

    static func resetToDefaults(defaults: UserDefaults = .standard) {
        for action in GlobalShortcutAction.allCases {
            defaults.removeObject(forKey: action.defaultsKey)
        }
    }
}

@MainActor
final class ShortcutRecorderWindowController: NSWindowController, NSWindowDelegate {
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 16
    private static let shadowMargin: CGFloat = 30
    private static let cornerRadius: CGFloat = 28
    private static let mascotSize = NSSize(width: 42, height: 34)
    private static let textGap: CGFloat = 10
    private static let cardSize = NSSize(width: 450, height: 176)
    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let messageFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private let action: GlobalShortcutAction
    private let currentShortcut: GlobalShortcut
    private let onShortcut: (GlobalShortcut) -> Bool
    private let onClose: () -> Void
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let recorderView = ShortcutRecorderView()
    private let shortcutField = ShortcutCaptureFieldView()
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private var pendingShortcut: GlobalShortcut?

    init(
        action: GlobalShortcutAction,
        currentShortcut: GlobalShortcut,
        onShortcut: @escaping (GlobalShortcut) -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.action = action
        self.currentShortcut = currentShortcut
        self.onShortcut = onShortcut
        self.onClose = onClose

        let windowSize = NSSize(
            width: Self.cardSize.width + Self.shadowMargin * 2,
            height: Self.cardSize.height + Self.shadowMargin * 2
        )
        let panel = ShortcutRecorderPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        panel.delegate = self
        buildUI(in: panel, windowSize: windowSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        guard let window else {
            return
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(recorderView)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.onClose()
        }
    }

    private func buildUI(in panel: NSPanel, windowSize: NSSize) {
        let rootView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false
        panel.contentView = rootView

        let glass = GlassHostView(
            frame: NSRect(
                origin: NSPoint(x: Self.shadowMargin, y: Self.shadowMargin),
                size: Self.cardSize
            ),
            cornerRadius: Self.cornerRadius,
            tintColor: nil,
            style: .regular
        )
        glass.wantsLayer = true
        glass.layer?.masksToBounds = false
        glass.layer?.shadowColor = NSColor.black.cgColor
        glass.layer?.shadowOpacity = 0.24
        glass.layer?.shadowRadius = 18
        glass.layer?.shadowOffset = CGSize(width: 0, height: -4)
        glass.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: Self.cardSize),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(glass)
        let contentView = glass.contentView

        recorderView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(recorderView)

        let mascotColumn = NSView()
        mascotColumn.translatesAutoresizingMaskIntoConstraints = false

        let mascotView = PetMascotView(frame: NSRect(origin: .zero, size: Self.mascotSize))
        mascotView.apply(state: .idle, mode: .selection)
        mascotView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Set shortcut")
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        recorderView.onShortcut = { [weak self] shortcut in
            self?.capture(shortcut)
            return true
        }
        recorderView.onCancel = { [weak self] in
            self?.close()
        }
        recorderView.onInvalidShortcut = { [weak self] message in
            self?.messageLabel.stringValue = message
        }

        messageLabel.stringValue = "Click the field and press new keys for \(action.menuTitle)."
        messageLabel.font = Self.messageFont
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = textWidth
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutField.placeholder = "Click here, then press keys"
        shortcutField.shortcutText = currentShortcut.displayString
        shortcutField.onClick = { [weak self] in
            guard let self else { return }
            self.pendingShortcut = nil
            self.okButton.isEnabled = false
            self.messageLabel.stringValue = "Press the new shortcut now."
            self.shortcutField.placeholder = "Press shortcut now"
            self.shortcutField.shortcutText = nil
            self.window?.makeFirstResponder(self.recorderView)
        }
        shortcutField.translatesAutoresizingMaskIntoConstraints = false

        okButton.target = self
        okButton.action = #selector(okTapped)
        okButton.bezelStyle = .rounded
        okButton.controlSize = .regular
        okButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        okButton.focusRingType = .none
        okButton.isEnabled = false
        okButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(mascotColumn)
        mascotColumn.addSubview(mascotView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(messageLabel)
        contentView.addSubview(shortcutField)
        contentView.addSubview(okButton)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.shadowMargin),
            glass.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Self.shadowMargin),
            glass.widthAnchor.constraint(equalToConstant: Self.cardSize.width),
            glass.heightAnchor.constraint(equalToConstant: Self.cardSize.height),

            recorderView.topAnchor.constraint(equalTo: contentView.topAnchor),
            recorderView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            recorderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            recorderView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            mascotColumn.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding),
            mascotColumn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.horizontalPadding),
            mascotColumn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalPadding),
            mascotColumn.widthAnchor.constraint(equalToConstant: Self.mascotSize.width),

            mascotView.centerXAnchor.constraint(equalTo: mascotColumn.centerXAnchor),
            mascotView.centerYAnchor.constraint(equalTo: mascotColumn.centerYAnchor),
            mascotView.widthAnchor.constraint(equalToConstant: Self.mascotSize.width),
            mascotView.heightAnchor.constraint(equalToConstant: Self.mascotSize.height),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding + 1),
            titleLabel.leadingAnchor.constraint(equalTo: mascotColumn.trailingAnchor, constant: Self.textGap),
            titleLabel.widthAnchor.constraint(equalToConstant: textWidth),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            shortcutField.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 10),
            shortcutField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            shortcutField.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            shortcutField.heightAnchor.constraint(equalToConstant: 42),

            okButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            okButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            okButton.heightAnchor.constraint(equalToConstant: 30),
            okButton.topAnchor.constraint(equalTo: shortcutField.bottomAnchor, constant: 10),
            okButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -Self.verticalPadding)
        ])
    }

    private func capture(_ shortcut: GlobalShortcut) {
        pendingShortcut = shortcut
        shortcutField.shortcutText = shortcut.displayString
        messageLabel.stringValue = "Press OK to save this shortcut."
        okButton.isEnabled = true
    }

    @objc private func okTapped() {
        guard let pendingShortcut else {
            NSSound.beep()
            return
        }

        if onShortcut(pendingShortcut) {
            close()
            return
        }

        messageLabel.stringValue = "This shortcut is already used. Press another one."
        shortcutField.showConflict()
        okButton.isEnabled = false
        self.pendingShortcut = nil
    }

    private var textWidth: CGFloat {
        Self.cardSize.width
            - Self.horizontalPadding
            - Self.mascotSize.width
            - Self.textGap
            - Self.horizontalPadding
    }
}

@MainActor
private final class ShortcutRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class ShortcutCaptureFieldView: NSView {
    var onClick: (() -> Void)?

    var placeholder: String = "" {
        didSet {
            if shortcutText == nil {
                label.stringValue = placeholder
            }
        }
    }

    var shortcutText: String? {
        didSet {
            if let shortcutText {
                label.font = NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
                label.stringValue = shortcutText
                label.textColor = .labelColor
                setBorderColor(NSColor.controlAccentColor.withAlphaComponent(0.85))
            } else {
                label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
                label.stringValue = placeholder
                label.textColor = .secondaryLabelColor
                setBorderColor(NSColor.separatorColor)
            }
        }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor
        setBorderColor(NSColor.separatorColor)

        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    func showConflict() {
        shortcutText = nil
        label.stringValue = "Press another shortcut"
        label.textColor = .secondaryLabelColor
        setBorderColor(NSColor.systemRed.withAlphaComponent(0.85))
    }

    private func setBorderColor(_ color: NSColor) {
        layer?.borderColor = color.cgColor
    }
}

@MainActor
private final class ShortcutRecorderView: NSView {
    var onShortcut: ((GlobalShortcut) -> Bool)?
    var onCancel: (() -> Void)?
    var onInvalidShortcut: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }

        guard let shortcut = GlobalShortcut(event: event) else {
            NSSound.beep()
            onInvalidShortcut?("Use at least one modifier: Control, Option, Shift, or Command.")
            return
        }

        if onShortcut?(shortcut) != true {
            NSSound.beep()
        }
    }
}

private enum ShortcutKeyFormatter {
    static func displayName(keyCode: UInt32, characters: String?) -> String {
        if let name = displayNames[keyCode] {
            return name
        }

        guard let characters, !characters.isEmpty else {
            return ""
        }

        return characters.uppercased()
    }

    static func menuEquivalent(keyCode: UInt32, characters: String?) -> String {
        if let equivalent = menuEquivalents[keyCode] {
            return equivalent
        }

        return characters?.lowercased() ?? ""
    }

    private static let displayNames: [UInt32: String] = [
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Command): "Command",
        UInt32(kVK_Shift): "Shift",
        UInt32(kVK_CapsLock): "Caps Lock",
        UInt32(kVK_Option): "Option",
        UInt32(kVK_Control): "Control",
        UInt32(kVK_RightCommand): "Command",
        UInt32(kVK_RightShift): "Shift",
        UInt32(kVK_RightOption): "Option",
        UInt32(kVK_RightControl): "Control",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_UpArrow): "↑"
    ]

    private static let menuEquivalents: [UInt32: String] = [
        UInt32(kVK_Return): "\r",
        UInt32(kVK_Tab): "\t",
        UInt32(kVK_Space): " ",
        UInt32(kVK_Delete): "\u{8}",
        UInt32(kVK_Escape): "\u{1B}",
        UInt32(kVK_LeftArrow): String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        UInt32(kVK_RightArrow): String(UnicodeScalar(NSRightArrowFunctionKey)!),
        UInt32(kVK_DownArrow): String(UnicodeScalar(NSDownArrowFunctionKey)!),
        UInt32(kVK_UpArrow): String(UnicodeScalar(NSUpArrowFunctionKey)!)
    ]
}
