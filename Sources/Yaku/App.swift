import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Vision

private enum MenuItemTag: Int {
    case permissionNotice = 100
    case accessibilitySettings = 101
    case permissionSeparator = 102
    case targetLanguage = 103
    case quit = 104
    case bootstrapNotice = 105
    case bootstrapAction = 106
    case bootstrapSeparator = 107
    case screenshotArea = 108
    case translateSelection = 109
    case draftTargetLanguage = 110
}

private struct GlobalHotKeyDefinition {
    static let signature = OSType(0x54524E53) // TRNS
    private static let fnModifier = UInt32(kEventKeyModifierFnMask)

    let id: UInt32
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let requiredModifierFlags: NSEvent.ModifierFlags
    let forbiddenModifierFlags: NSEvent.ModifierFlags
    let displayString: String

    static let screenshotArea = GlobalHotKeyDefinition(
        id: 1,
        keyCode: UInt32(kVK_ANSI_S),
        carbonModifiers: UInt32(cmdKey | controlKey),
        requiredModifierFlags: [.command, .control],
        forbiddenModifierFlags: [.option, .shift],
        displayString: "⌃⌘S"
    )

    static let screenshotAreaFn = GlobalHotKeyDefinition(
        id: 3,
        keyCode: UInt32(kVK_ANSI_S),
        carbonModifiers: fnModifier,
        requiredModifierFlags: [.function],
        forbiddenModifierFlags: [.command, .control, .option, .shift],
        displayString: "fn+S"
    )

    static let translateSelection = GlobalHotKeyDefinition(
        id: 2,
        keyCode: UInt32(kVK_ANSI_T),
        carbonModifiers: UInt32(cmdKey | controlKey),
        requiredModifierFlags: [.command, .control],
        forbiddenModifierFlags: [.option, .shift],
        displayString: "⌃⌘T"
    )

    static let translateSelectionFn = GlobalHotKeyDefinition(
        id: 4,
        keyCode: UInt32(kVK_ANSI_T),
        carbonModifiers: fnModifier,
        requiredModifierFlags: [.function],
        forbiddenModifierFlags: [.command, .control, .option, .shift],
        displayString: "fn+T"
    )

    static let screenshotAreaDisplayString = "\(screenshotArea.displayString) or \(screenshotAreaFn.displayString)"
    static let translateSelectionDisplayString = "\(translateSelection.displayString) or \(translateSelectionFn.displayString)"
}

private final class GlobalHotKey {
    private let definition: GlobalHotKeyDefinition

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var fallbackMonitor: Any?
    private let onPressed: @MainActor () -> Void

    init(definition: GlobalHotKeyDefinition, onPressed: @escaping @MainActor () -> Void) {
        self.definition = definition
        self.onPressed = onPressed
    }

    func register() {
        unregister()

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                let registrar = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard parameterStatus == noErr,
                      hotKeyID.signature == GlobalHotKeyDefinition.signature,
                      hotKeyID.id == registrar.definition.id
                else {
                    return OSStatus(eventNotHandledErr)
                }

                Task { @MainActor in
                    registrar.onPressed()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPointer,
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            installFallbackMonitor()
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: GlobalHotKeyDefinition.signature,
            id: definition.id
        )
        let hotKeyStatus = RegisterEventHotKey(
            definition.keyCode,
            definition.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard hotKeyStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            installFallbackMonitor()
            return
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
            self.fallbackMonitor = nil
        }
    }

    private func installFallbackMonitor() {
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard self.matches(event) else {
                return
            }

            Task { @MainActor in
                self.onPressed()
            }
        }
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(definition.keyCode) else {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return definition.requiredModifierFlags.isSubset(of: modifiers)
            && modifiers.intersection(definition.forbiddenModifierFlags).isEmpty
    }
}

struct TranslationLanguage: Equatable {
    let id: String
    let displayName: String
    let promptName: String

    static let all: [TranslationLanguage] = [
        .init(id: "ru", displayName: "Russian", promptName: "Russian"),
        .init(id: "en", displayName: "English", promptName: "English"),
        .init(id: "ko", displayName: "Korean", promptName: "Korean"),
        .init(id: "ja", displayName: "Japanese", promptName: "Japanese"),
        .init(id: "zh-Hans", displayName: "Chinese Simplified", promptName: "Simplified Chinese"),
        .init(id: "es", displayName: "Spanish", promptName: "Spanish"),
        .init(id: "fr", displayName: "French", promptName: "French"),
        .init(id: "de", displayName: "German", promptName: "German")
    ]

    static let defaultLanguage = all[0]
    static let defaultDraftLanguage = all.first { $0.id == "ko" } ?? defaultLanguage

    static func language(id: String) -> TranslationLanguage {
        all.first { $0.id == id } ?? defaultLanguage
    }
}

private enum TextNormalizer {
    static func cleanedSelection(_ text: String) -> String {
        var cleaned = normalizedBaseText(text)

        cleaned = cleaned.replacingOccurrences(
            of: #"(?<=\p{L})-\n(?=\p{L})"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?<=[.!?。！？])\s*(?=[▶•●▪▸])"#,
            with: "\n",
            options: .regularExpression
        )
        return cleanedStructuredSource(cleaned)
    }

    static func cleanedTranslation(_ text: String) -> String {
        var cleaned = normalizedBaseText(text)

        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n[ \t]+"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([,.;:!?…])"#,
            with: "$1",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanedDraftMessage(_ text: String) -> String {
        var cleaned = normalizedBaseText(text)

        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n[ \t]+"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n{4,}"#,
            with: "\n\n\n",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedBaseText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
    }

    private static func cleanedStructuredSource(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var resultLines: [String] = []
        var currentLine = ""

        func flushCurrentLine() {
            guard !currentLine.isEmpty else { return }
            resultLines.append(currentLine)
            currentLine = ""
        }

        for rawLine in lines {
            let line = cleanedInlineText(rawLine)
            if line.isEmpty {
                flushCurrentLine()
                if resultLines.last != "" {
                    resultLines.append("")
                }
                continue
            }

            if isStructuralLine(line) {
                flushCurrentLine()
                currentLine = line
                continue
            }

            if currentLine.isEmpty {
                currentLine = line
            } else {
                currentLine += joiningTextBetween(currentLine, and: line) + line
            }
        }

        flushCurrentLine()

        while resultLines.last == "" {
            resultLines.removeLast()
        }

        return resultLines
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedInlineText(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([,.;:!?…])"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"([(])\s+"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([)])"#,
            with: "$1",
            options: .regularExpression
        )
        return cleaned
    }

    private static func isStructuralLine(_ text: String) -> Bool {
        text.range(
            of: #"^\s*(?:[▶•●▪▸◆◇○◦\-–—*]|\d+[.)]|[A-Za-z][.)])\s*"#,
            options: .regularExpression
        ) != nil
    }

    private static func joiningTextBetween(_ left: String, and right: String) -> String {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else {
            return " "
        }

        let noSpaceBefore = CharacterSet(charactersIn: ",.;:!?…)]}）】」』")
        let noSpaceAfter = CharacterSet(charactersIn: "([{（【「『")
        if noSpaceBefore.contains(first) || noSpaceAfter.contains(last) {
            return ""
        }

        return " "
    }
}

@MainActor
private final class TranslationPrefetch {
    private enum State {
        case pending
        case running
        case completed(String)
        case failed(String)
        case cancelled
    }

    let text: String
    let targetLanguage: TranslationLanguage
    private let ollamaClient: OllamaClient
    private var task: Task<Void, Never>?
    private var state: State = .pending
    private var partialTranslation = ""
    private var subscribers: [(String) -> Void] = []
    private var failureSubscribers: [(String) -> Void] = []
    private let onComplete: (String, TranslationLanguage, String) -> Void

    init(
        text: String,
        targetLanguage: TranslationLanguage,
        ollamaClient: OllamaClient,
        onComplete: @escaping (String, TranslationLanguage, String) -> Void
    ) {
        self.text = text
        self.targetLanguage = targetLanguage
        self.ollamaClient = ollamaClient
        self.onComplete = onComplete
    }

    func startAfterDelay(milliseconds: UInt64) {
        guard task == nil else { return }

        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
                try Task.checkCancellation()
                await self?.start()
            } catch {
                self?.markCancelled()
            }
        }
    }

