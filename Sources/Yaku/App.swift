import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Sparkle
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
    case floatingDefaultMode = 111
    case thinkingLevel = 112
    case selectedModel = 113
    case checkForUpdates = 114
}

struct OllamaModelOption: Equatable {
    let id: String
    let displayName: String
    let isCloud: Bool

    static let all: [OllamaModelOption] = [
        .init(id: "gpt-oss:120b-cloud", displayName: "gpt-oss 120B (Cloud)", isCloud: true),
        .init(id: "gpt-oss:20b", displayName: "gpt-oss 20B (Local, offline)", isCloud: false)
    ]

    static let defaultModel = all[0]

    static func option(id: String) -> OllamaModelOption {
        all.first { $0.id == id } ?? defaultModel
    }
}

enum ThinkingLevel: String, CaseIterable {
    case low
    case medium
    case high

    var menuTitle: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var settingsTitle: String {
        "Thinking: \(menuTitle)"
    }
}

private enum FloatingButtonDefaultMode: String {
    case translate
    case smartReply

    var translationMode: TranslationMode {
        switch self {
        case .translate: return .selection
        case .smartReply: return .smartReply
        }
    }

    var menuTitle: String {
        switch self {
        case .translate: return "Default action: Translate"
        case .smartReply: return "Default action: Reply"
        }
    }
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
        .init(id: "en", displayName: "English (US)", promptName: "English"),
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
    let thinkingLevel: ThinkingLevel
    private let ollamaClient: OllamaClient
    private var task: Task<Void, Never>?
    private var state: State = .pending
    private var partialTranslation = ""
    private var subscribers: [(String) -> Void] = []
    private var failureSubscribers: [(String) -> Void] = []
    private let onComplete: (String, TranslationLanguage, ThinkingLevel, String) -> Void