    func subscribe(onPartial: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        if !partialTranslation.isEmpty {
            onPartial(partialTranslation)
        }

        switch state {
        case .completed(let translation):
            onPartial(translation)
        case .failed(let message):
            onFailure(message)
        default:
            subscribers.append(onPartial)
            failureSubscribers.append(onFailure)
        }
    }

    func ensureStartedNow() {
        switch state {
        case .pending:
            task?.cancel()
            task = Task { [weak self] in
                await self?.start()
            }
        default:
            break
        }
    }

    func cancel() {
        task?.cancel()
        state = .cancelled
        subscribers.removeAll()
        failureSubscribers.removeAll()
    }

    private func start() async {
        guard case .pending = state else { return }
        state = .running

        do {
            let finalTranslation = try await ollamaClient.translate(text, to: targetLanguage) { [weak self] partial in
                Task { @MainActor in
                    self?.publishPartial(partial)
                }
            }
            state = .completed(finalTranslation)
            onComplete(text, targetLanguage, finalTranslation)
            publishPartial(finalTranslation)
        } catch is CancellationError {
            markCancelled()
        } catch {
            let message = error.localizedDescription
            state = .failed(message)
            failureSubscribers.forEach { $0(message) }
            subscribers.removeAll()
            failureSubscribers.removeAll()
        }
    }

    private func publishPartial(_ partial: String) {
        partialTranslation = partial
        subscribers.forEach { $0(partial) }
    }

    private func markCancelled() {
        state = .cancelled
        subscribers.removeAll()
        failureSubscribers.removeAll()
    }
}

private final class TranslationCache {
    private let maxEntries: Int
    private var entries: [String: String] = [:]
    private var keysByRecentUse: [String] = []

    init(maxEntries: Int = 200) {
        self.maxEntries = maxEntries
    }

    func translation(for text: String, targetLanguage: TranslationLanguage) -> String? {
        let key = cacheKey(for: text, targetLanguage: targetLanguage)
        guard let translation = entries[key] else {
            return nil
        }

        markRecentlyUsed(key)
        return translation
    }

    func store(_ translation: String, for text: String, targetLanguage: TranslationLanguage) {
        let key = cacheKey(for: text, targetLanguage: targetLanguage)
        guard !key.isEmpty, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        entries[key] = translation
        markRecentlyUsed(key)
        trimIfNeeded()
    }

    private func cacheKey(for text: String, targetLanguage: TranslationLanguage) -> String {
        "\(targetLanguage.id):\(TextNormalizer.cleanedSelection(text))"
    }

    private func markRecentlyUsed(_ key: String) {
        keysByRecentUse.removeAll { $0 == key }
        keysByRecentUse.append(key)
    }

    private func trimIfNeeded() {
        while keysByRecentUse.count > maxEntries, let oldestKey = keysByRecentUse.first {
            keysByRecentUse.removeFirst()
            entries.removeValue(forKey: oldestKey)
        }
    }
}

@main
@MainActor
final class YakuApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mouseMonitor: Any?
    private var lastLeftMouseDownLocation: NSPoint?
    private let selectionReader = SelectionReader()
    private let ollamaClient = OllamaClient(
        baseURL: URL(string: "http://127.0.0.1:11434")!,
        model: "gpt-oss:120b-cloud"
    )

    private var translateButtonController: FloatingTranslateButtonController?
    private var translationPanelController: TranslationPanelController?
    private var translationPrefetch: TranslationPrefetch?
    private var isScreenshotTranslationRunning = false
    private var globalHotKeys: [GlobalHotKey] = []
    private lazy var translationCache = TranslationCache()
    private lazy var bootstrap: OllamaBootstrap = OllamaBootstrap(
        baseURL: ollamaClient.baseURL,
        model: ollamaClient.model
    )
    private var onboardingWindowController: OnboardingWindowController?
    private var targetLanguage: TranslationLanguage {
        get {
            TranslationLanguage.language(
                id: UserDefaults.standard.string(forKey: "targetLanguageID") ?? TranslationLanguage.defaultLanguage.id
            )
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "targetLanguageID")
        }
    }
    private var draftTargetLanguage: TranslationLanguage {
        get {
            TranslationLanguage.language(
                id: UserDefaults.standard.string(forKey: "draftTargetLanguageID") ?? TranslationLanguage.defaultDraftLanguage.id
            )
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "draftTargetLanguageID")
        }
    }

    private let prefetchDelayMilliseconds: UInt64 = 220
    private let prefetchMaxCharacterCount = 1_200

    static func main() {
        let app = NSApplication.shared
        let delegate = YakuApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        requestAccessibilityPermissionIfNeeded()
        startMouseMonitor()
        setupGlobalHotKeys()
        setupBootstrap()
    }

    private func setupGlobalHotKeys() {
        let screenshotHotKey = GlobalHotKey(definition: .screenshotArea) { [weak self] in
            self?.startScreenshotTranslation()
        }
        let screenshotFnHotKey = GlobalHotKey(definition: .screenshotAreaFn) { [weak self] in
            self?.startScreenshotTranslation()
        }
        let translateSelectionHotKey = GlobalHotKey(definition: .translateSelection) { [weak self] in
            self?.startSelectedTextTranslationForReplacement()
        }
        let translateSelectionFnHotKey = GlobalHotKey(definition: .translateSelectionFn) { [weak self] in
            self?.startSelectedTextTranslationForReplacement()
        }
        globalHotKeys = [
            screenshotHotKey,
            screenshotFnHotKey,
            translateSelectionHotKey,
            translateSelectionFnHotKey
        ]
        globalHotKeys.forEach { $0.register() }
    }

    private func setupBootstrap() {
        bootstrap.onChange = { [weak self] state in
            self?.handleBootstrapStateChange(state)
        }
        bootstrap.refresh()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            if !self.bootstrap.state.isReady {
                self.presentOnboardingWindow()
            }
        }
    }

    @MainActor
    private func handleBootstrapStateChange(_ state: BootstrapState) {
        updateMenuState()
    }

    @MainActor
    private func presentOnboardingWindow() {
        if let onboardingWindowController {
            onboardingWindowController.presentAndRefresh()
            return
        }
        let controller = OnboardingWindowController(bootstrap: bootstrap) { [weak self] in
            self?.onboardingWindowController = nil
        }
        onboardingWindowController = controller
        controller.presentAndRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        globalHotKeys.forEach { $0.unregister() }
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.length = 24
        if let button = statusItem.button {
            button.title = ""
            button.image = makeStatusBarIcon()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "Yaku"
        }

        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(makeMenuItem(
            title: "Accessibility permission required",
            tag: .permissionNotice,
            symbolName: "exclamationmark.triangle",
            isEnabled: false
        ))
        menu.addItem(makeMenuItem(
            title: "Open Accessibility Settings...",
            tag: .accessibilitySettings,
            symbolName: "gearshape",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        ))

        let permissionSeparator = NSMenuItem.separator()
        permissionSeparator.tag = MenuItemTag.permissionSeparator.rawValue
        menu.addItem(permissionSeparator)

        menu.addItem(makeMenuItem(
            title: "Ollama setup needed",
            tag: .bootstrapNotice,
            symbolName: "bolt.badge.clock",
            isEnabled: false
        ))
        menu.addItem(makeMenuItem(
            title: "Open Setup...",
            tag: .bootstrapAction,
            symbolName: "wrench.and.screwdriver",
            action: #selector(openOnboardingWindow),
            keyEquivalent: ""
        ))

        let bootstrapSeparator = NSMenuItem.separator()
        bootstrapSeparator.tag = MenuItemTag.bootstrapSeparator.rawValue
        menu.addItem(bootstrapSeparator)

        menu.addItem(makeMenuItem(
            title: "Translate My Text...",
            tag: .translateSelection,
            symbolName: "text.insert",
            action: #selector(translateSelectedTextFromMenu),
            keyEquivalent: "t",
            keyEquivalentModifierMask: [.control, .command]
        ))

        menu.addItem(makeMenuItem(
            title: "Translate Screen Area...",
            tag: .screenshotArea,
            symbolName: "viewfinder",
            action: #selector(translateScreenshotAreaFromMenu),
            keyEquivalent: "s",
            keyEquivalentModifierMask: [.control, .command]
        ))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(makeMenuItem(
            title: "",
            tag: .targetLanguage,
            symbolName: "globe",
            submenu: makeTargetLanguageMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .draftTargetLanguage,
            symbolName: "text.bubble",
            submenu: makeDraftTargetLanguageMenu()
        ))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(
            title: "Quit",
            tag: .quit,
            symbolName: "power",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
        self.statusItem = statusItem
        updateMenuState()
    }

    private func makeMenuItem(
        title: String,
        tag: MenuItemTag,
        symbolName: String? = nil,
        action: Selector? = nil,
        keyEquivalent: String = "",
        keyEquivalentModifierMask: NSEvent.ModifierFlags = .command,
        isEnabled: Bool = true,
        submenu: NSMenu? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.tag = tag.rawValue
        item.isEnabled = isEnabled
        item.keyEquivalentModifierMask = keyEquivalentModifierMask
        item.submenu = submenu
        if action != nil {
            item.target = self
        }
        if let symbolName {
            item.image = menuSymbol(symbolName)
        }
        return item
    }

    private func menuSymbol(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }

        image.isTemplate = true
        return image
    }

    private func makeStatusBarIcon() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        let backgroundDiameter: CGFloat = 18.5
        let backgroundOrigin = (size.width - backgroundDiameter) / 2
        let backgroundRect = NSRect(
            x: backgroundOrigin,
            y: backgroundOrigin,
            width: backgroundDiameter,
            height: backgroundDiameter
        )
        NSColor(calibratedWhite: 0.12, alpha: 0.92).setFill()
        NSBezierPath(ovalIn: backgroundRect).fill()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
        ("あ" as NSString).draw(
            in: NSRect(x: 0, y: 3.25, width: size.width, height: 16),
            withAttributes: attributes
        )

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func makeTargetLanguageMenu() -> NSMenu {
        let menu = NSMenu()
        for language in TranslationLanguage.all {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(selectTargetLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.id
            menu.addItem(item)
        }
        return menu
    }

    private func makeDraftTargetLanguageMenu() -> NSMenu {
        let menu = NSMenu()
        for language in TranslationLanguage.all {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(selectDraftTargetLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.id
            menu.addItem(item)
        }
        return menu
    }

    private func startMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown {
                self.lastLeftMouseDownLocation = NSEvent.mouseLocation
                return
            }

            self.handleMouseUp(event)
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard accessibilityIsTrusted() else {
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        if let controller = translationPanelController,
           controller.isVisible,
           controller.panelFrame.insetBy(dx: -4, dy: -4).contains(mouseLocation) {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            let allowClipboardFallback = self.shouldAttemptClipboardSelectionFallback(for: event)

            self.selectionReader.readSelectedText(allowClipboardFallback: allowClipboardFallback) { [weak self] selectedText in
                guard let self else { return }

                guard let selectedText, !selectedText.isEmpty else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.cancelPrefetch()
                    return
                }

                let cleanedSelection = TextNormalizer.cleanedSelection(selectedText)
                guard !cleanedSelection.isEmpty else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.cancelPrefetch()
                    return
                }

                self.showTranslateButton(for: cleanedSelection, near: NSEvent.mouseLocation)
            }
        }
    }

    private func shouldAttemptClipboardSelectionFallback(for event: NSEvent) -> Bool {
        guard event.type == .leftMouseUp else {
            return false
        }

        let isSelectionGesture: Bool
        if event.clickCount >= 2 {
            isSelectionGesture = true
        } else if let downLocation = lastLeftMouseDownLocation {
            let upLocation = NSEvent.mouseLocation
            let distance = hypot(upLocation.x - downLocation.x, upLocation.y - downLocation.y)
            isSelectionGesture = distance >= 5
        } else {
            isSelectionGesture = false
        }

        guard isSelectionGesture else {
            return false
        }

        return !selectionReader.isLikelyEditableElementAtMouseLocation()
    }

    @MainActor
    private func showTranslateButton(for selectedText: String, near screenPoint: NSPoint) {
        translationPanelController?.close()
        translateButtonController?.close()
        let language = targetLanguage
        if translationCache.translation(for: selectedText, targetLanguage: language) == nil {
            startPrefetchIfEligible(for: selectedText)
        } else {
            cancelPrefetch()
        }

        let controller = FloatingTranslateButtonController(
            screenPoint: screenPoint,
            selectedText: selectedText
        ) { [weak self] text in
            self?.translateButtonController?.close()
            self?.translateButtonController = nil
            self?.translate(text, near: screenPoint)
        }

        translateButtonController = controller
        controller.show()
    }

    @MainActor
    private func translate(
        _ text: String,
        near screenPoint: NSPoint,
        targetLanguage explicitTargetLanguage: TranslationLanguage? = nil,
        mode: TranslationMode = .selection,
        useCache: Bool = true,
        onReplace: ((String) -> Void)? = nil
    ) {
        let language = explicitTargetLanguage ?? targetLanguage
        let controller = TranslationPanelController(
            screenPoint: screenPoint,
            sourceText: text,
            targetLanguage: language,
            onReplace: onReplace
        )
        translationPanelController?.close()
        translationPanelController = controller
        controller.showLoading()

        if useCache, let cachedTranslation = translationCache.translation(for: text, targetLanguage: language) {
            controller.showTranslation(cachedTranslation)
            return
        }

        if useCache,
           let translationPrefetch,
           translationPrefetch.text == text,
           translationPrefetch.targetLanguage == language {
            translationPrefetch.subscribe { partialTranslation in
                controller.showTranslation(partialTranslation)
            } onFailure: { message in
                controller.showError(message)
            }
            translationPrefetch.ensureStartedNow()
            return
        }

        Task {
            do {
                let translated = try await ollamaClient.translate(text, to: language, mode: mode) { partialTranslation in
                    Task { @MainActor in
                        controller.showTranslation(partialTranslation)
                    }
                }
                await MainActor.run {
                    if useCache {
                        self.translationCache.store(translated, for: text, targetLanguage: language)
                    }
                    controller.showTranslation(translated)
                }
            } catch {
                await MainActor.run {
                    controller.showError(error.localizedDescription)
                    self.handleTranslationFailure(error)
                }
            }
        }
    }

    @MainActor
    private func handleTranslationFailure(_ error: Error) {
        guard let translationError = error as? TranslationError else { return }
        switch translationError {
        case .serverUnavailable, .modelMissing, .signInRequired:
            bootstrap.refresh()
            presentOnboardingWindow()
        case .ollama, .emptyResponse:
            break
        }
    }

    @MainActor
    private func startPrefetchIfEligible(for text: String) {
        cancelPrefetch()

        guard text.count <= prefetchMaxCharacterCount else {
            return
        }

        let language = targetLanguage
        let prefetch = TranslationPrefetch(
            text: text,
            targetLanguage: language,
            ollamaClient: ollamaClient
        ) { [weak self] sourceText, targetLanguage, translation in
            self?.translationCache.store(translation, for: sourceText, targetLanguage: targetLanguage)
        }
        translationPrefetch = prefetch
        prefetch.startAfterDelay(milliseconds: prefetchDelayMilliseconds)
    }

    @MainActor
    private func cancelPrefetch() {
        translationPrefetch?.cancel()
        translationPrefetch = nil
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard !accessibilityIsTrusted() else {
            return
        }

        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func accessibilityIsTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func updateMenuState() {
        guard let menu = statusItem?.menu else {
            return
        }

        let trusted = accessibilityIsTrusted()
        menu.item(withTag: MenuItemTag.permissionNotice.rawValue)?.isHidden = trusted
        menu.item(withTag: MenuItemTag.accessibilitySettings.rawValue)?.isHidden = trusted
        menu.item(withTag: MenuItemTag.permissionSeparator.rawValue)?.isHidden = trusted

        let bootstrapReady = bootstrap.state.isReady
        menu.item(withTag: MenuItemTag.bootstrapNotice.rawValue)?.isHidden = bootstrapReady
        menu.item(withTag: MenuItemTag.bootstrapAction.rawValue)?.title = bootstrapReady
            ? "Ollama Setup..."
            : "Open Setup..."
        menu.item(withTag: MenuItemTag.bootstrapSeparator.rawValue)?.isHidden = bootstrapReady
        menu.item(withTag: MenuItemTag.targetLanguage.rawValue)?.title = "Read translations: \(targetLanguage.displayName)"
        menu.item(withTag: MenuItemTag.draftTargetLanguage.rawValue)?.title = "Write messages in \(draftTargetLanguage.displayName)"
        if let translateSelectionItem = menu.item(withTag: MenuItemTag.translateSelection.rawValue) {
            translateSelectionItem.title = "Translate My Text to \(draftTargetLanguage.displayName)..."
            translateSelectionItem.isEnabled = trusted
        }
        if let screenshotItem = menu.item(withTag: MenuItemTag.screenshotArea.rawValue) {
            screenshotItem.title = isScreenshotTranslationRunning
                ? "Selecting Screen Area..."
                : "Translate Screen Area..."
            screenshotItem.isEnabled = !isScreenshotTranslationRunning
        }

        if let languageMenu = menu.item(withTag: MenuItemTag.targetLanguage.rawValue)?.submenu {
            for item in languageMenu.items {
                guard let languageID = item.representedObject as? String else { continue }
                item.state = languageID == targetLanguage.id ? .on : .off
            }
        }

        if let draftLanguageMenu = menu.item(withTag: MenuItemTag.draftTargetLanguage.rawValue)?.submenu {
            for item in draftLanguageMenu.items {
                guard let languageID = item.representedObject as? String else { continue }
                item.state = languageID == draftTargetLanguage.id ? .on : .off
            }
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @MainActor
    @objc private func openOnboardingWindow() {
        presentOnboardingWindow()
    }

    @MainActor
    @objc private func translateScreenshotAreaFromMenu() {
        startScreenshotTranslation()
    }

    @MainActor
    @objc private func translateSelectedTextFromMenu() {
        startSelectedTextTranslationForReplacement()
    }

    @MainActor
    private func startSelectedTextTranslationForReplacement() {
        guard accessibilityIsTrusted() else {
            requestAccessibilityPermissionIfNeeded()
            return
        }

        translateButtonController?.close()
        translateButtonController = nil
        cancelPrefetch()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }

            self.selectionReader.readSelectedText(allowClipboardFallback: true) { [weak self] selectedText in
                guard let self else { return }

                guard let selectedText else {
                    self.presentSelectionTranslationError("Select text first, then press \(GlobalHotKeyDefinition.translateSelectionDisplayString).")
                    return
                }

                let cleanedDraft = TextNormalizer.cleanedDraftMessage(selectedText)
                guard !cleanedDraft.isEmpty else {
                    self.presentSelectionTranslationError("Select text first, then press \(GlobalHotKeyDefinition.translateSelectionDisplayString).")
                    return
                }

                let language = self.draftTargetLanguage
                self.translate(
                    cleanedDraft,
                    near: NSEvent.mouseLocation,
                    targetLanguage: language,
                    mode: .draftMessage,
                    useCache: false
                ) { [weak self] translation in
                    self?.replaceCurrentSelection(with: translation)
                }
            }
        }
    }

    @MainActor
    private func replaceCurrentSelection(with translation: String) {
        let cleanTranslation = TextNormalizer.cleanedTranslation(translation)
        guard !cleanTranslation.isEmpty else {
            return
        }

        PasteboardTextInserter.replaceCurrentSelection(with: cleanTranslation)
        translationPanelController?.close()
        translationPanelController = nil
    }

    @MainActor
    private func startScreenshotTranslation() {
        guard !isScreenshotTranslationRunning else {
            return
        }

        isScreenshotTranslationRunning = true
        updateMenuState()
        translateButtonController?.close()
        translateButtonController = nil
        translationPanelController?.close()
        translationPanelController = nil
        cancelPrefetch()

        Task { [weak self] in
            do {
                let screenshotURL = try await ScreenshotCapture.captureInteractiveArea()
                defer {
                    try? FileManager.default.removeItem(at: screenshotURL)
                }

                let recognizedText = try await ImageTextRecognizer.recognizeText(in: screenshotURL)
                await MainActor.run {
                    guard let self else { return }
                    self.isScreenshotTranslationRunning = false
                    self.updateMenuState()

                    let sourceText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !TextNormalizer.cleanedSelection(sourceText).isEmpty else {
                        self.presentScreenshotTranslationError(ScreenshotTranslationError.noTextRecognized)
                        return
                    }

                    self.translate(sourceText, near: NSEvent.mouseLocation)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isScreenshotTranslationRunning = false
                    self.updateMenuState()
                    guard !ScreenshotTranslationError.isCancellation(error) else {
                        return
                    }
                    self.presentScreenshotTranslationError(error)
                }
            }
        }
    }

    @MainActor
    private func presentScreenshotTranslationError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Screenshot translation failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @MainActor
    private func presentSelectionTranslationError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Selection translation failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @MainActor
    @objc private func selectTargetLanguage(_ sender: NSMenuItem) {
        guard let languageID = sender.representedObject as? String else {
            return
        }

        targetLanguage = TranslationLanguage.language(id: languageID)
        cancelPrefetch()
        translationPanelController?.close()
        translationPanelController = nil
        updateMenuState()
    }

    @MainActor
    @objc private func selectDraftTargetLanguage(_ sender: NSMenuItem) {
        guard let languageID = sender.representedObject as? String else {
            return
        }

        draftTargetLanguage = TranslationLanguage.language(id: languageID)
        translationPanelController?.close()
        translationPanelController = nil
        updateMenuState()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

final class SelectionReader {
    func readSelectedText(
        allowClipboardFallback: Bool,
        completion: @escaping (String?) -> Void
    ) {
        if let selectedText = readSelectedText() {
            completion(selectedText)
            return
        }

        guard allowClipboardFallback else {
            completion(nil)
            return
        }

        ClipboardSelectionReader.readSelectedText(completion: completion)
    }

    func isLikelyEditableElementAtMouseLocation() -> Bool {
        guard let element = elementAtMouseLocation() ?? focusedElement() else {
            return false
        }

        var currentElement: AXUIElement? = element
        for _ in 0..<6 {
            guard let element = currentElement else {
                return false
            }

            if let role = role(of: element), Self.editableTextRoles.contains(role) {
                return true
            }

            currentElement = parent(of: element)
        }

        return false
    }

    func readSelectedText() -> String? {
        guard let focusedElement = focusedElement() else {
            return nil
        }

        guard let text = selectedText(from: focusedElement) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private static let editableTextRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedResult == .success,
              let focusedElement = focusedValue,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    private func elementAtMouseLocation() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        let mouseLocation = NSEvent.mouseLocation
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(mouseLocation.x),
            Float(mouseLocation.y),
            &element
        )

        guard result == .success else {
            return nil
        }

        return element
    }

    private func role(of element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )

        guard result == .success else {
            return nil
        }

        return roleValue as? String
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var parentValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentValue
        )

        guard result == .success,
              let parentValue,
              CFGetTypeID(parentValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (parentValue as! AXUIElement)
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var selectedTextValue: CFTypeRef?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )

        if selectedTextResult == .success, let selectedText = selectedTextValue as? String {
            return selectedText
        }

        return selectedTextViaRange(from: element)
    }

    private func selectedTextViaRange(from element: AXUIElement) -> String? {
        var rangeValue: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )

        guard rangeResult == .success, let rangeValue else {
            return nil
        }

        var textValue: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &textValue
        )

        guard textResult == .success, let fullText = textValue as? String else {
            return nil
        }

        var range = CFRange()
        guard CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        let axRangeValue = rangeValue as! AXValue
        guard AXValueGetType(axRangeValue) == .cfRange,
              AXValueGetValue(axRangeValue, .cfRange, &range),
              range.length > 0
        else {
            return nil
        }

        let utf16 = fullText.utf16
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= utf16.count
        else {
            return nil
        }

        let utf16Start = utf16.index(utf16.startIndex, offsetBy: range.location)
        let utf16End = utf16.index(utf16.startIndex, offsetBy: range.location + range.length)
        guard let start = utf16Start.samePosition(in: fullText),
              let end = utf16End.samePosition(in: fullText)
        else {
            return nil
        }

        return String(fullText[start..<end])
    }
}