    init(
        text: String,
        targetLanguage: TranslationLanguage,
        thinkingLevel: ThinkingLevel,
        ollamaClient: OllamaClient,
        onComplete: @escaping (String, TranslationLanguage, ThinkingLevel, String) -> Void
    ) {
        self.text = text
        self.targetLanguage = targetLanguage
        self.thinkingLevel = thinkingLevel
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
            let finalTranslation = try await ollamaClient.translate(text, to: targetLanguage, thinkingLevel: thinkingLevel) { [weak self] partial in
                Task { @MainActor in
                    self?.publishPartial(partial)
                }
            }
            state = .completed(finalTranslation)
            onComplete(text, targetLanguage, thinkingLevel, finalTranslation)
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

    func translation(for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel) -> String? {
        let key = cacheKey(for: text, targetLanguage: targetLanguage, thinkingLevel: thinkingLevel)
        guard let translation = entries[key] else {
            return nil
        }

        markRecentlyUsed(key)
        return translation
    }

    func store(_ translation: String, for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel) {
        let key = cacheKey(for: text, targetLanguage: targetLanguage, thinkingLevel: thinkingLevel)
        guard !key.isEmpty, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        entries[key] = translation
        markRecentlyUsed(key)
        trimIfNeeded()
    }

    private func cacheKey(for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel) -> String {
        "\(targetLanguage.id):\(thinkingLevel.rawValue):\(TextNormalizer.cleanedSelection(text))"
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
    private let ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
    private var ollamaClient: OllamaClient {
        OllamaClient(baseURL: ollamaBaseURL, model: selectedModelID)
    }

    private var translateButtonController: FloatingTranslateButtonController?
    private var translationPanelController: TranslationPanelController?
    private var translationPrefetch: TranslationPrefetch?
    private var isScreenshotTranslationRunning = false
    private var globalHotKeys: [GlobalHotKey] = []
    private var translationCache = TranslationCache()
    private lazy var bootstrap: OllamaBootstrap = OllamaBootstrap(
        baseURL: ollamaBaseURL,
        model: selectedModelID
    )
    private var onboardingWindowController: OnboardingWindowController?
    private lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
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
    private var floatingDefaultMode: FloatingButtonDefaultMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "floatingButtonDefaultMode") ?? FloatingButtonDefaultMode.translate.rawValue
            return FloatingButtonDefaultMode(rawValue: raw) ?? .translate
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "floatingButtonDefaultMode")
        }
    }
    private var selectedModelID: String {
        get { UserDefaults.standard.string(forKey: "selectedOllamaModel") ?? OllamaModelOption.defaultModel.id }
        set { UserDefaults.standard.set(newValue, forKey: "selectedOllamaModel") }
    }
    private var thinkingLevel: ThinkingLevel {
        get {
            let raw = UserDefaults.standard.string(forKey: "thinkingLevel") ?? ThinkingLevel.low.rawValue
            return ThinkingLevel(rawValue: raw) ?? .low
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "thinkingLevel")
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
        requestScreenRecordingPermissionIfNeeded()
        startMouseMonitor()
        setupGlobalHotKeys()
        setupBootstrap()
        _ = updaterController
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
        wireBootstrap()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            if !self.bootstrap.state.isReady {
                self.presentOnboardingWindow()
            }
        }
    }

    private func wireBootstrap() {
        bootstrap.onChange = { [weak self] state in
            self?.handleBootstrapStateChange(state)
        }
        bootstrap.refresh()
    }

    @MainActor
    private func rebuildBootstrapForCurrentModel() {
        bootstrap.cancelPull()
        let staleOnboarding = onboardingWindowController
        onboardingWindowController = nil
        staleOnboarding?.close()

        bootstrap = OllamaBootstrap(baseURL: ollamaBaseURL, model: selectedModelID)
        wireBootstrap()

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
            button.image = makeStatusBarIcon(for: floatingDefaultMode)
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
        menu.addItem(makeMenuItem(
            title: "",
            tag: .floatingDefaultMode,
            symbolName: "rectangle.and.hand.point.up.left",
            submenu: makeFloatingDefaultModeMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .thinkingLevel,
            symbolName: "brain.head.profile",
            submenu: makeThinkingLevelMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .selectedModel,
            symbolName: "cpu",
            submenu: makeModelSelectionMenu()
        ))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(
            title: "Check for Updates...",
            tag: .checkForUpdates,
            symbolName: "arrow.down.circle",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        ))
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

    private func makeStatusBarIcon(for mode: FloatingButtonDefaultMode) -> NSImage {
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

        switch mode {
        case .translate:
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
        case .smartReply:
            if let baseImage = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
                let symbol = baseImage.withSymbolConfiguration(config) ?? baseImage
                let symbolSize = symbol.size
                let drawRect = NSRect(
                    x: (size.width - symbolSize.width) / 2,
                    y: (size.height - symbolSize.height) / 2,
                    width: symbolSize.width,
                    height: symbolSize.height
                )
                symbol.draw(in: drawRect)
            }
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func refreshStatusBarIcon() {
        statusItem?.button?.image = makeStatusBarIcon(for: floatingDefaultMode)
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

    private func makeFloatingDefaultModeMenu() -> NSMenu {
        let menu = NSMenu()
        let translateItem = NSMenuItem(
            title: "Translate selection",
            action: #selector(selectFloatingDefaultMode(_:)),
            keyEquivalent: ""
        )
        translateItem.target = self
        translateItem.representedObject = FloatingButtonDefaultMode.translate.rawValue
        menu.addItem(translateItem)

        let replyItem = NSMenuItem(
            title: "Reply or answer (Tab to switch)",
            action: #selector(selectFloatingDefaultMode(_:)),
            keyEquivalent: ""
        )
        replyItem.target = self
        replyItem.representedObject = FloatingButtonDefaultMode.smartReply.rawValue
        menu.addItem(replyItem)
        return menu
    }

    private func makeThinkingLevelMenu() -> NSMenu {
        let menu = NSMenu()
        for level in ThinkingLevel.allCases {
            let item = NSMenuItem(
                title: level.menuTitle,
                action: #selector(selectThinkingLevel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = level.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func makeModelSelectionMenu() -> NSMenu {
        let menu = NSMenu()
        for option in OllamaModelOption.all {
            let item = NSMenuItem(
                title: option.displayName,
                action: #selector(selectModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.id
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
            let preferClipboard = self.shouldAttemptClipboardSelectionFallback(for: event)

            self.selectionReader.readSelectedTextContext(
                preferClipboard: preferClipboard,
                allowClipboardFallback: false
            ) { [weak self] selection in
                guard let self else { return }

                guard let selection, !selection.text.isEmpty else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.cancelPrefetch()
                    return
                }

                let cleanedSelection = TextNormalizer.cleanedSelection(selection.text)
                guard !cleanedSelection.isEmpty else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.cancelPrefetch()
                    return
                }

                self.showTranslateButton(for: cleanedSelection, near: mouseLocation)
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
        let currentThinkingLevel = thinkingLevel
        if translationCache.translation(for: selectedText, targetLanguage: language, thinkingLevel: currentThinkingLevel) == nil {
            startPrefetchIfEligible(for: selectedText)
        } else {
            cancelPrefetch()
        }

        let controller = FloatingTranslateButtonController(
            screenPoint: screenPoint,
            selectedText: selectedText,
            initialMode: floatingDefaultMode.translationMode,
            onTranslate: { [weak self] text in
                self?.translateButtonController?.close()
                self?.translateButtonController = nil
                self?.translate(text, near: screenPoint)
            },
            onSmartReply: { [weak self] text in
                self?.translateButtonController?.close()
                self?.translateButtonController = nil
                self?.replyToSelection(text, near: screenPoint)
            }
        )

        translateButtonController = controller
        controller.show()
    }

    @MainActor
    private func replyToSelection(_ text: String, near screenPoint: NSPoint) {
        cancelPrefetch()
        translate(
            text,
            near: screenPoint,
            mode: .smartReply,
            useCache: false
        )
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
        let currentThinkingLevel = thinkingLevel
        let controller = TranslationPanelController(
            screenPoint: screenPoint,
            sourceText: text,
            targetLanguage: language,
            resultLabel: mode.resultLabel,
            loadingPlaceholder: mode.loadingPlaceholder,
            onTargetLanguageSelected: { [weak self] selectedLanguage in
                self?.retranslateCurrentPanel(
                    text,
                    targetLanguage: selectedLanguage,
                    mode: mode,
                    thinkingLevel: currentThinkingLevel,
                    useCache: useCache
                )
            },
            onReplace: onReplace
        )
        translationPanelController?.close()
        translationPanelController = controller
        let requestID = controller.showLoading()
        runTranslation(
            text,
            targetLanguage: language,
            mode: mode,
            thinkingLevel: currentThinkingLevel,
            useCache: useCache,
            controller: controller,
            requestID: requestID
        )
    }

    @MainActor
    private func retranslateCurrentPanel(
        _ text: String,
        targetLanguage language: TranslationLanguage,
        mode: TranslationMode,
        thinkingLevel: ThinkingLevel,
        useCache: Bool
    ) {
        guard let controller = translationPanelController else {
            return
        }

        let requestID = controller.showLoading(targetLanguage: language)
        runTranslation(
            text,
            targetLanguage: language,
            mode: mode,
            thinkingLevel: thinkingLevel,
            useCache: useCache,
            controller: controller,
            requestID: requestID
        )
    }

    @MainActor
    private func runTranslation(
        _ text: String,
        targetLanguage language: TranslationLanguage,
        mode: TranslationMode,
        thinkingLevel: ThinkingLevel,
        useCache: Bool,
        controller: TranslationPanelController,
        requestID: UUID
    ) {
        if useCache, let cachedTranslation = translationCache.translation(for: text, targetLanguage: language, thinkingLevel: thinkingLevel) {
            controller.showTranslation(cachedTranslation, requestID: requestID)
            return
        }

        if useCache,
           let translationPrefetch,
           translationPrefetch.text == text,
           translationPrefetch.targetLanguage == language,
           translationPrefetch.thinkingLevel == thinkingLevel {
            translationPrefetch.subscribe { partialTranslation in
                controller.showTranslation(partialTranslation, requestID: requestID)
            } onFailure: { message in
                controller.showError(message, requestID: requestID)
            }
            translationPrefetch.ensureStartedNow()
            return
        }

        Task {
            do {
                let translated = try await ollamaClient.translate(text, to: language, mode: mode, thinkingLevel: thinkingLevel) { partialTranslation in
                    Task { @MainActor in
                        controller.showTranslation(partialTranslation, requestID: requestID)
                    }
                }
                await MainActor.run {
                    if useCache {
                        self.translationCache.store(translated, for: text, targetLanguage: language, thinkingLevel: thinkingLevel)
                    }
                    controller.showTranslation(translated, requestID: requestID)
                }
            } catch {
                await MainActor.run {
                    controller.showError(error.localizedDescription, requestID: requestID)
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
        let currentThinkingLevel = thinkingLevel
        let prefetch = TranslationPrefetch(
            text: text,
            targetLanguage: language,
            thinkingLevel: currentThinkingLevel,
            ollamaClient: ollamaClient
        ) { [weak self] sourceText, targetLanguage, thinkingLevel, translation in
            self?.translationCache.store(translation, for: sourceText, targetLanguage: targetLanguage, thinkingLevel: thinkingLevel)
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

    private func requestScreenRecordingPermissionIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else {
            return
        }
        _ = CGRequestScreenCaptureAccess()
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
        menu.item(withTag: MenuItemTag.targetLanguage.rawValue)?.title = "Translating to: \(targetLanguage.displayName)"
        menu.item(withTag: MenuItemTag.draftTargetLanguage.rawValue)?.title = "Write messages in \(draftTargetLanguage.displayName)"
        menu.item(withTag: MenuItemTag.floatingDefaultMode.rawValue)?.title = floatingDefaultMode.menuTitle
        menu.item(withTag: MenuItemTag.thinkingLevel.rawValue)?.title = thinkingLevel.settingsTitle
        menu.item(withTag: MenuItemTag.selectedModel.rawValue)?.title = "Model: \(OllamaModelOption.option(id: selectedModelID).displayName)"
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

        if let defaultModeMenu = menu.item(withTag: MenuItemTag.floatingDefaultMode.rawValue)?.submenu {
            let activeMode = floatingDefaultMode.rawValue
            for item in defaultModeMenu.items {
                guard let raw = item.representedObject as? String else { continue }
                item.state = raw == activeMode ? .on : .off
            }
        }

        if let thinkingMenu = menu.item(withTag: MenuItemTag.thinkingLevel.rawValue)?.submenu {
            let activeLevel = thinkingLevel.rawValue
            for item in thinkingMenu.items {
                guard let raw = item.representedObject as? String else { continue }
                item.state = raw == activeLevel ? .on : .off
            }
        }

        if let modelMenu = menu.item(withTag: MenuItemTag.selectedModel.rawValue)?.submenu {
            let activeModelID = selectedModelID
            for item in modelMenu.items {
                guard let modelID = item.representedObject as? String else { continue }
                item.state = modelID == activeModelID ? .on : .off
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

            self.selectionReader.readSelectedTextContext(allowClipboardFallback: true) { [weak self] selection in
                guard let self else { return }

                guard let selection else {
                    self.presentSelectionTranslationError("Select text first, then press \(GlobalHotKeyDefinition.translateSelectionDisplayString).")
                    return
                }

                let cleanedDraft = TextNormalizer.cleanedDraftMessage(selection.text)
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
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)

        if let screenshotError = error as? ScreenshotTranslationError,
           case .screenRecordingPermissionDenied = screenshotError {
            alert.messageText = "Screen Recording permission required"
            alert.informativeText = screenshotError.localizedDescription
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            }
            return
        }

        alert.messageText = "Screenshot translation failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
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

    @MainActor
    @objc private func selectFloatingDefaultMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = FloatingButtonDefaultMode(rawValue: raw)
        else {
            return
        }

        floatingDefaultMode = mode
        refreshStatusBarIcon()
        updateMenuState()
    }

    @MainActor
    @objc private func selectThinkingLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let level = ThinkingLevel(rawValue: raw)
        else {
            return
        }

        thinkingLevel = level
        cancelPrefetch()
        updateMenuState()
    }

    @MainActor
    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelID = sender.representedObject as? String else {
            return
        }

        let option = OllamaModelOption.option(id: modelID)
        guard option.id != selectedModelID else {
            return
        }

        selectedModelID = option.id
        cancelPrefetch()
        translationCache = TranslationCache()
        rebuildBootstrapForCurrentModel()
        updateMenuState()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @MainActor
    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

extension YakuApp: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/ChoiVadim/yaku/main/appcast.xml"
    }
}

struct SelectedTextContext {
    let text: String
    let anchorPoint: NSPoint?
}

final class SelectionReader {
    func readSelectedText(
        preferClipboard: Bool = false,
        allowClipboardFallback: Bool,
        completion: @escaping (String?) -> Void
    ) {
        readSelectedTextContext(
            preferClipboard: preferClipboard,
            allowClipboardFallback: allowClipboardFallback
        ) { selection in
            completion(selection?.text)
        }
    }

    func readSelectedTextContext(
        preferClipboard: Bool = false,
        allowClipboardFallback: Bool,
        completion: @escaping (SelectedTextContext?) -> Void
    ) {
        if preferClipboard {
            ClipboardSelectionReader.readSelectedText { [weak self] clipboardText in
                if let clipboardText, !clipboardText.isEmpty {
                    completion(SelectedTextContext(text: clipboardText, anchorPoint: nil))
                    return
                }
                completion(self?.readSelectedTextContext())
            }
            return
        }

        if let selection = readSelectedTextContext() {
            completion(selection)
            return
        }

        guard allowClipboardFallback else {
            completion(nil)
            return
        }

        ClipboardSelectionReader.readSelectedText { selectedText in
            guard let selectedText else {
                completion(nil)
                return
            }

            completion(SelectedTextContext(text: selectedText, anchorPoint: nil))
        }
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
        readSelectedTextContext()?.text
    }

    func readSelectedTextContext() -> SelectedTextContext? {
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

        return SelectedTextContext(
            text: trimmed,
            anchorPoint: nil
        )
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
        guard let range = selectedTextRange(from: element) else {
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

    private func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )

        guard rangeResult == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axRangeValue = rangeValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(axRangeValue) == .cfRange,
              AXValueGetValue(axRangeValue, .cfRange, &range),
              range.location >= 0,
              range.length > 0
        else {
            return nil
        }

        return range
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
    case captureFailedDetail(String)
    case noTextRecognized
    case screenRecordingPermissionDenied

    var errorDescription: String? {
        switch self {
        case .captureCancelled:
            "Screenshot selection was cancelled."
        case .captureFailed(let status):
            "Screenshot capture failed with exit code \(status)."
        case .captureFailedDetail(let message):
            "Screenshot capture failed: \(message)"
        case .noTextRecognized:
            "No readable text was found in the selected area."
        case .screenRecordingPermissionDenied:
            "Yaku needs Screen Recording permission to capture screenshots. Open System Settings → Privacy & Security → Screen Recording, enable Yaku, then quit and reopen the app."
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
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("yaku-screenshot-\(UUID().uuidString)")
                    .appendingPathExtension("png")

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", outputURL.path]
                let stderrPipe = Pipe()
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let stderrText = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let fileExists = FileManager.default.fileExists(atPath: outputURL.path)

                    if !fileExists {
                        if stderrText.isEmpty {
                            continuation.resume(throwing: ScreenshotTranslationError.captureCancelled)
                        } else if stderrText.localizedCaseInsensitiveContains("could not create image") {
                            continuation.resume(throwing: ScreenshotTranslationError.screenRecordingPermissionDenied)
                        } else {
                            continuation.resume(throwing: ScreenshotTranslationError.captureFailedDetail(stderrText))
                        }
                        return
                    }

                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: ScreenshotTranslationError.captureFailed(process.terminationStatus))
                        return
                    }

                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
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

final class TabKeyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onTab: @MainActor () -> Void

    init(onTab: @escaping @MainActor () -> Void) {
        self.onTab = onTab
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo, type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard keyCode == Int64(kVK_Tab) else {
                    return Unmanaged.passUnretained(event)
                }

                let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
                guard event.flags.intersection(modifierMask).isEmpty else {
                    return Unmanaged.passUnretained(event)
                }

                let interceptor = Unmanaged<TabKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                Task { @MainActor in
                    interceptor.onTab()
                }
                return nil
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func disable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    deinit {
        disable()
    }
}

final class CommandCopyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onCopy: @MainActor () -> Void

    init(onCopy: @escaping @MainActor () -> Void) {
        self.onCopy = onCopy
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo, type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard keyCode == Int64(kVK_ANSI_C) else {
                    return Unmanaged.passUnretained(event)
                }

                let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
                guard modifiers == .maskCommand else {
                    return Unmanaged.passUnretained(event)
                }

                let interceptor = Unmanaged<CommandCopyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                Task { @MainActor in
                    interceptor.onCopy()
                }
                return nil
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func disable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    deinit {
        disable()
    }
}

@MainActor
final class FloatingTranslateButtonController {
    private let panel: NSPanel
    private let selectedText: String
    private let onTranslate: (String) -> Void
    private let onSmartReply: (String) -> Void
    private let buttonView: FloatingTranslateButtonView
    private var currentMode: TranslationMode
    private var tabInterceptor: TabKeyInterceptor?

    init(
        screenPoint: NSPoint,
        selectedText: String,
        initialMode: TranslationMode,
        onTranslate: @escaping (String) -> Void,
        onSmartReply: @escaping (String) -> Void
    ) {
        self.selectedText = selectedText
        self.onTranslate = onTranslate
        self.onSmartReply = onSmartReply
        self.currentMode = initialMode

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
        buttonView = FloatingTranslateButtonView(initialMode: initialMode)
        buttonView.frame = NSRect(x: shadowPadding, y: shadowPadding, width: buttonSize, height: buttonSize)
        container.addSubview(buttonView)
        panel.contentView = container

        buttonView.onClick = { [weak self] in
            guard let self else { return }
            self.invokeCurrentMode()
        }
    }

    func show() {
        panel.orderFrontRegardless()
        let interceptor = TabKeyInterceptor { [weak self] in
            self?.toggleMode()
        }
        tabInterceptor = interceptor
        interceptor.enable()
    }

    func close() {
        tabInterceptor?.disable()
        tabInterceptor = nil
        panel.close()
    }

    private func toggleMode() {
        currentMode = (currentMode == .smartReply) ? .selection : .smartReply
        buttonView.apply(mode: currentMode)
    }

    private func invokeCurrentMode() {
        switch currentMode {
        case .selection, .draftMessage:
            onTranslate(selectedText)
        case .smartReply:
            onSmartReply(selectedText)
        }
    }
}

@MainActor
final class FloatingTranslateButtonView: NSView {
    var onClick: (() -> Void)?

    private let actionButton = NSButton()
    private var currentMode: TranslationMode

    init(initialMode: TranslationMode) {
        self.currentMode = initialMode
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        wantsLayer = true
        buildUI()
        apply(mode: initialMode)
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

        actionButton.target = self
        actionButton.action = #selector(buttonTapped)
        actionButton.frame = bounds
        actionButton.autoresizingMask = [.width, .height]
        actionButton.isBordered = false
        actionButton.contentTintColor = .white
        actionButton.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        actionButton.imageScaling = .scaleNone
        glass.contentView.addSubview(actionButton)
    }

    func apply(mode: TranslationMode) {
        currentMode = mode
        switch mode {
        case .selection, .draftMessage:
            actionButton.image = nil
            actionButton.title = "あ"
            actionButton.imagePosition = .noImage
            actionButton.toolTip = "Translate selection — Tab to switch to Reply"
        case .smartReply:
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            actionButton.image = NSImage(
                systemSymbolName: "bubble.left.fill",
                accessibilityDescription: "Generate reply or answer"
            )?.withSymbolConfiguration(config)
            actionButton.title = ""
            actionButton.imagePosition = .imageOnly
            actionButton.toolTip = "Generate reply — Tab to switch to Translate"
        }
    }

    @objc private func buttonTapped() {
        onClick?()
    }
}

final class TranslationPanelController {
    private let panel: NSPanel
    private let contentView: TranslationContentView
    private let anchorScreenPoint: NSPoint
    private var activeRequestID = UUID()
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    private var commandCopyInterceptor: CommandCopyInterceptor?

    var panelFrame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }

    private let loadingPlaceholder: String

    init(
        screenPoint: NSPoint,
        sourceText: String,
        targetLanguage: TranslationLanguage,
        resultLabel: String? = nil,
        loadingPlaceholder: String = "Translating",
        onTargetLanguageSelected: ((TranslationLanguage) -> Void)? = nil,
        onReplace: ((String) -> Void)? = nil
    ) {
        self.loadingPlaceholder = loadingPlaceholder
        anchorScreenPoint = screenPoint
        let visibleFrame = NSScreen.visibleFrame(containing: screenPoint)
        let panelHeight = min(
            TranslationContentView.preferredHeight(sourceText: sourceText, resultText: "\(loadingPlaceholder)..."),
            visibleFrame.height - 32
        )
        let panelSize = NSSize(width: TranslationContentView.preferredWidth, height: panelHeight)
        let originY = Self.panelOriginY(for: screenPoint.y, panelHeight: panelHeight, visibleFrame: visibleFrame)
        let origin = NSPoint(
            x: Self.panelOriginX(for: screenPoint.x, panelWidth: panelSize.width, visibleFrame: visibleFrame),
            y: originY
        )
        let anchorY = TranslationContentView.anchorY(
            for: screenPoint.y,
            panelOriginY: originY,
            panelHeight: panelHeight
        )

        contentView = TranslationContentView(
            sourceText: sourceText,
            targetLanguage: targetLanguage,
            resultLabel: resultLabel,
            anchorY: anchorY,
            onTargetLanguageSelected: onTargetLanguageSelected,
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
        contentView.onNeedsResize = { [weak self] in
            self?.resizeToFitContent(animated: true)
        }
    }

    deinit {
        removeOutsideClickMonitors()
        removeCommandCopyInterceptor()
    }

    @discardableResult
    func showLoading(targetLanguage: TranslationLanguage? = nil) -> UUID {
        activeRequestID = UUID()
        if let targetLanguage {
            contentView.setTargetLanguage(targetLanguage)
        }
        contentView.startLoadingAnimation(baseText: loadingPlaceholder)
        resizeToFitContent(animated: false)
        panel.orderFrontRegardless()
        installOutsideClickMonitors()
        installCommandCopyInterceptor()
        return activeRequestID
    }

    func showTranslation(_ text: String, requestID: UUID? = nil) {
        guard requestIsCurrent(requestID) else {
            return
        }

        contentView.setResult(text)
        resizeToFitContent(animated: false)
    }

    func showError(_ message: String, requestID: UUID? = nil) {
        guard requestIsCurrent(requestID) else {
            return
        }

        contentView.setResult("Error: \(message)")
        resizeToFitContent(animated: true)
    }

    func close() {
        contentView.stopLoadingAnimation()
        removeOutsideClickMonitors()
        removeCommandCopyInterceptor()
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

    private func installCommandCopyInterceptor() {
        guard commandCopyInterceptor == nil else {
            return
        }

        let interceptor = CommandCopyInterceptor { [weak self] in
            self?.copyResultAndClose()
        }
        commandCopyInterceptor = interceptor
        interceptor.enable()
    }

    private func removeCommandCopyInterceptor() {
        commandCopyInterceptor?.disable()
        commandCopyInterceptor = nil
    }

    private func copyResultAndClose() {
        guard panel.isVisible else {
            return
        }

        contentView.copyResultToPasteboard()
        close()
    }

    private func closeIfClickIsOutside(_ event: NSEvent) {
        guard panel.isVisible else {
            return
        }

        guard !contentView.isTargetLanguageMenuOpen else {
            return
        }

        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard !panel.frame.insetBy(dx: -4, dy: -4).contains(screenPoint) else {
            return
        }

        close()
    }

    private func requestIsCurrent(_ requestID: UUID?) -> Bool {
        guard let requestID else {
            return true
        }

        return requestID == activeRequestID
    }

    private func resizeToFitContent(animated: Bool) {
        let currentFrame = panel.frame
        let visibleFrame = NSScreen.visibleFrame(containing: NSPoint(x: currentFrame.midX, y: currentFrame.midY))
        let targetHeight = min(contentView.preferredHeightForCurrentContent(), visibleFrame.height - 32)
        let targetWidth = TranslationContentView.preferredWidth
        let preserveCurrentPosition = panel.isVisible
        let targetY = preserveCurrentPosition
            ? min(
                max(currentFrame.maxY - targetHeight, visibleFrame.minY + 16),
                visibleFrame.maxY - targetHeight - 16
            )
            : Self.panelOriginY(
                for: anchorScreenPoint.y,
                panelHeight: targetHeight,
                visibleFrame: visibleFrame
            )
        let targetAnchorY = TranslationContentView.anchorY(
            for: anchorScreenPoint.y,
            panelOriginY: targetY,
            panelHeight: targetHeight
        )
        contentView.setAnchorY(targetAnchorY)

        let targetFrame = NSRect(
            x: preserveCurrentPosition
                ? min(max(currentFrame.minX, visibleFrame.minX + 16), visibleFrame.maxX - targetWidth - 16)
                : Self.panelOriginX(for: anchorScreenPoint.x, panelWidth: targetWidth, visibleFrame: visibleFrame),
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

    private static func panelOriginX(for anchorX: CGFloat, panelWidth: CGFloat, visibleFrame: NSRect) -> CGFloat {
        let desiredX = anchorX + 5
        return min(max(desiredX, visibleFrame.minX + 16), visibleFrame.maxX - panelWidth - 16)
    }

    private static func panelOriginY(for anchorY: CGFloat, panelHeight: CGFloat, visibleFrame: NSRect) -> CGFloat {
        let desiredY = anchorY - panelHeight * 0.52
        return min(max(desiredY, visibleFrame.minY + 16), visibleFrame.maxY - panelHeight - 16)
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

final class GlassChromeOverlayView: NSView {
    var cornerRadius: CGFloat = 22

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let innerRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: max(0, cornerRadius - 1), yRadius: max(0, cornerRadius - 1))
        NSColor(calibratedWhite: 1.0, alpha: 0.06).setStroke()
        innerPath.lineWidth = 1
        innerPath.stroke()
    }
}

final class HairlineSeparatorView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
        bounds.fill()
    }
}

final class LanguagePickerButton: NSButton {
    static let titleLeadingInset: CGFloat = 8

    private static let horizontalPadding: CGFloat = 8
    private static let chevronGap: CGFloat = 8
    private static let chevronWidth: CGFloat = 10
    private static let chevronHeight: CGFloat = 16
    private static let chevronBackgroundSize: CGFloat = 18

    private let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private let titleColor = NSColor(calibratedRed: 0.12, green: 0.58, blue: 1.0, alpha: 0.96)

    private var hoverTrackingArea: NSTrackingArea?
    private var displayTitle = ""
    private var isHovered = false
    private var isMenuOpen = false
    private var pickerEnabled = true

    var preferredWidth: CGFloat {
        let titleWidth = ceil((displayTitle as NSString).size(withAttributes: [.font: titleFont]).width)
        let affordanceWidth = pickerEnabled ? Self.chevronGap + Self.chevronBackgroundSize : 0
        let paddedWidth = titleWidth + Self.horizontalPadding * 2 + affordanceWidth
        return min(max(paddedWidth, 64), 220)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        alignment = .left
        focusRingType = .none
        title = ""
        setButtonType(.momentaryChange)
        applyStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard pickerEnabled else {
            return
        }

        isHovered = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyStyle()
    }

    override func draw(_ dirtyRect: NSRect) {
        let title = NSAttributedString(string: displayTitle, attributes: [
            .font: titleFont,
            .foregroundColor: titleColor,
            .kern: 0
        ])
        let titleSize = title.size()
        let titleOrigin = NSPoint(
            x: Self.horizontalPadding,
            y: floor((bounds.height - titleSize.height) / 2) - 1
        )
        title.draw(at: titleOrigin)

        guard pickerEnabled && (isHovered || isMenuOpen || isHighlighted),
              bounds.width > Self.horizontalPadding * 2 + Self.chevronBackgroundSize
        else {
            return
        }

        drawChevronPair()
    }

    private func drawChevronPair() {
        let backgroundRect = NSRect(
            x: bounds.maxX - Self.horizontalPadding - Self.chevronBackgroundSize,
            y: floor((bounds.height - Self.chevronBackgroundSize) / 2),
            width: Self.chevronBackgroundSize,
            height: Self.chevronBackgroundSize
        )
        NSColor(calibratedWhite: 1.0, alpha: 0.11).setFill()
        NSBezierPath(ovalIn: backgroundRect).fill()

        let origin = NSPoint(
            x: backgroundRect.midX - Self.chevronWidth / 2,
            y: floor((bounds.height - Self.chevronHeight) / 2)
        )
        let midX = origin.x + Self.chevronWidth / 2
        let rightX = origin.x + Self.chevronWidth

        NSColor(calibratedWhite: 1.0, alpha: 0.88).setStroke()

        let up = NSBezierPath()
        up.lineWidth = 2.0
        up.lineCapStyle = .round
        up.lineJoinStyle = .round
        up.move(to: NSPoint(x: origin.x + 1, y: origin.y + 10))
        up.line(to: NSPoint(x: midX, y: origin.y + 14))
        up.line(to: NSPoint(x: rightX - 1, y: origin.y + 10))
        up.stroke()

        let down = NSBezierPath()
        down.lineWidth = 2.0
        down.lineCapStyle = .round
        down.lineJoinStyle = .round
        down.move(to: NSPoint(x: origin.x + 1, y: origin.y + 6))
        down.line(to: NSPoint(x: midX, y: origin.y + 2))
        down.line(to: NSPoint(x: rightX - 1, y: origin.y + 6))
        down.stroke()
    }

    func setTitle(_ title: String, pickerEnabled: Bool) {
        displayTitle = title
        self.pickerEnabled = pickerEnabled
        toolTip = pickerEnabled ? "Choose translation language" : nil
        isEnabled = true
        applyStyle()
        needsLayout = true
    }

    func setMenuOpen(_ isMenuOpen: Bool) {
        self.isMenuOpen = isMenuOpen
        applyStyle()
    }

    private func applyStyle() {
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
        needsDisplay = true
    }
}

final class SourcePreviewView: NSView {
    private static let moreButtonWidth: CGFloat = 50
    private static let moreGap: CGFloat = 8
    private static let sourceTextYOffset: CGFloat = 2
    private static let moreButtonYOffset: CGFloat = 1

    private let textLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton(title: "more", target: nil, action: nil)
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var canExpand = false

    var onMore: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        textLabel.font = NSFont.systemFont(ofSize: TranslationContentView.sourceFontSize, weight: .semibold)
        textLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.90)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.usesSingleLineMode = true
        addSubview(textLabel)

        moreButton.target = self
        moreButton.action = #selector(moreTapped)
        moreButton.isBordered = false
        moreButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        moreButton.contentTintColor = NSColor(calibratedRed: 0.12, green: 0.58, blue: 1.0, alpha: 1.0)
        moreButton.isHidden = true
        moreButton.toolTip = "Show full source"
        addSubview(moreButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateMoreVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateMoreVisibility()
    }

    override func layout() {
        super.layout()
        let buttonVisible = !moreButton.isHidden
        let labelWidth = buttonVisible
            ? max(0, bounds.width - Self.moreButtonWidth - Self.moreGap)
            : bounds.width
        let sourceTextHeight = ceil(textLabel.intrinsicContentSize.height)
        let moreButtonHeight = ceil(moreButton.intrinsicContentSize.height)
        let rowHeight = max(sourceTextHeight, moreButtonHeight)
        let rowY = floor((bounds.height - rowHeight) / 2)
        textLabel.frame = NSRect(
            x: 0,
            y: rowY + Self.sourceTextYOffset,
            width: labelWidth,
            height: rowHeight
        )
        moreButton.frame = NSRect(
            x: bounds.maxX - Self.moreButtonWidth,
            y: rowY + Self.moreButtonYOffset,
            width: Self.moreButtonWidth,
            height: rowHeight
        )
    }

    func configure(text: String, canExpand: Bool) {
        textLabel.stringValue = text
        self.canExpand = canExpand
        updateMoreVisibility()
    }

    private func updateMoreVisibility() {
        moreButton.isHidden = !(canExpand && isHovered)
        needsLayout = true
    }

    @objc private func moreTapped() {
        onMore?()
    }
}

final class TranslationContentView: NSView {
    static let bodyWidth: CGFloat = 400
    static let preferredWidth: CGFloat = bodyWidth
    private static let minHeight: CGFloat = 168
    private static let maxHeight: CGFloat = 540
    private static let contentWidth: CGFloat = 364
    static let sourceFontSize: CGFloat = 16
    private static let collapsedSourceBoxHeight: CGFloat = 34
    private static let minimumExpandedSourceBoxHeight: CGFloat = 48
    private static let minimumResultBoxHeight: CGFloat = 58
    private static let maximumSourceBoxHeight: CGFloat = 140
    private static let maximumResultBoxHeight: CGFloat = 340

    private static let panelPaddingX: CGFloat = 18
    private static let panelPaddingTop: CGFloat = 20
    private static let panelPaddingBottom: CGFloat = 18
    private static let labelHeight: CGFloat = 18
    private static let labelToBoxGap: CGFloat = 8
    private static let sourceToDividerGap: CGFloat = 13
    private static let dividerToTargetGap: CGFloat = 16
    private static let dividerHeight: CGFloat = 1
    private static let buttonSize: CGFloat = 18
    private static let resultFontSize: CGFloat = 18
    private static let textInsetY: CGFloat = 3
    private static let scrollableTextBottomPadding: CGFloat = 18

    var onClose: (() -> Void)?
    var onNeedsResize: (() -> Void)?

    private let sourceText: String
    private var targetLanguage: TranslationLanguage
    private let resultLabel: String?
    private var resultText = "Translating..."
    private var resultDisplayText = "Translating..."
    private let resultTextView = NSTextView()
    private let sourceTitleLabel = NSTextField(labelWithString: "")
    private let sourcePreviewView = SourcePreviewView(frame: .zero)
    private let targetTitleButton = LanguagePickerButton(frame: .zero)
    private let sourceTextView = NSTextView()
    private let sourceScrollView = NSScrollView()
    private let resultScrollView = NSScrollView()
    private let sourceDivider = HairlineSeparatorView()
    private var panelGlass: GlassHostView?
    private var chromeOverlay: GlassChromeOverlayView?
    private var closeButton: NSButton?
    private var copyButton: NSButton?
    private var replaceButton: NSButton?
    private var sourceExpanded = false
    private var shouldScrollSourceToTop = true
    private var shouldScrollResultToTop = true
    private var anchorYValue: CGFloat
    private let onTargetLanguageSelected: ((TranslationLanguage) -> Void)?
    private let onReplace: ((String) -> Void)?
    private var loadingBaseText: String?
    private var loadingTimer: Timer?
    private var loadingDotCount = 0
    private var isInternalLoadingUpdate = false

    var isTargetLanguageMenuOpen = false

    init(
        sourceText: String,
        targetLanguage: TranslationLanguage,
        resultLabel: String? = nil,
        anchorY: CGFloat,
        onTargetLanguageSelected: ((TranslationLanguage) -> Void)? = nil,
        onReplace: ((String) -> Void)? = nil
    ) {
        self.sourceText = sourceText
        self.targetLanguage = targetLanguage
        self.resultLabel = resultLabel
        self.anchorYValue = anchorY
        self.onTargetLanguageSelected = onTargetLanguageSelected
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

    static func preferredHeight(sourceText: String, resultText: String, sourceExpanded: Bool = false) -> CGFloat {
        let sourceBoxHeight = sourceHeight(for: sourceText, expanded: sourceExpanded)
        let resultBoxHeight = boxHeight(
            for: resultText,
            font: NSFont.systemFont(ofSize: resultFontSize, weight: .semibold),
            width: contentWidth,
            minimum: minimumResultBoxHeight,
            maximum: maximumResultBoxHeight
        )

        let fixedHeight = panelPaddingTop
            + labelHeight + labelToBoxGap
            + sourceToDividerGap + dividerHeight + dividerToTargetGap
            + labelHeight + labelToBoxGap
            + panelPaddingBottom
        return min(max(fixedHeight + sourceBoxHeight + resultBoxHeight, minHeight), maxHeight)
    }

    func preferredHeightForCurrentContent() -> CGFloat {
        Self.preferredHeight(sourceText: sourceText, resultText: resultDisplayText, sourceExpanded: sourceExpanded)
    }

    static func anchorY(for screenY: CGFloat, panelOriginY: CGFloat, panelHeight: CGFloat) -> CGFloat {
        min(max(screenY - panelOriginY, 0), panelHeight)
    }

    func setAnchorY(_ anchorY: CGFloat) {
        guard abs(anchorYValue - anchorY) >= 0.5 else {
            return
        }
        anchorYValue = anchorY
        layoutForCurrentSize()
    }

    func setTargetLanguage(_ language: TranslationLanguage) {
        guard resultLabel == nil else {
            return
        }

        targetLanguage = language
        targetTitleButton.setTitle(language.displayName, pickerEnabled: true)
        layoutForCurrentSize()
    }

    private func expandSource() {
        guard !sourceExpanded else {
            return
        }

        sourceExpanded = true
        shouldScrollSourceToTop = true
        onNeedsResize?()
        layoutForCurrentSize()
    }

    private static func boxHeight(for text: String, font: NSFont, width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let height = textHeight(for: text, font: font, width: width) + textInsetY * 2 + 4
        return min(max(height, minimum), maximum)
    }

    private static func sourceHeight(for text: String, expanded: Bool) -> CGFloat {
        guard expanded else {
            return collapsedSourceBoxHeight
        }

        return boxHeight(
            for: text,
            font: NSFont.systemFont(ofSize: sourceFontSize, weight: .semibold),
            width: contentWidth,
            minimum: minimumExpandedSourceBoxHeight,
            maximum: maximumSourceBoxHeight
        )
    }

    private static func singleLineWidth(for text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func collapsedSourceText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func layoutScrollableTextView(
        _ textView: NSTextView,
        inside scrollView: NSScrollView,
        scrollFrame: NSRect,
        rawTextHeight: CGFloat,
        showsOverflowScroller: Bool = true
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
        scrollView.hasVerticalScroller = showsOverflowScroller && !fitsInScrollFrame
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
            frame: NSRect(x: 0, y: 0, width: Self.bodyWidth, height: bounds.height),
            cornerRadius: 22,
            tintColor: NSColor(calibratedRed: 0.10, green: 0.095, blue: 0.045, alpha: 0.72),
            style: .regular
        )
        panelGlass.autoresizingMask = [.height]
        addSubview(panelGlass)
        let content = panelGlass.contentView
        self.panelGlass = panelGlass

        configureSectionLabel(
            sourceTitleLabel,
            text: "Source",
            color: NSColor(calibratedWhite: 1.0, alpha: 0.74)
        )
        content.addSubview(sourceTitleLabel)

        closeButton = makeIconButton(
            symbolName: "xmark",
            accessibilityDescription: "Close",
            pointSize: 10,
            target: self,
            action: #selector(closeTapped),
            to: content
        )

        configureScrollView(sourceScrollView)
        configureTextView(
            sourceTextView,
            text: sourceText,
            font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold),
            color: NSColor(calibratedWhite: 1.0, alpha: 0.90)
        )
        sourceScrollView.documentView = sourceTextView
        sourceScrollView.isHidden = true
        sourcePreviewView.onMore = { [weak self] in
            self?.expandSource()
        }
        content.addSubview(sourcePreviewView)
        content.addSubview(sourceScrollView)
        content.addSubview(sourceDivider)

        targetTitleButton.target = self
        targetTitleButton.action = #selector(showTargetLanguageMenu)
        targetTitleButton.setTitle(resultLabel ?? targetLanguage.displayName, pickerEnabled: resultLabel == nil)
        content.addSubview(targetTitleButton)

        copyButton = makeIconButton(
            symbolName: "doc.on.doc",
            accessibilityDescription: "Copy translation",
            pointSize: 11,
            target: self,
            action: #selector(copyResult),
            to: content
        )
        copyButton?.contentTintColor = NSColor(calibratedRed: 0.12, green: 0.58, blue: 1.0, alpha: 0.90)

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
            replaceButton.contentTintColor = NSColor(calibratedRed: 0.12, green: 0.58, blue: 1.0, alpha: 0.38)
            self.replaceButton = replaceButton
        }

        configureScrollView(resultScrollView)
        configureTextView(
            resultTextView,
            text: resultText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
            color: NSColor(calibratedRed: 0.12, green: 0.58, blue: 1.0, alpha: 1.0)
        )
        resultScrollView.documentView = resultTextView
        content.addSubview(resultScrollView)

        let chromeOverlay = GlassChromeOverlayView(frame: content.bounds)
        chromeOverlay.autoresizingMask = [.width, .height]
        content.addSubview(chromeOverlay)
        self.chromeOverlay = chromeOverlay

        setResult(resultText)
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

    private func configureSectionLabel(_ label: NSTextField, text: String, color: NSColor) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: color,
            .kern: 0
        ])
        label.attributedStringValue = attributed
    }

    func layoutForCurrentSize() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bodyHeight = bounds.height
        panelGlass?.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.bodyWidth,
            height: bodyHeight
        )
        chromeOverlay?.frame = NSRect(x: 0, y: 0, width: Self.bodyWidth, height: bodyHeight)

        let sourceBoxHeight = Self.sourceHeight(for: sourceText, expanded: sourceExpanded)
        let fixedHeight = Self.panelPaddingTop
            + Self.labelHeight + Self.labelToBoxGap
            + Self.sourceToDividerGap + Self.dividerHeight + Self.dividerToTargetGap
            + Self.labelHeight + Self.labelToBoxGap
            + Self.panelPaddingBottom
        let availableBoxHeight = max(
            Self.collapsedSourceBoxHeight + Self.minimumResultBoxHeight,
            bounds.height - fixedHeight
        )
        let resolvedSourceBoxHeight = min(
            sourceBoxHeight,
            max(Self.collapsedSourceBoxHeight, availableBoxHeight - Self.minimumResultBoxHeight)
        )
        let resolvedResultBoxHeight = max(Self.minimumResultBoxHeight, availableBoxHeight - resolvedSourceBoxHeight)

        var y = bodyHeight - Self.panelPaddingTop - Self.labelHeight
        sourceTitleLabel.frame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth - Self.buttonSize - 8,
            height: Self.labelHeight
        )
        closeButton?.frame = NSRect(
            x: Self.bodyWidth - Self.panelPaddingX - Self.buttonSize,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )

        y -= Self.labelToBoxGap + resolvedSourceBoxHeight
        let sourceScrollFrame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: resolvedSourceBoxHeight
        )
        let collapsedSourceText = Self.collapsedSourceText(sourceText)
        let sourceCanExpand = Self.singleLineWidth(
            for: collapsedSourceText,
            font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold)
        ) > Self.contentWidth
            || collapsedSourceText != sourceText.trimmingCharacters(in: .whitespacesAndNewlines)

        sourcePreviewView.frame = sourceScrollFrame
        sourcePreviewView.configure(text: collapsedSourceText, canExpand: sourceCanExpand)
        sourcePreviewView.isHidden = sourceExpanded
        sourceScrollView.isHidden = !sourceExpanded

        if sourceExpanded {
            let sourceRawTextHeight = Self.textHeight(
                for: sourceText,
                font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold),
                width: sourceScrollFrame.width
            )
            Self.layoutScrollableTextView(
                sourceTextView,
                inside: sourceScrollView,
                scrollFrame: sourceScrollFrame,
                rawTextHeight: sourceRawTextHeight,
                showsOverflowScroller: true
            )
            if shouldScrollSourceToTop {
                scrollToTop(sourceScrollView)
                shouldScrollSourceToTop = false
            }
        }

        y -= Self.sourceToDividerGap + Self.dividerHeight
        sourceDivider.frame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: Self.dividerHeight
        )

        y -= Self.dividerToTargetGap + Self.labelHeight
        let targetActionButtonCount = replaceButton == nil ? 1 : 2
        let targetActionWidth = CGFloat(targetActionButtonCount) * Self.buttonSize
            + CGFloat(max(0, targetActionButtonCount - 1)) * 8
        let targetTitleLeadingInset = LanguagePickerButton.titleLeadingInset
        targetTitleButton.frame = NSRect(
            x: Self.panelPaddingX - targetTitleLeadingInset,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: min(
                targetTitleButton.preferredWidth,
                Self.contentWidth - targetActionWidth - 8 + targetTitleLeadingInset
            ),
            height: Self.buttonSize
        )
        copyButton?.frame = NSRect(
            x: Self.bodyWidth - Self.panelPaddingX - Self.buttonSize,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )
        replaceButton?.frame = NSRect(
            x: Self.bodyWidth - Self.panelPaddingX - Self.buttonSize * 2 - 8,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )

        y -= Self.labelToBoxGap + resolvedResultBoxHeight
        let resultScrollFrame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: resolvedResultBoxHeight
        )
        let resultRawTextHeight = Self.textHeight(
            for: resultDisplayText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
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
        if !isInternalLoadingUpdate {
            stopLoadingAnimation()
        }
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

    func startLoadingAnimation(baseText: String) {
        stopLoadingAnimation()
        loadingBaseText = baseText
        loadingDotCount = 0
        renderLoadingFrame()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLoadingAnimation() }
        }
        loadingTimer = timer
    }

    func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
        loadingBaseText = nil
    }

    var isShowingLoadingState: Bool { loadingBaseText != nil }

    private func tickLoadingAnimation() {
        guard loadingBaseText != nil else { return }
        loadingDotCount = (loadingDotCount + 1) % 4
        renderLoadingFrame()
    }

    private func renderLoadingFrame() {
        guard let baseText = loadingBaseText else { return }
        let dots = String(repeating: ".", count: loadingDotCount)
        isInternalLoadingUpdate = true
        setResult("\(baseText)\(dots)")
        isInternalLoadingUpdate = false
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

    @objc private func showTargetLanguageMenu() {
        guard resultLabel == nil else {
            return
        }

        let menu = NSMenu()
        for language in TranslationLanguage.all {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(selectTemporaryTargetLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.id
            item.state = language.id == targetLanguage.id ? .on : .off
            menu.addItem(item)
        }

        isTargetLanguageMenuOpen = true
        targetTitleButton.setMenuOpen(true)
        _ = menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: -4),
            in: targetTitleButton
        )
        targetTitleButton.setMenuOpen(false)
        isTargetLanguageMenuOpen = false
    }

    @objc private func selectTemporaryTargetLanguage(_ sender: NSMenuItem) {
        guard let languageID = sender.representedObject as? String else {
            return
        }

        let language = TranslationLanguage.language(id: languageID)
        guard language != targetLanguage else {
            return
        }

        setTargetLanguage(language)
        onTargetLanguageSelected?(language)
    }

    @objc private func copyResult() {
        copyResultToPasteboard()
    }

    func copyResultToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultTextView.string, forType: .string)
    }

    @objc private func replaceSelectedText() {
        let replacement = TextNormalizer.cleanedTranslation(resultTextView.string)
        guard !replacement.isEmpty,
              !isShowingLoadingState,
              !replacement.hasPrefix("Error:")
        else {
            return
        }

        onReplace?(replacement)
    }

    @objc private func closeTapped() {
        onClose?()
    }

    private func updateReplaceButtonState() {
        guard let replaceButton else {
            return
        }

        let replacement = TextNormalizer.cleanedTranslation(resultTextView.string)
        let canReplace = !replacement.isEmpty
            && !isShowingLoadingState
            && !replacement.hasPrefix("Error:")
        replaceButton.isEnabled = canReplace
        replaceButton.contentTintColor = NSColor(
            calibratedRed: 0.12,
            green: 0.58,
            blue: 1.0,
            alpha: canReplace ? 0.86 : 0.38
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

enum TranslationMode {
    case selection
    case draftMessage
    case smartReply

    var resultLabel: String? {
        switch self {
        case .selection, .draftMessage:
            return nil
        case .smartReply:
            return "Reply"
        }
    }

    var loadingPlaceholder: String {
        switch self {
        case .smartReply:
            return "Thinking"
        case .selection, .draftMessage:
            return "Translating"
        }
    }

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
        case .smartReply:
            """
            The user has selected text in another app. The text is either (a) a message they received — email, chat message, DM, comment, support ticket, or similar; or (b) a question they need to answer — a quiz item, exam question, multiple-choice question, or open question. Decide which it is from the text itself, then respond appropriately. Always respond in the SAME language as the source text. Never translate.

            If it is a received message: write a natural, ready-to-send reply as if the user is sending it now. Match the tone, register, formality, and length of the original. Be concise. Don't restate or quote the original. Don't add greetings or sign-offs unless the original suggests them. Don't address the user — produce only the message body they would paste into the reply field.

            If it is a multiple-choice question: identify the correct option and respond with the option letter or number followed by the option text, then a brief one-sentence justification. Example: "B. Mitochondria — they generate most of the cell's ATP."

            If it is an open question: give a clear, direct answer. Keep it short unless the question demands depth.

            Return only the reply or answer text. No commentary, no labels, no preface, no explanation of what you're doing, no quotes around the answer.
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
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let sourceText: String
        switch mode {
        case .selection, .smartReply:
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
            think: thinkingLevel.rawValue,
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