enum ClipboardSelectionReader {
    private static let markerPrefix = "YakuSelectionProbe:"

    static func readSelectedText(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let marker = "\(markerPrefix)\(UUID().uuidString)"

        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)

        postCommandC()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            let copiedText = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            snapshot.restore(to: pasteboard)

            guard let copiedText,
                  !copiedText.isEmpty,
                  copiedText != marker
            else {
                completion(nil)
                return
            }

            completion(copiedText)
        }
    }

    private static func postCommandC() {
        KeyboardShortcutPoster.postCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_C))
    }
}

enum KeyboardShortcutPoster {
    static func postCommandShortcut(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        postKey(CGKeyCode(kVK_Command), keyDown: true, flags: .maskCommand, source: source)
        postKey(keyCode, keyDown: true, flags: .maskCommand, source: source)
        postKey(keyCode, keyDown: false, flags: .maskCommand, source: source)
        postKey(CGKeyCode(kVK_Command), keyDown: false, flags: [], source: source)
    }

    private static func postKey(
        _ keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let capturedItems = (pasteboard.pasteboardItems ?? []).map { item in
            var capturedTypes: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    capturedTypes[type] = data
                }
            }
            return capturedTypes
        }

        return PasteboardSnapshot(items: capturedItems)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { capturedTypes in
            let item = NSPasteboardItem()
            for (type, data) in capturedTypes {
                item.setData(data, forType: type)
            }
            return item
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

enum PasteboardTextInserter {
    static func replaceCurrentSelection(with text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let replacementChangeCount = pasteboard.changeCount

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard pasteboard.changeCount == replacementChangeCount else {
                return
            }
            snapshot.restore(to: pasteboard)
        }
    }

    private static func postCommandV() {
        KeyboardShortcutPoster.postCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_V))
    }
}

enum ScreenshotTranslationError: LocalizedError {
    case captureCancelled
    case captureFailed(Int32)
    case noTextRecognized

    var errorDescription: String? {
        switch self {
        case .captureCancelled:
            "Screenshot selection was cancelled."
        case .captureFailed(let status):
            "Screenshot capture failed with exit code \(status)."
        case .noTextRecognized:
            "No readable text was found in the selected area."
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        guard let screenshotError = error as? ScreenshotTranslationError else {
            return false
        }

        if case .captureCancelled = screenshotError {
            return true
        }
        return false
    }
}

enum ScreenshotCapture {
    static func captureInteractiveArea() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("yaku-screenshot-\(UUID().uuidString)")
                    .appendingPathExtension("png")

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", outputURL.path]

                do {
                    try process.run()
                    process.waitUntilExit()

                    let fileExists = FileManager.default.fileExists(atPath: outputURL.path)
                    if process.terminationStatus != 0 {
                        if !fileExists {
                            continuation.resume(throwing: ScreenshotTranslationError.captureCancelled)
                        } else {
                            continuation.resume(throwing: ScreenshotTranslationError.captureFailed(process.terminationStatus))
                        }
                        return
                    }

                    guard fileExists,
                          let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                          let fileSize = attributes[.size] as? NSNumber,
                          fileSize.intValue > 0
                    else {
                        continuation.resume(throwing: ScreenshotTranslationError.captureCancelled)
                        return
                    }

                    continuation.resume(returning: outputURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum ImageTextRecognizer {
    private struct RecognizedLine {
        let text: String
        let boundingBox: CGRect
    }

    static func recognizeText(in imageURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true

                    let supportedLanguages = (try? request.supportedRecognitionLanguages()) ?? []
                    if !supportedLanguages.isEmpty {
                        request.recognitionLanguages = supportedLanguages
                    }

                    let handler = VNImageRequestHandler(url: imageURL, options: [:])
                    try handler.perform([request])

                    let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
                        guard let candidate = observation.topCandidates(1).first else {
                            return nil
                        }

                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else {
                            return nil
                        }

                        return RecognizedLine(text: text, boundingBox: observation.boundingBox)
                    }

                    let orderedLines = lines.sorted { lhs, rhs in
                        let rowTolerance: CGFloat = 0.025
                        let lhsMidY = lhs.boundingBox.midY
                        let rhsMidY = rhs.boundingBox.midY

                        if abs(lhsMidY - rhsMidY) <= rowTolerance {
                            return lhs.boundingBox.minX < rhs.boundingBox.minX
                        }

                        return lhsMidY > rhsMidY
                    }

                    let recognizedText = orderedLines
                        .map(\.text)
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    guard !recognizedText.isEmpty else {
                        continuation.resume(throwing: ScreenshotTranslationError.noTextRecognized)
                        return
                    }

                    continuation.resume(returning: recognizedText)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

final class FloatingTranslateButtonController {
    private let panel: NSPanel
    private let selectedText: String
    private let onTranslate: (String) -> Void

    init(screenPoint: NSPoint, selectedText: String, onTranslate: @escaping (String) -> Void) {
        self.selectedText = selectedText
        self.onTranslate = onTranslate

        let buttonSize: CGFloat = 30
        let shadowPadding: CGFloat = 15
        let totalSize: CGFloat = buttonSize + shadowPadding * 2
        let origin = NSPoint(
            x: screenPoint.x + 5 - shadowPadding,
            y: screenPoint.y - buttonSize - 5 - shadowPadding
        )
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: totalSize, height: totalSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: totalSize, height: totalSize)))
        let buttonView = FloatingTranslateButtonView { [weak self] in
            guard let self else { return }
            self.onTranslate(self.selectedText)
        }
        buttonView.frame = NSRect(x: shadowPadding, y: shadowPadding, width: buttonSize, height: buttonSize)
        container.addSubview(buttonView)
        panel.contentView = container
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
    }
}

final class FloatingTranslateButtonView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        wantsLayer = true
        buildUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer = self.layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.38
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -3)
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        layer.masksToBounds = false
    }

    private func buildUI() {
        let glass = GlassHostView(
            frame: bounds,
            cornerRadius: bounds.width / 2,
            tintColor: NSColor(srgbRed: 0.06, green: 0.12, blue: 0.22, alpha: 0.55),
            style: .regular
        )
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        let button = NSButton(title: "あ", target: self, action: #selector(buttonTapped))
        button.frame = bounds
        button.autoresizingMask = [.width, .height]
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        button.contentTintColor = .white
        button.toolTip = "Translate selection"
        glass.contentView.addSubview(button)
    }

    @objc private func buttonTapped() {
        onClick()
    }
}

final class TranslationPanelController {
    private let panel: NSPanel
    private let contentView: TranslationContentView
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?

    var panelFrame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }

    init(
        screenPoint: NSPoint,
        sourceText: String,
        targetLanguage: TranslationLanguage,
        onReplace: ((String) -> Void)? = nil
    ) {
        let visibleFrame = NSScreen.visibleFrame(containing: screenPoint)
        let panelHeight = min(
            TranslationContentView.preferredHeight(sourceText: sourceText, resultText: "Translating..."),
            visibleFrame.height - 32
        )
        let panelSize = NSSize(width: TranslationContentView.preferredWidth, height: panelHeight)
        let origin = NSPoint(
            x: min(screenPoint.x + 10, visibleFrame.maxX - panelSize.width - 16),
            y: max(screenPoint.y - panelSize.height - 10, visibleFrame.minY + 16)
        )

        contentView = TranslationContentView(
            sourceText: sourceText,
            targetLanguage: targetLanguage,
            onReplace: onReplace
        )
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = contentView
        contentView.onClose = { [weak self] in self?.close() }
    }

    deinit {
        removeOutsideClickMonitors()
    }

    func showLoading() {
        contentView.setResult("Translating...")
        resizeToFitContent(animated: false)
        panel.orderFrontRegardless()
        installOutsideClickMonitors()
    }

    func showTranslation(_ text: String) {
        contentView.setResult(text)
        resizeToFitContent(animated: false)
    }

    func showError(_ message: String) {
        contentView.setResult("Error: \(message)")
        resizeToFitContent(animated: true)
    }

    func close() {
        removeOutsideClickMonitors()
        panel.close()
    }

    private func installOutsideClickMonitors() {
        guard globalOutsideClickMonitor == nil, localOutsideClickMonitor == nil else {
            return
        }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickIsOutside(event)
        }

        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickIsOutside(event)
            return event
        }
    }

    private func removeOutsideClickMonitors() {
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }

        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
    }

    private func closeIfClickIsOutside(_ event: NSEvent) {
        guard panel.isVisible else {
            return
        }

        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard !panel.frame.insetBy(dx: -4, dy: -4).contains(screenPoint) else {
            return
        }

        close()
    }

    private func resizeToFitContent(animated: Bool) {
        let currentFrame = panel.frame
        let visibleFrame = NSScreen.visibleFrame(containing: NSPoint(x: currentFrame.midX, y: currentFrame.midY))
        let targetHeight = min(contentView.preferredHeightForCurrentContent(), visibleFrame.height - 32)
        let targetWidth = TranslationContentView.preferredWidth
        var targetY = currentFrame.maxY - targetHeight
        targetY = max(targetY, visibleFrame.minY + 16)
        targetY = min(targetY, visibleFrame.maxY - targetHeight - 16)

        let targetFrame = NSRect(
            x: min(currentFrame.minX, visibleFrame.maxX - targetWidth - 16),
            y: targetY,
            width: targetWidth,
            height: targetHeight
        )

        let frameUnchanged = abs(targetFrame.minX - currentFrame.minX) < 0.5
            && abs(targetFrame.minY - currentFrame.minY) < 0.5
            && abs(targetFrame.width - currentFrame.width) < 0.5
            && abs(targetFrame.height - currentFrame.height) < 0.5
        if frameUnchanged {
            contentView.layoutForCurrentSize()
            return
        }

        let heightDelta = abs(targetFrame.height - currentFrame.height)
        if !animated || heightDelta < 1.5 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(targetFrame, display: true)
            CATransaction.commit()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }
}

private extension NSScreen {
    static func visibleFrame(containing point: NSPoint) -> NSRect {
        NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
    }
}

enum GlassHostStyle {
    case regular
    case clear
}

final class GlassHostView: NSView {
    let contentView = NSView()

    init(frame: NSRect, cornerRadius: CGFloat, tintColor: NSColor?, style: GlassHostStyle) {
        super.init(frame: frame)
        wantsLayer = true
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            glass.style = style == .clear ? .clear : .regular
            glass.contentView = contentView
            addSubview(glass)
        } else {
            let material = NSVisualEffectView(frame: bounds)
            material.autoresizingMask = [.width, .height]
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = cornerRadius
            material.layer?.masksToBounds = true
            addSubview(material)
            material.addSubview(contentView)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class TranslationContentView: NSView, NSTextViewDelegate {
    static let preferredWidth: CGFloat = 400
    private static let minHeight: CGFloat = 156
    private static let maxHeight: CGFloat = 540
    private static let contentWidth: CGFloat = 364
    private static let minimumSourceBoxHeight: CGFloat = 38
    private static let minimumResultBoxHeight: CGFloat = 48
    private static let maximumSourceBoxHeight: CGFloat = 140
    private static let maximumResultBoxHeight: CGFloat = 280

    private static let panelPaddingX: CGFloat = 18
    private static let panelPaddingTop: CGFloat = 16
    private static let panelPaddingBottom: CGFloat = 16
    private static let labelHeight: CGFloat = 14
    private static let labelToBoxGap: CGFloat = 8
    private static let sectionGap: CGFloat = 14
    private static let buttonSize: CGFloat = 18
    private static let sourceFontSize: CGFloat = 15
    private static let resultFontSize: CGFloat = 15
    private static let boxInsetX: CGFloat = 14
    private static let boxInsetY: CGFloat = 10
    private static let scrollableTextBottomPadding: CGFloat = 18

    var onClose: (() -> Void)?

    private let sourceText: String
    private let targetLanguage: TranslationLanguage
    private var resultText = "Translating..."
    private var resultDisplayText = "Translating..."
    private let resultTextView = NSTextView()
    private let sourceTitleLabel = NSTextField(labelWithString: "")
    private let targetTitleLabel = NSTextField(labelWithString: "")
    private let sourceTextView = NSTextView()
    private let sourceScrollView = NSScrollView()
    private let resultScrollView = NSScrollView()
    private var panelGlass: GlassHostView?
    private var sourceBox: GlassHostView?
    private var resultBox: GlassHostView?
    private var closeButton: NSButton?
    private var copyButton: NSButton?
    private var replaceButton: NSButton?
    private var selectionCopyBubble: GlassHostView?
    private var selectionCopyButton: NSButton?
    private var selectedSnippetToCopy: String?
    private weak var selectedTextView: NSTextView?
    private var shouldScrollSourceToTop = true
    private var shouldScrollResultToTop = true
    private let onReplace: ((String) -> Void)?

    init(sourceText: String, targetLanguage: TranslationLanguage, onReplace: ((String) -> Void)? = nil) {
        self.sourceText = sourceText
        self.targetLanguage = targetLanguage
        self.onReplace = onReplace
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.preferredWidth,
            height: Self.preferredHeight(sourceText: sourceText, resultText: "Translating...")
        ))
        wantsLayer = true
        buildUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    static func preferredHeight(sourceText: String, resultText: String) -> CGFloat {
        let sourceBoxHeight = boxHeight(
            for: sourceText,
            font: NSFont.systemFont(ofSize: sourceFontSize, weight: .regular),
            width: contentWidth - boxInsetX * 2,
            minimum: minimumSourceBoxHeight,
            maximum: maximumSourceBoxHeight
        )
        let resultBoxHeight = boxHeight(
            for: resultText,
            font: NSFont.systemFont(ofSize: resultFontSize, weight: .regular),
            width: contentWidth - boxInsetX * 2,
            minimum: minimumResultBoxHeight,
            maximum: maximumResultBoxHeight
        )

        let fixedHeight = panelPaddingTop
            + labelHeight + labelToBoxGap
            + sectionGap
            + labelHeight + labelToBoxGap
            + panelPaddingBottom
        return min(max(fixedHeight + sourceBoxHeight + resultBoxHeight, minHeight), maxHeight)
    }

    func preferredHeightForCurrentContent() -> CGFloat {
        Self.preferredHeight(sourceText: sourceText, resultText: resultDisplayText)
    }

    private static func boxHeight(for text: String, font: NSFont, width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let height = textHeight(for: text, font: font, width: width) + boxInsetY * 2 + 4
        return min(max(height, minimum), maximum)
    }

    private static func layoutScrollableTextView(
        _ textView: NSTextView,
        inside scrollView: NSScrollView,
        scrollFrame: NSRect,
        rawTextHeight: CGFloat
    ) {
        scrollView.frame = scrollFrame

        let minimumVerticalTextPadding: CGFloat = 4
        let fitsInScrollFrame = rawTextHeight + minimumVerticalTextPadding * 2 <= scrollFrame.height
        let verticalInset: CGFloat
        let textViewHeight: CGFloat
        if fitsInScrollFrame {
            verticalInset = floor(max(2, (scrollFrame.height - rawTextHeight) / 2))
            textViewHeight = scrollFrame.height
        } else {
            verticalInset = minimumVerticalTextPadding
            textViewHeight = max(
                scrollFrame.height + 1,
                rawTextHeight + verticalInset * 2 + scrollableTextBottomPadding
            )
        }

        let scrollerInset: CGFloat = 8
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: scrollFrame.width, height: textViewHeight)
        )
        textView.minSize = NSSize(width: 0, height: scrollFrame.height)
        textView.textContainer?.containerSize = NSSize(
            width: max(0, scrollFrame.width - scrollerInset),
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.hasVerticalScroller = !fitsInScrollFrame
    }

    private static func textHeight(for text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let cleanText = text.isEmpty ? " " : text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(string: cleanText, attributes: [
            .font: font,
            .paragraphStyle: paragraph
        ])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    private static func renderedMarkdownText(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let rendered = (try? AttributedString(markdown: text, options: options))
            .map { NSMutableAttributedString($0) }
            ?? NSMutableAttributedString(string: text)

        guard rendered.length > 0 else {
            return rendered
        }

        let fullRange = NSRange(location: 0, length: rendered.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 0
        rendered.addAttributes([
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ], range: fullRange)

        var fontRuns: [(NSRange, NSFont)] = []
        rendered.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            guard let intent = (value as? NSNumber)?.intValue else {
                return
            }

            if let styledFont = markdownFont(for: intent, baseFont: font) {
                fontRuns.append((range, styledFont))
            }
        }
        for (range, styledFont) in fontRuns {
            rendered.addAttribute(.font, value: styledFont, range: range)
        }

        var linkRuns: [NSRange] = []
        rendered.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            if value != nil {
                linkRuns.append(range)
            }
        }
        for range in linkRuns {
            rendered.addAttributes([
                .foregroundColor: NSColor(calibratedRed: 0.72, green: 0.86, blue: 1.0, alpha: 0.96),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: range)
        }

        return rendered
    }

    private static func markdownFont(for intent: Int, baseFont: NSFont) -> NSFont? {
        let emphasized = 1
        let stronglyEmphasized = 2
        let code = 4

        if intent & code != 0 {
            return NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.94, weight: .regular)
        }

        var font = baseFont
        var changed = false
        if intent & stronglyEmphasized != 0 {
            font = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
            changed = true
        }
        if intent & emphasized != 0 {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            changed = true
        }
        return changed ? font : nil
    }

    private func buildUI() {
        let panelGlass = GlassHostView(
            frame: bounds,
            cornerRadius: 22,
            tintColor: NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.18, alpha: 0.46),
            style: .regular
        )
        panelGlass.autoresizingMask = [.width, .height]
        addSubview(panelGlass)
        let content = panelGlass.contentView
        self.panelGlass = panelGlass

        configureSectionLabel(sourceTitleLabel, text: "Source")
        content.addSubview(sourceTitleLabel)

        closeButton = makeIconButton(
            symbolName: "xmark",
            accessibilityDescription: "Close",
            pointSize: 10,
            target: self,
            action: #selector(closeTapped),
            to: content
        )

        let sourceBox = makeTextBox(in: content)
        self.sourceBox = sourceBox

        configureScrollView(sourceScrollView)
        configureTextView(
            sourceTextView,
            text: sourceText,
            font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .regular),
            color: NSColor(calibratedWhite: 1.0, alpha: 0.92)
        )
        sourceScrollView.documentView = sourceTextView
        sourceBox.contentView.addSubview(sourceScrollView)

        configureSectionLabel(targetTitleLabel, text: targetLanguage.displayName)
        content.addSubview(targetTitleLabel)

        copyButton = makeIconButton(
            symbolName: "doc.on.doc",
            accessibilityDescription: "Copy translation",
            pointSize: 11,
            target: self,
            action: #selector(copyResult),
            to: content
        )

        if onReplace != nil {
            let replaceButton = makeIconButton(
                symbolName: "text.insert",
                accessibilityDescription: "Replace selected text",
                pointSize: 12,
                target: self,
                action: #selector(replaceSelectedText),
                to: content
            )
            replaceButton.isEnabled = false
            replaceButton.contentTintColor = NSColor(calibratedWhite: 1.0, alpha: 0.42)
            self.replaceButton = replaceButton
        }

        let copyBubble = GlassHostView(
            frame: NSRect(x: 0, y: 0, width: 34, height: 34),
            cornerRadius: 17,
            tintColor: NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.20, alpha: 0.58),
            style: .regular
        )
        copyBubble.isHidden = true
        content.addSubview(copyBubble)
        selectionCopyBubble = copyBubble

        selectionCopyButton = makeIconButton(
            symbolName: "doc.on.doc",
            accessibilityDescription: "Copy selection",
            pointSize: 14,
            target: self,
            action: #selector(copySelectedSnippet),
            to: copyBubble.contentView
        )
        selectionCopyButton?.frame = copyBubble.contentView.bounds
        selectionCopyButton?.autoresizingMask = [.width, .height]
        selectionCopyButton?.contentTintColor = NSColor(calibratedWhite: 1.0, alpha: 0.78)
        selectionCopyButton?.sendAction(on: [.leftMouseDown])

        let resultBox = makeTextBox(in: content)
        self.resultBox = resultBox

        configureScrollView(resultScrollView)
        configureTextView(
            resultTextView,
            text: resultText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .regular),
            color: .white
        )
        resultScrollView.documentView = resultTextView
        resultBox.contentView.addSubview(resultScrollView)
        if let selectionCopyBubble {
            selectionCopyBubble.removeFromSuperview()
            content.addSubview(selectionCopyBubble)
        }

        setResult(resultText)
    }

    private func makeTextBox(in parent: NSView) -> GlassHostView {
        let box = GlassHostView(
            frame: .zero,
            cornerRadius: 12,
            tintColor: NSColor(calibratedWhite: 0.0, alpha: 0.22),
            style: .clear
        )
        parent.addSubview(box)
        return box
    }

    private func configureScrollView(_ scrollView: NSScrollView) {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.knobStyle = .light
        scrollView.borderType = .noBorder
    }

    private func configureTextView(_ textView: NSTextView, text: String, font: NSFont, color: NSColor) {
        textView.string = text
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textColor = color
        textView.font = font
        textView.delegate = self
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 2)
    }

    @discardableResult
    private func makeIconButton(
        symbolName: String,
        accessibilityDescription: String,
        pointSize: CGFloat,
        target: AnyObject,
        action: Selector,
        to parent: NSView
    ) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) ?? NSImage()
        let image = baseImage.withSymbolConfiguration(config) ?? baseImage
        let button = NSButton(image: image, target: target, action: action)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor(calibratedWhite: 1.0, alpha: 0.55)
        button.toolTip = accessibilityDescription
        parent.addSubview(button)
        return button
    }

    private func configureSectionLabel(_ label: NSTextField, text: String) {
        let attributed = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.50),
            .kern: 1.6
        ])
        label.attributedStringValue = attributed
    }

    func layoutForCurrentSize() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let sourceBoxHeight = Self.boxHeight(
            for: sourceText,
            font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .regular),
            width: Self.contentWidth - Self.boxInsetX * 2,
            minimum: Self.minimumSourceBoxHeight,
            maximum: Self.maximumSourceBoxHeight
        )
        let fixedHeight = Self.panelPaddingTop
            + Self.labelHeight + Self.labelToBoxGap
            + Self.sectionGap
            + Self.labelHeight + Self.labelToBoxGap
            + Self.panelPaddingBottom
        let availableBoxHeight = max(
            Self.minimumSourceBoxHeight + Self.minimumResultBoxHeight,
            bounds.height - fixedHeight
        )
        let resolvedSourceBoxHeight = min(
            sourceBoxHeight,
            max(Self.minimumSourceBoxHeight, availableBoxHeight - Self.minimumResultBoxHeight)
        )
        let resolvedResultBoxHeight = max(Self.minimumResultBoxHeight, availableBoxHeight - resolvedSourceBoxHeight)

        var y = bounds.height - Self.panelPaddingTop - Self.labelHeight
        sourceTitleLabel.frame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth - Self.buttonSize - 8,
            height: Self.labelHeight
        )
        closeButton?.frame = NSRect(
            x: bounds.width - Self.panelPaddingX - Self.buttonSize,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )

        y -= Self.labelToBoxGap + resolvedSourceBoxHeight
        sourceBox?.frame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: resolvedSourceBoxHeight
        )
        let sourceScrollFrame = NSRect(
            x: Self.boxInsetX,
            y: Self.boxInsetY,
            width: Self.contentWidth - Self.boxInsetX * 2,
            height: resolvedSourceBoxHeight - Self.boxInsetY * 2
        )
        let sourceRawTextHeight = Self.textHeight(
            for: sourceText,
            font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .regular),
            width: sourceScrollFrame.width
        )
        Self.layoutScrollableTextView(
            sourceTextView,
            inside: sourceScrollView,
            scrollFrame: sourceScrollFrame,
            rawTextHeight: sourceRawTextHeight
        )
        if shouldScrollSourceToTop {
            scrollToTop(sourceScrollView)
            shouldScrollSourceToTop = false
        }

        y -= Self.sectionGap + Self.labelHeight
        let targetActionButtonCount = replaceButton == nil ? 1 : 2
        let targetActionWidth = CGFloat(targetActionButtonCount) * Self.buttonSize
            + CGFloat(max(0, targetActionButtonCount - 1)) * 8
        targetTitleLabel.frame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth - targetActionWidth - 8,
            height: Self.labelHeight
        )
        copyButton?.frame = NSRect(
            x: bounds.width - Self.panelPaddingX - Self.buttonSize,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )
        replaceButton?.frame = NSRect(
            x: bounds.width - Self.panelPaddingX - Self.buttonSize * 2 - 8,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )

        y -= Self.labelToBoxGap + resolvedResultBoxHeight
        resultBox?.frame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: resolvedResultBoxHeight
        )

        let resultScrollFrame = NSRect(
            x: Self.boxInsetX,
            y: Self.boxInsetY,
            width: Self.contentWidth - Self.boxInsetX * 2,
            height: resolvedResultBoxHeight - Self.boxInsetY * 2
        )
        let resultRawTextHeight = Self.textHeight(
            for: resultDisplayText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .regular),
            width: resultScrollFrame.width
        )
        Self.layoutScrollableTextView(
            resultTextView,
            inside: resultScrollView,
            scrollFrame: resultScrollFrame,
            rawTextHeight: resultRawTextHeight
        )
        if shouldScrollResultToTop {
            scrollToTop(resultScrollView)
            shouldScrollResultToTop = false
        }
    }

    func setResult(_ text: String) {
        hideSelectionCopyButtonIfNeeded(for: resultTextView)
        let cleanedText = TextNormalizer.cleanedTranslation(text)

        if cleanedText == resultText {
            return
        }

        if !cleanedText.hasPrefix(resultText) {
            shouldScrollResultToTop = true
        }

        let renderedText = Self.renderedMarkdownText(
            cleanedText,
            font: resultTextView.font ?? NSFont.systemFont(ofSize: Self.resultFontSize, weight: .regular),
            color: resultTextView.textColor ?? NSColor.white
        )
        if let textStorage = resultTextView.textStorage {
            textStorage.setAttributedString(renderedText)
        } else {
            resultTextView.string = renderedText.string
        }

        resultText = cleanedText
        resultDisplayText = resultTextView.string
        updateReplaceButtonState()
        layoutForCurrentSize()
    }

    private func scrollToTop(_ scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else {
            return
        }

        let clipView = scrollView.contentView
        let y = documentView.isFlipped
            ? CGFloat.zero
            : max(0, documentView.bounds.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutForCurrentSize()
    }

    @objc private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultTextView.string, forType: .string)
    }

    @objc private func replaceSelectedText() {
        let replacement = TextNormalizer.cleanedTranslation(resultTextView.string)
        guard !replacement.isEmpty,
              replacement != "Translating...",
              !replacement.hasPrefix("Error:")
        else {
            return
        }

        onReplace?(replacement)
    }

    @objc private func copySelectedSnippet() {
        guard let selectedSnippetToCopy, !selectedSnippetToCopy.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedSnippetToCopy, forType: .string)
        hideSelectionCopyButton()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else {
            return
        }

        updateSelectionCopyButton(for: textView)
    }

    private func updateSelectionCopyButton(for textView: NSTextView) {
        guard let selectedText = selectedText(in: textView), !selectedText.isEmpty else {
            hideSelectionCopyButtonIfNeeded(for: textView)
            return
        }

        selectedSnippetToCopy = selectedText
        selectedTextView = textView

        positionSelectionCopyBubbleNearMouse()
        selectionCopyBubble?.isHidden = false
    }

    private func positionSelectionCopyBubbleNearMouse() {
        let bubbleSize = NSSize(width: 34, height: 34)
        let mouseInWindow = window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? convert(NSEvent.mouseLocation, from: nil)
        let mouseInView = convert(mouseInWindow, from: nil)
        let targetOrigin = NSPoint(
            x: mouseInView.x + 10,
            y: mouseInView.y + 10
        )
        let clampedOrigin = NSPoint(
            x: min(max(8, targetOrigin.x), max(8, bounds.width - bubbleSize.width - 8)),
            y: min(max(8, targetOrigin.y), max(8, bounds.height - bubbleSize.height - 8))
        )
        selectionCopyBubble?.frame = NSRect(origin: clampedOrigin, size: bubbleSize)
    }

    private func selectedText(in textView: NSTextView) -> String? {
        let range = textView.selectedRange()
        guard range.length > 0, let stringRange = Range(range, in: textView.string) else {
            return nil
        }

        return String(textView.string[stringRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hideSelectionCopyButtonIfNeeded(for textView: NSTextView) {
        guard selectedTextView === textView else {
            return
        }

        hideSelectionCopyButton(clearSelection: false)
    }

    private func hideSelectionCopyButton(clearSelection: Bool = true) {
        selectionCopyBubble?.isHidden = true
        if clearSelection {
            selectedSnippetToCopy = nil
            selectedTextView = nil
        }
    }

    private func updateReplaceButtonState() {
        guard let replaceButton else {
            return
        }

        let replacement = TextNormalizer.cleanedTranslation(resultTextView.string)
        let canReplace = !replacement.isEmpty
            && replacement != "Translating..."
            && !replacement.hasPrefix("Error:")
        replaceButton.isEnabled = canReplace
        replaceButton.contentTintColor = NSColor(calibratedWhite: 1.0, alpha: canReplace ? 0.70 : 0.35)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

enum TranslationMode {
    case selection
    case draftMessage

    func systemPrompt(targetLanguage: TranslationLanguage) -> String {
        switch self {
        case .selection:
            """
            Translate the user's text into natural \(targetLanguage.promptName) by preserving the intended meaning, not by translating word-for-word. First infer what the text is trying to say in context, then express that idea as a fluent native \(targetLanguage.promptName) speaker would. Silently clean accidental line breaks, repeated spaces, OCR artifacts, and hyphenated line wraps. Preserve proper names, dates, numbers, URLs, and concrete facts. Preserve paragraph, bullet, and list structure when present. If the source is long or dense, split the translation into readable paragraphs instead of returning one wall of text. Prefer clear idiomatic wording over literal phrasing. Return only the \(targetLanguage.promptName) translation, with no commentary.
            """
        case .draftMessage:
            """
            Rewrite the user's drafted outgoing message as a natural message in \(targetLanguage.promptName). Do not translate mechanically. Infer the user's actual intent, emotion, and social situation, then say it the way a native \(targetLanguage.promptName) speaker would send it in a chat or message.

            Preserve the original meaning, tone, politeness level, formatting, line breaks, emojis, URLs, usernames, product names, and concrete details. Adapt idioms, word order, honorifics, and phrasing so the result feels culturally and conversationally natural. If the draft is blunt, awkward, or phrased like a direct translation, smooth it while keeping the same intent. If the draft is a fragment, return a natural sendable fragment without inventing extra context. If the draft is already in \(targetLanguage.promptName), lightly polish it only when needed.

            Return only the final \(targetLanguage.promptName) message, with no commentary, labels, alternatives, quotes, or explanations.
            """
        }
    }
}

struct OllamaClient {
    let baseURL: URL
    let model: String

    func translate(
        _ text: String,
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode = .selection,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let sourceText: String
        switch mode {
        case .selection:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        }
        guard !sourceText.isEmpty else {
            throw TranslationError.emptyResponse
        }

        let url = baseURL.appending(path: "api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body = ChatRequest(
            model: model,
            stream: true,
            think: "low",
            messages: [
                ChatMessage(
                    role: "system",
                    content: mode.systemPrompt(targetLanguage: targetLanguage)
                ),
                ChatMessage(role: "user", content: sourceText)
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet {
            throw TranslationError.serverUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.ollama("invalid response")
        }

        if httpResponse.statusCode == 404 {
            throw TranslationError.modelMissing(model)
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw TranslationError.signInRequired
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranslationError.ollama("HTTP \(httpResponse.statusCode)")
        }

        var translated = ""
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else {
                continue
            }

            if let streamError = try? decoder.decode(StreamError.self, from: data),
               let message = streamError.error {
                throw OllamaClient.classifyStreamError(message: message, model: model)
            }

            let decoded = try decoder.decode(ChatResponse.self, from: data)
            translated += decoded.message.content

            let partial = TextNormalizer.cleanedTranslation(translated)
            if !partial.isEmpty {
                onPartial(partial)
            }

            if decoded.done {
                break
            }
        }

        let finalTranslation = TextNormalizer.cleanedTranslation(translated)
        guard !finalTranslation.isEmpty else {
            throw TranslationError.emptyResponse
        }

        return finalTranslation
    }

    static func classifyStreamError(message: String, model: String) -> TranslationError {
        let lowered = message.lowercased()
        if lowered.contains("not found") && (lowered.contains("model") || lowered.contains("manifest")) {
            return .modelMissing(model)
        }
        if lowered.contains("unauthorized")
            || lowered.contains("sign in")
            || lowered.contains("not signed in")
            || lowered.contains("signin")
            || lowered.contains("authenticate")
            || lowered.contains("forbidden") {
            return .signInRequired
        }
        return .ollama(message)
    }
}

struct ChatRequest: Encodable {
    let model: String
    let stream: Bool
    let think: String
    let messages: [ChatMessage]
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatResponse: Decodable {
    let message: ChatMessage
    let done: Bool
}

struct StreamError: Decodable {
    let error: String?
}

enum TranslationError: LocalizedError {
    case ollama(String)
    case emptyResponse
    case serverUnavailable
    case modelMissing(String)
    case signInRequired

    var errorDescription: String? {
        switch self {
        case .ollama(let message):
            "Ollama request failed: \(message)"
        case .emptyResponse:
            "Ollama returned an empty translation."
        case .serverUnavailable:
            "Ollama isn't running. Open Yaku setup to install or start it."
        case .modelMissing(let name):
            "Model \(name) isn't available. Open Yaku setup to pull it."
        case .signInRequired:
            "Ollama needs sign-in for the cloud model. Open Yaku setup to finish."
        }
    }
}

extension YakuApp: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
    }
}
