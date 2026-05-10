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
    case selectionDisplayMode = 115
    case usageStatsSummary = 116
    case writingStyle = 117
    case cleanupLevel = 118
    case snippets = 119
    case replacementMode = 120
    case keyboardShortcuts = 121
    case translateOrReplySelection = 122
    case resetSettings = 123
}

struct OllamaModelOption: Equatable {
    let id: String
    let displayName: String
    let isCloud: Bool

    static let all: [OllamaModelOption] = [
        .init(id: "gpt-oss:120b-cloud", displayName: "Online (fast, needs sign-in)", isCloud: true),
        .init(id: "gpt-oss:20b", displayName: "Offline (slower, works without internet)", isCloud: false)
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
        "Thinking: \(rawValue)"
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
        case .translate: return "Main mode: translate"
        case .smartReply: return "Main mode: reply"
        }
    }
}

private enum SelectionDisplayMode: String, CaseIterable {
    case floatingBar
    case pet
    case off

    var menuTitle: String {
        switch self {
        case .floatingBar: return "Floating bar"
        case .pet: return "Pet mode"
        case .off: return "Off"
        }
    }

    var settingsTitle: String {
        switch self {
        case .floatingBar: return "Display: floating bar"
        case .pet: return "Display: pet mode"
        case .off: return "Display: off"
        }
    }
}

private enum ReplacementMode: String, CaseIterable {
    case instantInsert
    case showPanel

    var menuTitle: String {
        switch self {
        case .instantInsert: return "Insert without preview"
        case .showPanel: return "Show preview panel"
        }
    }

    var settingsTitle: String {
        switch self {
        case .instantInsert: return "Replace action: insert without preview"
        case .showPanel: return "Replace action: show preview panel"
        }
    }
}

private struct GlobalHotKeyDefinition {
    static let signature = OSType(0x54524E53) // TRNS

    let id: UInt32
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let modifierFlags: NSEvent.ModifierFlags
    let displayString: String

    init(action: GlobalShortcutAction, shortcut: GlobalShortcut) {
        id = action.id
        keyCode = shortcut.keyCode
        carbonModifiers = shortcut.carbonModifiers
        modifierFlags = shortcut.modifiers
        displayString = shortcut.displayString
    }
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
        return modifiers.intersection(GlobalShortcut.supportedModifiers) == definition.modifierFlags
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
    let appCategory: AppCategory
    let cleanup: CleanupLevel
    private let ollamaClient: OllamaClient
    private var task: Task<Void, Never>?
    private var state: State = .pending
    private var partialTranslation = ""
    private var subscribers: [(String) -> Void] = []
    private var completionSubscribers: [(String) -> Void] = []
    private var failureSubscribers: [(String) -> Void] = []
    private let onComplete: (String, TranslationLanguage, ThinkingLevel, String) -> Void

    init(
        text: String,
        targetLanguage: TranslationLanguage,
        thinkingLevel: ThinkingLevel,
        appCategory: AppCategory,
        cleanup: CleanupLevel,
        ollamaClient: OllamaClient,
        onComplete: @escaping (String, TranslationLanguage, ThinkingLevel, String) -> Void
    ) {
        self.text = text
        self.targetLanguage = targetLanguage
        self.thinkingLevel = thinkingLevel
        self.appCategory = appCategory
        self.cleanup = cleanup
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

    func subscribe(
        onPartial: @escaping (String) -> Void,
        onCompletion: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        if !partialTranslation.isEmpty {
            onPartial(partialTranslation)
        }

        switch state {
        case .completed(let translation):
            onPartial(translation)
            onCompletion(translation)
        case .failed(let message):
            onFailure(message)
        default:
            subscribers.append(onPartial)
            completionSubscribers.append(onCompletion)
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
        completionSubscribers.removeAll()
        failureSubscribers.removeAll()
    }

    private func start() async {
        guard case .pending = state else { return }
        state = .running

        do {
            let finalTranslation = try await ollamaClient.translate(
                text,
                to: targetLanguage,
                appCategory: appCategory,
                style: .casual,
                cleanup: cleanup,
                snippets: [],
                thinkingLevel: thinkingLevel
            ) { [weak self] partial in
                Task { @MainActor in
                    self?.publishPartial(partial)
                }
            }
            state = .completed(finalTranslation)
            onComplete(text, targetLanguage, thinkingLevel, finalTranslation)
            publishPartial(finalTranslation)
            completionSubscribers.forEach { $0(finalTranslation) }
            subscribers.removeAll()
            completionSubscribers.removeAll()
            failureSubscribers.removeAll()
        } catch is CancellationError {
            markCancelled()
        } catch {
            let message = error.localizedDescription
            state = .failed(message)
            failureSubscribers.forEach { $0(message) }
            subscribers.removeAll()
            completionSubscribers.removeAll()
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
        completionSubscribers.removeAll()
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

    func translation(for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel, cleanup: CleanupLevel) -> String? {
        let key = cacheKey(for: text, targetLanguage: targetLanguage, thinkingLevel: thinkingLevel, cleanup: cleanup)
        guard let translation = entries[key] else {
            return nil
        }

        markRecentlyUsed(key)
        return translation
    }

    func store(_ translation: String, for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel, cleanup: CleanupLevel) {
        let key = cacheKey(for: text, targetLanguage: targetLanguage, thinkingLevel: thinkingLevel, cleanup: cleanup)
        guard !key.isEmpty, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        entries[key] = translation
        markRecentlyUsed(key)
        trimIfNeeded()
    }

    private func cacheKey(for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel, cleanup: CleanupLevel) -> String {
        "\(targetLanguage.id):\(thinkingLevel.rawValue):\(cleanup.rawValue):\(TextNormalizer.cleanedSelection(text))"
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
    private var floatingLoadingBar: FloatingTranslateButtonController?
    private var petController: PetController?
    private var translationPanelController: TranslationPanelController?
    private var translationPrefetch: TranslationPrefetch?
    private var isScreenshotTranslationRunning = false
    private var screenshotDragStartLocation: NSPoint?
    private var screenshotDragEndLocation: NSPoint?
    private var screenshotPanelSide: TranslationPanelController.Side?
    private var screenshotDragTracker: ScreenshotDragTracker?
    private var globalHotKeys: [GlobalHotKey] = []
    private var shortcutRecorderWindowController: ShortcutRecorderWindowController?
    private var lastReplacementSourcePID: pid_t?
    private var translationCache = TranslationCache()
    private let usageStatsStore = UsageStatsStore()
    private let snippetsStore = SnippetsStore()
    private lazy var bootstrap: OllamaBootstrap = OllamaBootstrap(
        baseURL: ollamaBaseURL,
        model: selectedModelID
    )
    private var onboardingWindowController: OnboardingWindowController?
    private var snippetsWindowController: SnippetsWindowController?
    private var accessibilityTrustTimer: Timer?
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard isRunningFromAppBundle else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()
    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
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
    private var selectionDisplayMode: SelectionDisplayMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "selectionDisplayMode") ?? SelectionDisplayMode.floatingBar.rawValue
            return SelectionDisplayMode(rawValue: raw) ?? .floatingBar
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectionDisplayMode")
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
    private var cleanupLevel: CleanupLevel {
        get {
            let raw = UserDefaults.standard.string(forKey: "cleanupLevel") ?? CleanupLevel.light.rawValue
            return CleanupLevel(rawValue: raw) ?? .light
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "cleanupLevel")
        }
    }

    private var replacementMode: ReplacementMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "replacementMode") ?? ReplacementMode.instantInsert.rawValue
            return ReplacementMode(rawValue: raw) ?? .instantInsert
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "replacementMode")
        }
    }

    private func writingStyle(for category: AppCategory) -> WritingStyle {
        let key = "writingStyle.\(category.rawValue)"
        if let raw = UserDefaults.standard.string(forKey: key),
           let style = WritingStyle(rawValue: raw) {
            return style
        }
        return Self.defaultStyle(for: category)
    }

    private func setWritingStyle(_ style: WritingStyle, for category: AppCategory) {
        UserDefaults.standard.set(style.rawValue, forKey: "writingStyle.\(category.rawValue)")
    }

    private static func defaultStyle(for category: AppCategory) -> WritingStyle {
        switch category {
        case .personalMessages, .other: return .casual
        case .workMessages, .email: return .formal
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
        // AX default messaging timeout is 6s. Parameterized calls (e.g.
        // kAXBoundsForRangeParameterizedAttribute) can stall the main thread
        // when an unsupported app responds slowly. Cap it.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5)
        setupStatusItem()
        requestAccessibilityPermissionIfNeeded()
        requestScreenRecordingPermissionIfNeeded()
        startMouseMonitor()
        applySelectionDisplayMode()
        setupGlobalHotKeys()
        setupBootstrap()
        snippetsStore.onChange = { [weak self] in
            self?.translationCache = TranslationCache()
            self?.cancelPrefetch()
        }
        _ = updaterController
    }

    private func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut {
        GlobalShortcutStore.shortcut(for: action)
    }

    private func setupGlobalHotKeys() {
        globalHotKeys.forEach { $0.unregister() }

        let screenshotHotKey = GlobalHotKey(
            definition: GlobalHotKeyDefinition(
                action: .screenshotArea,
                shortcut: shortcut(for: .screenshotArea)
            )
        ) { [weak self] in
            self?.startScreenshotTranslation()
        }
        let translateSelectionHotKey = GlobalHotKey(
            definition: GlobalHotKeyDefinition(
                action: .translateSelection,
                shortcut: shortcut(for: .translateSelection)
            )
        ) { [weak self] in
            self?.startSelectedTextTranslationForReplacement()
        }
        let translateOrReplyHotKey = GlobalHotKey(
            definition: GlobalHotKeyDefinition(
                action: .translateOrReply,
                shortcut: shortcut(for: .translateOrReply)
            )
        ) { [weak self] in
            self?.startSelectionTranslateOrReply()
        }
        globalHotKeys = [
            screenshotHotKey,
            translateSelectionHotKey,
            translateOrReplyHotKey
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
        petController?.close()
        globalHotKeys.forEach { $0.unregister() }
        accessibilityTrustTimer?.invalidate()
        accessibilityTrustTimer = nil
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
            title: "Open accessibility settings...",
            tag: .accessibilitySettings,
            symbolName: "gearshape",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        ))

        let permissionSeparator = NSMenuItem.separator()
        permissionSeparator.tag = MenuItemTag.permissionSeparator.rawValue
        menu.addItem(permissionSeparator)

        let usageSummaryItem = UsageStatsMenuItem(store: usageStatsStore)
        usageSummaryItem.tag = MenuItemTag.usageStatsSummary.rawValue
        menu.addItem(usageSummaryItem)

        menu.addItem(makeMenuItem(
            title: "Translator setup needed",
            tag: .bootstrapNotice,
            symbolName: "bolt.badge.clock",
            isEnabled: false
        ))
        menu.addItem(makeMenuItem(
            title: "Open setup...",
            tag: .bootstrapAction,
            symbolName: "wrench.and.screwdriver",
            action: #selector(openOnboardingWindow),
            keyEquivalent: ""
        ))

        let bootstrapSeparator = NSMenuItem.separator()
        bootstrapSeparator.tag = MenuItemTag.bootstrapSeparator.rawValue
        menu.addItem(bootstrapSeparator)

        menu.addItem(makeSectionHeader("Main settings"))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .floatingDefaultMode,
            symbolName: "bolt.circle",
            submenu: makeFloatingDefaultModeMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .selectionDisplayMode,
            symbolName: "pawprint.fill",
            submenu: makeSelectionDisplayModeMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .replacementMode,
            symbolName: "return",
            submenu: makeReplacementModeMenu()
        ))

        menu.addItem(makeSectionHeader("Shortcuts"))
        menu.addItem(makeMenuItem(
            title: "Rewrite my text...",
            tag: .translateSelection,
            symbolName: "text.insert",
            action: #selector(translateSelectedTextFromMenu),
            keyEquivalent: shortcut(for: .translateSelection).menuKeyEquivalent,
            keyEquivalentModifierMask: shortcut(for: .translateSelection).keyEquivalentModifierMask
        ))

        menu.addItem(makeMenuItem(
            title: "Translate screen area...",
            tag: .screenshotArea,
            symbolName: "viewfinder",
            action: #selector(translateScreenshotAreaFromMenu),
            keyEquivalent: shortcut(for: .screenshotArea).menuKeyEquivalent,
            keyEquivalentModifierMask: shortcut(for: .screenshotArea).keyEquivalentModifierMask
        ))

        menu.addItem(makeMenuItem(
            title: "Translate selected text...",
            tag: .translateOrReplySelection,
            symbolName: "text.viewfinder",
            action: #selector(translateOrReplySelectionFromMenu),
            keyEquivalent: shortcut(for: .translateOrReply).menuKeyEquivalent,
            keyEquivalentModifierMask: shortcut(for: .translateOrReply).keyEquivalentModifierMask
        ))

        menu.addItem(makeMenuItem(
            title: "",
            tag: .keyboardShortcuts,
            symbolName: "keyboard",
            submenu: makeKeyboardShortcutsMenu()
        ))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(makeSectionHeader("Languages"))
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

        menu.addItem(makeSectionHeader("Output"))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .writingStyle,
            symbolName: "textformat",
            submenu: makeWritingStyleMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .cleanupLevel,
            symbolName: "sparkles",
            submenu: makeCleanupLevelMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "Snippets & dictionary…",
            tag: .snippets,
            symbolName: "text.append",
            action: #selector(openSnippetsWindow),
            keyEquivalent: ""
        ))

        menu.addItem(makeSectionHeader("AI engine"))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .selectedModel,
            symbolName: "cpu",
            submenu: makeModelSelectionMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .thinkingLevel,
            symbolName: "brain.head.profile",
            submenu: makeThinkingLevelMenu()
        ))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(
            title: "Reset settings...",
            tag: .resetSettings,
            symbolName: "arrow.counterclockwise",
            action: #selector(resetSettings),
            keyEquivalent: ""
        ))
        menu.addItem(makeMenuItem(
            title: "Check for updates...",
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

    private func makeSectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title.uppercased(), action: nil, keyEquivalent: "")
        item.isEnabled = false
        let attributed = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        item.attributedTitle = attributed
        return item
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

    private func makeSelectionDisplayModeMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in SelectionDisplayMode.allCases {
            let item = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectSelectionDisplayMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func makeFloatingDefaultModeMenu() -> NSMenu {
        let menu = NSMenu()
        let translateItem = NSMenuItem(
            title: "Translate",
            action: #selector(selectFloatingDefaultMode(_:)),
            keyEquivalent: ""
        )
        translateItem.target = self
        translateItem.representedObject = FloatingButtonDefaultMode.translate.rawValue
        menu.addItem(translateItem)

        let replyItem = NSMenuItem(
            title: "Reply",
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

    private func makeWritingStyleMenu() -> NSMenu {
        let menu = NSMenu()
        for category in AppCategory.allCases {
            let categoryItem = NSMenuItem(title: category.displayName, action: nil, keyEquivalent: "")
            categoryItem.representedObject = category.rawValue
            let submenu = NSMenu()
            for style in WritingStyle.allCases {
                let item = NSMenuItem(
                    title: style.displayName,
                    action: #selector(selectWritingStyle(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = "\(category.rawValue):\(style.rawValue)"
                submenu.addItem(item)
            }
            categoryItem.submenu = submenu
            menu.addItem(categoryItem)
        }
        return menu
    }

    private func makeCleanupLevelMenu() -> NSMenu {
        let menu = NSMenu()
        for level in CleanupLevel.allCases {
            let item = NSMenuItem(
                title: level.displayName,
                action: #selector(selectCleanupLevel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = level.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func makeReplacementModeMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in ReplacementMode.allCases {
            let item = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectReplacementMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func makeKeyboardShortcutsMenu() -> NSMenu {
        let menu = NSMenu()
        for action in GlobalShortcutAction.allCases {
            let shortcut = shortcut(for: action)
            let item = NSMenuItem(
                title: "\(action.menuTitle): \(shortcut.displayString)",
                action: #selector(recordKeyboardShortcut(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let resetItem = NSMenuItem(
            title: "Reset to defaults",
            action: #selector(resetKeyboardShortcuts),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)
        return menu
    }

    private func startMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            if event.type == .leftMouseDown {
                self.lastLeftMouseDownLocation = mouseLocation
                if self.isScreenshotTranslationRunning {
                    self.screenshotDragStartLocation = mouseLocation
                    self.screenshotDragEndLocation = nil
                }
                return
            }

            if event.type == .leftMouseDragged {
                if self.isScreenshotTranslationRunning {
                    self.updateScreenshotDrag(to: mouseLocation)
                }
                return
            }

            if self.isScreenshotTranslationRunning {
                if event.type == .leftMouseUp {
                    self.updateScreenshotDrag(to: mouseLocation)
                }
                return
            }

            self.handleMouseUp(event)
        }
    }

    @MainActor
    private func applySelectionDisplayMode() {
        switch selectionDisplayMode {
        case .floatingBar:
            petController?.close()
            petController = nil
        case .off:
            petController?.close()
            petController = nil
            translateButtonController?.close()
            translateButtonController = nil
            cancelPrefetch()
        case .pet:
            translateButtonController?.close()
            translateButtonController = nil
            if petController == nil {
                petController = PetController(initialMode: floatingDefaultMode.translationMode)
            }
            petController?.show()
        }

        updateMenuState()
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
                    self.petController?.clearReady()
                    self.cancelPrefetch()
                    return
                }

                let cleanedSelection = TextNormalizer.cleanedSelection(selection.text)
                guard !cleanedSelection.isEmpty else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    self.cancelPrefetch()
                    return
                }

                self.showTranslateButton(
                    for: cleanedSelection,
                    near: mouseLocation,
                    selectionRect: selection.selectionRect,
                    panelSide: self.panelSideForSelectionEnding(at: mouseLocation)
                )
            }
        }
    }

    private func panelSideForSelectionEnding(at mouseLocation: NSPoint) -> TranslationPanelController.Side {
        panelSideForDrag(from: lastLeftMouseDownLocation, to: mouseLocation)
    }

    private func panelSideForScreenshotEnding(at mouseLocation: NSPoint) -> TranslationPanelController.Side {
        screenshotPanelSide ?? panelSideForDrag(from: screenshotDragStartLocation, to: mouseLocation)
    }

    private func panelSideForDrag(from startLocation: NSPoint?, to endLocation: NSPoint) -> TranslationPanelController.Side {
        guard let startLocation else { return .right }

        let dx = endLocation.x - startLocation.x
        let dy = endLocation.y - startLocation.y
        // Need a meaningful horizontal drag — vertical or tiny drags
        // give no reliable direction signal, so default to .right.
        guard abs(dx) >= 5, abs(dx) > abs(dy) else { return .right }
        return dx > 0 ? .right : .left
    }

    private func updateScreenshotDrag(to mouseLocation: NSPoint) {
        screenshotDragEndLocation = mouseLocation
        screenshotPanelSide = panelSideForDrag(from: screenshotDragStartLocation, to: mouseLocation)
    }

    @MainActor
    private func startScreenshotDragTracking() {
        resetScreenshotDragTracking()
        let tracker = ScreenshotDragTracker { [weak self] startLocation, endLocation, panelSide in
            guard let self else { return }
            if let startLocation {
                self.screenshotDragStartLocation = startLocation
            }
            if let endLocation {
                self.screenshotDragEndLocation = endLocation
            }
            if let panelSide {
                self.screenshotPanelSide = panelSide
            }
        }
        screenshotDragTracker = tracker
        tracker.enable()
    }

    @MainActor
    private func resetScreenshotDragTracking() {
        screenshotDragTracker?.disable()
        screenshotDragTracker = nil
        screenshotDragStartLocation = nil
        screenshotDragEndLocation = nil
        screenshotPanelSide = nil
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
    private func showTranslateButton(
        for selectedText: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right
    ) {
        translationPanelController?.close()
        translateButtonController?.close()
        petController?.clearReady()

        guard selectionDisplayMode != .off else {
            cancelPrefetch()
            return
        }

        let language = targetLanguage
        let currentThinkingLevel = thinkingLevel
        let currentCleanup = cleanupLevel
        if translationCache.translation(for: selectedText, targetLanguage: language, thinkingLevel: currentThinkingLevel, cleanup: currentCleanup) == nil {
            startPrefetchIfEligible(for: selectedText)
        } else {
            cancelPrefetch()
        }

        if selectionDisplayMode == .pet {
            if petController == nil {
                petController = PetController(initialMode: floatingDefaultMode.translationMode)
            }
            petController?.show()
            petController?.showReady(
                selectedText: selectedText,
                initialMode: floatingDefaultMode.translationMode,
                onTranslate: { [weak self] text in
                    self?.translate(
                        text,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                },
                onSmartReply: { [weak self] text in
                    self?.replyToSelection(
                        text,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                }
            )
            return
        }

        let controller = FloatingTranslateButtonController(
            screenPoint: screenPoint,
            selectedText: selectedText,
            initialMode: floatingDefaultMode.translationMode,
            onTranslate: { [weak self] text in
                self?.translateButtonController?.close()
                self?.translateButtonController = nil
                self?.translate(
                    text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide
                )
            },
            onSmartReply: { [weak self] text in
                self?.translateButtonController?.close()
                self?.translateButtonController = nil
                self?.replyToSelection(
                    text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide
                )
            }
        )

        translateButtonController = controller
        controller.show()
    }

    @MainActor
    private func replyToSelection(
        _ text: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right,
        keepPetReadyUntilPanelCloses: Bool = false
    ) {
        cancelPrefetch()
        translate(
            text,
            near: screenPoint,
            mode: .smartReply,
            useCache: false,
            usageKind: .smartReply,
            selectionRect: selectionRect,
            panelSide: panelSide,
            keepPetReadyUntilPanelCloses: keepPetReadyUntilPanelCloses
        )
    }

    @MainActor
    private func translate(
        _ text: String,
        near screenPoint: NSPoint,
        targetLanguage explicitTargetLanguage: TranslationLanguage? = nil,
        mode: TranslationMode = .selection,
        useCache: Bool = true,
        usageKind: UsageStatsEventKind = .selection,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right,
        keepPetReadyUntilPanelCloses: Bool = false,
        onReplace: ((String) -> Void)? = nil
    ) {
        let language = explicitTargetLanguage ?? targetLanguage
        let currentThinkingLevel = thinkingLevel
        let (_, currentAppCategory) = AppCategoryClassifier.detectFrontmost()
        let currentStyle = writingStyle(for: currentAppCategory)
        let currentCleanup = cleanupLevel
        let currentSnippets = snippetsStore.usableSnippets()
        let anchor: TranslationPanelController.Anchor =
            selectionRect.map(TranslationPanelController.Anchor.selection)
                ?? .point(screenPoint, panelSide: panelSide)
        let controller = TranslationPanelController(
            anchor: anchor,
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
                    appCategory: currentAppCategory,
                    style: currentStyle,
                    cleanup: currentCleanup,
                    snippets: currentSnippets,
                    useCache: useCache,
                    usageKind: usageKind
                )
            },
            onReplace: onReplace,
            onClose: { [weak self] in
                self?.translationPanelController = nil
                self?.petController?.clearReady()
            }
        )
        translationPanelController?.close()
        translationPanelController = controller
        if keepPetReadyUntilPanelCloses {
            holdPetReadyUntilActivePanelCloses(mode: mode)
        }
        let requestID = controller.showLoading()
        runTranslation(
            text,
            targetLanguage: language,
            mode: mode,
            thinkingLevel: currentThinkingLevel,
            appCategory: currentAppCategory,
            style: currentStyle,
            cleanup: currentCleanup,
            snippets: currentSnippets,
            useCache: useCache,
            usageKind: usageKind,
            controller: controller,
            requestID: requestID
        )
    }

    @MainActor
    private func holdPetReadyUntilActivePanelCloses(mode: TranslationMode) {
        guard selectionDisplayMode == .pet else {
            return
        }

        if petController == nil {
            petController = PetController(initialMode: mode)
        }
        petController?.show()
        petController?.holdReadyUntilPanelCloses(mode: mode)
    }

    @MainActor
    private func retranslateCurrentPanel(
        _ text: String,
        targetLanguage language: TranslationLanguage,
        mode: TranslationMode,
        thinkingLevel: ThinkingLevel,
        appCategory: AppCategory,
        style: WritingStyle,
        cleanup: CleanupLevel,
        snippets: [Snippet],
        useCache: Bool,
        usageKind: UsageStatsEventKind
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
            appCategory: appCategory,
            style: style,
            cleanup: cleanup,
            snippets: snippets,
            useCache: useCache,
            usageKind: usageKind,
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
        appCategory: AppCategory,
        style: WritingStyle,
        cleanup: CleanupLevel,
        snippets: [Snippet],
        useCache: Bool,
        usageKind: UsageStatsEventKind,
        controller: TranslationPanelController,
        requestID: UUID
    ) {
        if let busyError = translationErrorIfBootstrapBusy() {
            controller.showError(busyError.localizedDescription, requestID: requestID)
            return
        }

        if useCache, let cachedTranslation = translationCache.translation(for: text, targetLanguage: language, thinkingLevel: thinkingLevel, cleanup: cleanup) {
            usageStatsStore.recordUse(
                sourceText: text,
                resultText: cachedTranslation,
                kind: usageKind,
                targetLanguage: language
            )
            controller.showTranslation(cachedTranslation, requestID: requestID)
            return
        }

        if useCache,
           let translationPrefetch,
           translationPrefetch.text == text,
           translationPrefetch.targetLanguage == language,
           translationPrefetch.thinkingLevel == thinkingLevel,
           translationPrefetch.appCategory == appCategory,
           translationPrefetch.cleanup == cleanup {
            translationPrefetch.subscribe { partialTranslation in
                controller.showTranslation(partialTranslation, requestID: requestID)
            } onCompletion: { [weak self] finalTranslation in
                self?.usageStatsStore.recordUse(
                    sourceText: text,
                    resultText: finalTranslation,
                    kind: usageKind,
                    targetLanguage: language
                )
            } onFailure: { message in
                controller.showError(message, requestID: requestID)
            }
            translationPrefetch.ensureStartedNow()
            return
        }

        Task {
            do {
                let translated = try await ollamaClient.translate(
                    text,
                    to: language,
                    mode: mode,
                    appCategory: appCategory,
                    style: style,
                    cleanup: cleanup,
                    snippets: snippets,
                    thinkingLevel: thinkingLevel
                ) { partialTranslation in
                    Task { @MainActor in
                        controller.showTranslation(partialTranslation, requestID: requestID)
                    }
                }
                await MainActor.run {
                    if useCache {
                        self.translationCache.store(translated, for: text, targetLanguage: language, thinkingLevel: thinkingLevel, cleanup: cleanup)
                    }
                    self.usageStatsStore.recordUse(
                        sourceText: text,
                        resultText: translated,
                        kind: usageKind,
                        targetLanguage: language
                    )
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
    @discardableResult
    private func handleTranslationFailure(_ error: Error) -> Bool {
        guard let translationError = error as? TranslationError else { return false }
        switch translationError {
        case .serverUnavailable, .modelMissing, .signInRequired:
            bootstrap.refresh()
            presentOnboardingWindow()
            return true
        case .ollama, .emptyResponse, .modelDownloading:
            return false
        }
    }

    @MainActor
    private func translationErrorIfBootstrapBusy() -> TranslationError? {
        if case .working(let detail) = bootstrap.state.modelReady {
            return .modelDownloading(detail)
        }
        return nil
    }

    @MainActor
    private func startPrefetchIfEligible(for text: String) {
        cancelPrefetch()

        guard text.count <= prefetchMaxCharacterCount else {
            return
        }

        let language = targetLanguage
        let currentThinkingLevel = thinkingLevel
        let (_, appCategory) = AppCategoryClassifier.detectFrontmost()
        let currentCleanup = cleanupLevel
        let prefetch = TranslationPrefetch(
            text: text,
            targetLanguage: language,
            thinkingLevel: currentThinkingLevel,
            appCategory: appCategory,
            cleanup: currentCleanup,
            ollamaClient: ollamaClient
        ) { [weak self] sourceText, targetLanguage, thinkingLevel, translation in
            self?.translationCache.store(translation, for: sourceText, targetLanguage: targetLanguage, thinkingLevel: thinkingLevel, cleanup: currentCleanup)
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
        startAccessibilityTrustWatcher()
    }

    private func accessibilityIsTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func startAccessibilityTrustWatcher() {
        guard accessibilityTrustTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if self.accessibilityIsTrusted() {
                    timer.invalidate()
                    self.accessibilityTrustTimer = nil
                    self.updateMenuState()
                }
            }
        }
        accessibilityTrustTimer = timer
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
            ? "Setup..."
            : "Open setup..."
        menu.item(withTag: MenuItemTag.bootstrapSeparator.rawValue)?.isHidden = bootstrapReady
        menu.item(withTag: MenuItemTag.targetLanguage.rawValue)?.title = "Translation language: \(targetLanguage.displayName)"
        menu.item(withTag: MenuItemTag.draftTargetLanguage.rawValue)?.title = "Writing language: \(draftTargetLanguage.displayName)"
        menu.item(withTag: MenuItemTag.selectionDisplayMode.rawValue)?.title = selectionDisplayMode.settingsTitle
        menu.item(withTag: MenuItemTag.floatingDefaultMode.rawValue)?.title = floatingDefaultMode.menuTitle
        menu.item(withTag: MenuItemTag.thinkingLevel.rawValue)?.title = thinkingLevel.settingsTitle
        menu.item(withTag: MenuItemTag.selectedModel.rawValue)?.title = "Mode: \(OllamaModelOption.option(id: selectedModelID).displayName)"
        menu.item(withTag: MenuItemTag.checkForUpdates.rawValue)?.isHidden = !isRunningFromAppBundle
        if let translateSelectionItem = menu.item(withTag: MenuItemTag.translateSelection.rawValue) {
            translateSelectionItem.title = "Rewrite my text in \(draftTargetLanguage.displayName)..."
            applyShortcut(for: .translateSelection, to: translateSelectionItem)
            translateSelectionItem.isEnabled = trusted
        }
        if let screenshotItem = menu.item(withTag: MenuItemTag.screenshotArea.rawValue) {
            let idleTitle: String
            switch floatingDefaultMode {
            case .translate:
                idleTitle = "Translate screen area..."
            case .smartReply:
                idleTitle = "Reply to screen area..."
            }
            screenshotItem.title = isScreenshotTranslationRunning
                ? "Selecting screen area..."
                : idleTitle
            applyShortcut(for: .screenshotArea, to: screenshotItem)
            screenshotItem.isEnabled = !isScreenshotTranslationRunning
        }
        if let selectionItem = menu.item(withTag: MenuItemTag.translateOrReplySelection.rawValue) {
            switch floatingDefaultMode {
            case .translate:
                selectionItem.title = "Translate selected text..."
            case .smartReply:
                selectionItem.title = "Reply to selected text..."
            }
            applyShortcut(for: .translateOrReply, to: selectionItem)
            selectionItem.isEnabled = trusted
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

        if let displayModeMenu = menu.item(withTag: MenuItemTag.selectionDisplayMode.rawValue)?.submenu {
            let activeMode = selectionDisplayMode.rawValue
            for item in displayModeMenu.items {
                guard let raw = item.representedObject as? String else { continue }
                item.state = raw == activeMode ? .on : .off
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

        menu.item(withTag: MenuItemTag.writingStyle.rawValue)?.title = "Writing style"
        menu.item(withTag: MenuItemTag.cleanupLevel.rawValue)?.title = "Auto cleanup: \(cleanupLevel.displayName.lowercased())"
        menu.item(withTag: MenuItemTag.keyboardShortcuts.rawValue)?.title = "Edit keyboard shortcuts..."
        if let shortcutsMenu = menu.item(withTag: MenuItemTag.keyboardShortcuts.rawValue)?.submenu {
            updateKeyboardShortcutsMenu(shortcutsMenu)
        }

        if let styleMenu = menu.item(withTag: MenuItemTag.writingStyle.rawValue)?.submenu {
            for categoryItem in styleMenu.items {
                guard let categoryRaw = categoryItem.representedObject as? String,
                      let category = AppCategory(rawValue: categoryRaw),
                      let submenu = categoryItem.submenu
                else { continue }
                let activeStyle = writingStyle(for: category)
                categoryItem.title = "\(category.displayName) — \(activeStyle.displayName)"
                for item in submenu.items {
                    guard let raw = item.representedObject as? String else { continue }
                    let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    item.state = parts[1] == activeStyle.rawValue ? .on : .off
                }
            }
        }

        if let cleanupMenu = menu.item(withTag: MenuItemTag.cleanupLevel.rawValue)?.submenu {
            let activeLevel = cleanupLevel.rawValue
            for item in cleanupMenu.items {
                guard let raw = item.representedObject as? String else { continue }
                item.state = raw == activeLevel ? .on : .off
            }
        }

        menu.item(withTag: MenuItemTag.replacementMode.rawValue)?.title = replacementMode.settingsTitle
        if let replacementMenu = menu.item(withTag: MenuItemTag.replacementMode.rawValue)?.submenu {
            let activeMode = replacementMode.rawValue
            for item in replacementMenu.items {
                guard let raw = item.representedObject as? String else { continue }
                item.state = raw == activeMode ? .on : .off
            }
        }
    }

    private func applyShortcut(for action: GlobalShortcutAction, to item: NSMenuItem) {
        let shortcut = shortcut(for: action)
        item.keyEquivalent = shortcut.menuKeyEquivalent
        item.keyEquivalentModifierMask = shortcut.keyEquivalentModifierMask
    }

    private func updateKeyboardShortcutsMenu(_ menu: NSMenu) {
        for item in menu.items {
            if let raw = item.representedObject as? String,
               let action = GlobalShortcutAction(rawValue: raw) {
                let shortcut = shortcut(for: action)
                item.title = "\(action.menuTitle): \(shortcut.displayString)"
            } else if item.action == #selector(resetKeyboardShortcuts) {
                item.isEnabled = GlobalShortcutAction.allCases.contains {
                    shortcut(for: $0) != $0.defaultShortcut
                }
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
    @objc private func openSnippetsWindow() {
        if let snippetsWindowController {
            snippetsWindowController.presentAndFocus()
            return
        }
        let controller = SnippetsWindowController(store: snippetsStore) { [weak self] in
            self?.snippetsWindowController = nil
        }
        snippetsWindowController = controller
        controller.presentAndFocus()
    }

    @MainActor
    @objc private func translateScreenshotAreaFromMenu() {
        startScreenshotTranslation()
    }

    @MainActor
    @objc private func translateSelectedTextFromMenu() {
        startSelectedTextTranslationForReplacement()
    }

    @objc private func translateOrReplySelectionFromMenu() {
        startSelectionTranslateOrReply()
    }

    @MainActor
    private func startSelectionTranslateOrReply() {
        guard accessibilityIsTrusted() else {
            requestAccessibilityPermissionIfNeeded()
            return
        }

        translateButtonController?.close()
        translateButtonController = nil
        petController?.clearReady()
        cancelPrefetch()

        let mode = floatingDefaultMode.translationMode

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }

            self.selectionReader.readSelectedTextContext(allowClipboardFallback: true) { [weak self] selection in
                guard let self else { return }

                let shortcutDisplay = self.shortcut(for: .translateOrReply).displayString

                guard let selection else {
                    self.presentSelectionTranslationError("Select text first, then press \(shortcutDisplay).")
                    return
                }

                let cleaned = TextNormalizer.cleanedSelection(selection.text)
                guard !cleaned.isEmpty else {
                    self.presentSelectionTranslationError("Select text first, then press \(shortcutDisplay).")
                    return
                }

                let mouseLocation = NSEvent.mouseLocation
                let panelSide = self.panelSideForSelectionEnding(at: mouseLocation)

                switch mode {
                case .smartReply:
                    self.replyToSelection(
                        cleaned,
                        near: mouseLocation,
                        selectionRect: selection.selectionRect,
                        panelSide: panelSide
                    )
                case .selection, .draftMessage:
                    self.translate(
                        cleaned,
                        near: mouseLocation,
                        mode: .selection,
                        usageKind: .selection,
                        selectionRect: selection.selectionRect,
                        panelSide: panelSide
                    )
                }
            }
        }
    }

    @MainActor
    private func startSelectedTextTranslationForReplacement() {
        guard accessibilityIsTrusted() else {
            requestAccessibilityPermissionIfNeeded()
            return
        }

        cancelPrefetch()
        lastReplacementSourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }

            self.selectionReader.readSelectedTextContext(allowClipboardFallback: true) { [weak self] selection in
                guard let self else { return }

                guard let selection else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    self.presentSelectionTranslationError("Select text first, then press \(self.shortcut(for: .translateSelection).displayString).")
                    return
                }

                let cleanedDraft = TextNormalizer.cleanedDraftMessage(selection.text)
                guard !cleanedDraft.isEmpty else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    self.presentSelectionTranslationError("Select text first, then press \(self.shortcut(for: .translateSelection).displayString).")
                    return
                }

                let language = self.draftTargetLanguage
                let mouseLocation = NSEvent.mouseLocation
                switch self.replacementMode {
                case .instantInsert:
                    self.runInstantTranslation(cleanedDraft, language: language, near: mouseLocation)
                case .showPanel:
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.translate(
                        cleanedDraft,
                        near: mouseLocation,
                        targetLanguage: language,
                        mode: .draftMessage,
                        useCache: false,
                        usageKind: .draftMessage,
                        selectionRect: selection.selectionRect,
                        panelSide: self.panelSideForSelectionEnding(at: mouseLocation),
                        keepPetReadyUntilPanelCloses: true
                    ) { [weak self] translation in
                        self?.replaceCurrentSelection(with: translation)
                    }
                }
            }
        }
    }

    @MainActor
    private func runInstantTranslation(_ text: String, language: TranslationLanguage, near screenPoint: NSPoint) {
        if let busyError = translationErrorIfBootstrapBusy() {
            presentSelectionTranslationError(
                busyError.localizedDescription,
                title: "Translator is still downloading"
            )
            return
        }

        let currentThinkingLevel = thinkingLevel
        let (_, currentAppCategory) = AppCategoryClassifier.detectFrontmost()
        let currentStyle = writingStyle(for: currentAppCategory)
        let currentCleanup = cleanupLevel
        let currentSnippets = snippetsStore.usableSnippets()

        let loadingBar = showInstantTranslationLoading(near: screenPoint)

        let client = ollamaClient
        Task { [weak self] in
            do {
                let translated = try await client.translate(
                    text,
                    to: language,
                    mode: .draftMessage,
                    appCategory: currentAppCategory,
                    style: currentStyle,
                    cleanup: currentCleanup,
                    snippets: currentSnippets,
                    thinkingLevel: currentThinkingLevel
                ) { _ in }
                await MainActor.run {
                    guard let self else { return }
                    self.usageStatsStore.recordUse(
                        sourceText: text,
                        resultText: translated,
                        kind: .draftMessage,
                        targetLanguage: language
                    )
                    self.hideInstantTranslationLoading(loadingBar)
                    self.replaceCurrentSelection(with: translated)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.hideInstantTranslationLoading(loadingBar)
                    let routedToOnboarding = self.handleTranslationFailure(error)
                    if !routedToOnboarding {
                        self.presentSelectionTranslationError(
                            error.localizedDescription,
                            title: "Translation failed"
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func showInstantTranslationLoading(near screenPoint: NSPoint) -> FloatingTranslateButtonController? {
        switch selectionDisplayMode {
        case .pet:
            if petController == nil {
                petController = PetController(initialMode: .draftMessage)
            }
            petController?.showThinking()
            return nil
        case .floatingBar:
            // Reuse the bar that's already on screen so it morphs in place
            // instead of flickering — its panel stays at the same origin.
            let bar: FloatingTranslateButtonController
            if let existing = translateButtonController {
                bar = existing
                translateButtonController = nil
            } else {
                bar = FloatingTranslateButtonController(
                    screenPoint: screenPoint,
                    selectedText: "",
                    initialMode: .selection,
                    onTranslate: { _ in },
                    onSmartReply: { _ in }
                )
                bar.show()
            }
            bar.setLoading()
            floatingLoadingBar?.close()
            floatingLoadingBar = bar
            return bar
        case .off:
            return nil
        }
    }

    @MainActor
    private func hideInstantTranslationLoading(_ loadingBar: FloatingTranslateButtonController?) {
        petController?.clearThinking()
        guard let loadingBar else { return }
        loadingBar.close()
        if floatingLoadingBar === loadingBar {
            floatingLoadingBar = nil
        }
    }

    @MainActor
    private func replaceCurrentSelection(with translation: String) {
        let cleanTranslation = TextNormalizer.cleanedTranslation(translation)
        guard !cleanTranslation.isEmpty else {
            return
        }

        let sourcePID = lastReplacementSourcePID
        lastReplacementSourcePID = nil

        let performPaste: @MainActor () -> Void = { [weak self] in
            PasteboardTextInserter.replaceCurrentSelection(with: cleanTranslation)
            self?.usageStatsStore.recordReplacement(text: cleanTranslation)
            self?.translationPanelController?.close()
            self?.translationPanelController = nil
        }

        if let pid = sourcePID,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
           let runningApp = NSRunningApplication(processIdentifier: pid) {
            runningApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                performPaste()
            }
        } else {
            performPaste()
        }
    }

    @MainActor
    private func startScreenshotTranslation() {
        guard !isScreenshotTranslationRunning else {
            return
        }

        isScreenshotTranslationRunning = true
        startScreenshotDragTracking()
        updateMenuState()
        translateButtonController?.close()
        translateButtonController = nil
        petController?.clearReady()
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
                        self.resetScreenshotDragTracking()
                        self.presentScreenshotTranslationError(ScreenshotTranslationError.noTextRecognized)
                        return
                    }

                    let mouseLocation = NSEvent.mouseLocation
                    let panelSide = self.panelSideForScreenshotEnding(at: mouseLocation)
                    self.resetScreenshotDragTracking()
                    let mode = self.floatingDefaultMode.translationMode
                    self.translate(
                        sourceText,
                        near: mouseLocation,
                        mode: mode,
                        useCache: mode != .smartReply,
                        usageKind: mode == .smartReply ? .smartReply : .screenArea,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isScreenshotTranslationRunning = false
                    self.resetScreenshotDragTracking()
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
        NSApp.activate(ignoringOtherApps: true)

        if let screenshotError = error as? ScreenshotTranslationError,
           case .screenRecordingPermissionDenied = screenshotError {
            let response = YakuAlertController(
                title: "Screen recording required",
                message: screenshotError.localizedDescription,
                primaryButtonTitle: "Open settings",
                secondaryButtonTitle: "Quit Yaku"
            ).showModal()
            switch response {
            case .alertFirstButtonReturn:
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            case .alertSecondButtonReturn:
                NSApp.terminate(nil)
            default:
                break
            }
            return
        }

        _ = YakuAlertController(
            title: "Screenshot translation failed",
            message: error.localizedDescription,
            primaryButtonTitle: "OK"
        ).showModal()
    }

    @MainActor
    private func presentSelectionTranslationError(_ message: String, title: String = "No text selected") {
        NSApp.activate(ignoringOtherApps: true)
        _ = YakuAlertController(
            title: title,
            message: message,
            primaryButtonTitle: "OK"
        ).showModal()
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
        petController?.setActionMode(mode.translationMode)
        refreshStatusBarIcon()
        updateMenuState()
    }

    @MainActor
    @objc private func selectSelectionDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = SelectionDisplayMode(rawValue: raw)
        else {
            return
        }

        selectionDisplayMode = mode
        applySelectionDisplayMode()
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

    @MainActor
    @objc private func selectWritingStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let category = AppCategory(rawValue: parts[0]),
              let style = WritingStyle(rawValue: parts[1])
        else { return }
        setWritingStyle(style, for: category)
        cancelPrefetch()
        translationCache = TranslationCache()
        updateMenuState()
    }

    @MainActor
    @objc private func selectCleanupLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let level = CleanupLevel(rawValue: raw)
        else { return }
        cleanupLevel = level
        cancelPrefetch()
        translationCache = TranslationCache()
        updateMenuState()
    }

    @MainActor
    @objc private func selectReplacementMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ReplacementMode(rawValue: raw)
        else { return }
        replacementMode = mode
        updateMenuState()
    }

    @MainActor
    @objc private func recordKeyboardShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = GlobalShortcutAction(rawValue: raw)
        else { return }

        shortcutRecorderWindowController?.close()
        let controller = ShortcutRecorderWindowController(
            action: action,
            currentShortcut: shortcut(for: action),
            onShortcut: { [weak self] shortcut in
                self?.setKeyboardShortcut(shortcut, for: action) ?? false
            },
            onClose: { [weak self] in
                self?.shortcutRecorderWindowController = nil
            }
        )
        shortcutRecorderWindowController = controller
        controller.present()
    }

    @MainActor
    private func setKeyboardShortcut(_ shortcut: GlobalShortcut, for action: GlobalShortcutAction) -> Bool {
        for otherAction in GlobalShortcutAction.allCases where otherAction != action {
            if self.shortcut(for: otherAction) == shortcut {
                return false
            }
        }

        GlobalShortcutStore.set(shortcut, for: action)
        setupGlobalHotKeys()
        updateMenuState()
        return true
    }

    @MainActor
    @objc private func resetKeyboardShortcuts() {
        GlobalShortcutStore.resetToDefaults()
        setupGlobalHotKeys()
        updateMenuState()
    }

    @MainActor
    @objc private func resetSettings() {
        let response = YakuAlertController(
            title: "Reset settings?",
            message: "This restores languages, main mode, display, output, AI mode, and keyboard shortcuts. Snippets, dictionary, and usage stats stay unchanged.",
            primaryButtonTitle: "Reset",
            secondaryButtonTitle: "Cancel"
        ).showModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        resetSettingsToDefaults()
    }

    @MainActor
    private func resetSettingsToDefaults() {
        let previousModelID = selectedModelID
        let defaults = UserDefaults.standard
        [
            "targetLanguageID",
            "draftTargetLanguageID",
            "floatingButtonDefaultMode",
            "selectionDisplayMode",
            "selectedOllamaModel",
            "thinkingLevel",
            "cleanupLevel",
            "replacementMode"
        ].forEach { defaults.removeObject(forKey: $0) }

        for category in AppCategory.allCases {
            defaults.removeObject(forKey: "writingStyle.\(category.rawValue)")
        }

        GlobalShortcutStore.resetToDefaults(defaults: defaults)
        shortcutRecorderWindowController?.close()
        cancelPrefetch()
        translationCache = TranslationCache()
        translationPanelController?.close()
        translationPanelController = nil
        petController?.setActionMode(floatingDefaultMode.translationMode)
        refreshStatusBarIcon()
        applySelectionDisplayMode()
        setupGlobalHotKeys()

        if selectedModelID != previousModelID {
            rebuildBootstrapForCurrentModel()
        }

        updateMenuState()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @MainActor
    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}

extension YakuApp: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/ChoiVadim/yaku/main/appcast.xml"
    }
}

@MainActor
private final class YakuModalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class YakuAlertController: NSWindowController, NSWindowDelegate {
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 16
    private static let shadowMargin: CGFloat = 30
    private static let cornerRadius: CGFloat = 28
    private static let mascotSize = NSSize(width: 42, height: 34)
    private static let textGap: CGFloat = 10
    private static let minTextWidth: CGFloat = 168
    private static let maxTextWidth: CGFloat = 300
    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let messageFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private struct AlertLayout {
        let cardSize: NSSize
        let textWidth: CGFloat
    }

    init(
        title: String,
        message: String,
        primaryButtonTitle: String,
        secondaryButtonTitle: String? = nil
    ) {
        let layout = Self.layout(
            title: title,
            message: message,
            primaryButtonTitle: primaryButtonTitle,
            secondaryButtonTitle: secondaryButtonTitle
        )
        let windowSize = NSSize(
            width: layout.cardSize.width + Self.shadowMargin * 2,
            height: layout.cardSize.height + Self.shadowMargin * 2
        )
        let panel = YakuModalPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        panel.delegate = self
        buildUI(
            in: panel,
            windowSize: windowSize,
            layout: layout,
            title: title,
            message: message,
            primaryButtonTitle: primaryButtonTitle,
            secondaryButtonTitle: secondaryButtonTitle
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showModal() -> NSApplication.ModalResponse {
        guard let window else { return .cancel }
        window.center()
        window.makeKeyAndOrderFront(nil)
        return NSApp.runModal(for: window)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.stopModal(withCode: .cancel)
        }
    }

    private func buildUI(
        in panel: NSPanel,
        windowSize: NSSize,
        layout: AlertLayout,
        title: String,
        message: String,
        primaryButtonTitle: String,
        secondaryButtonTitle: String?
    ) {
        let rootView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false
        panel.contentView = rootView

        let glass = GlassHostView(
            frame: NSRect(origin: NSPoint(x: Self.shadowMargin, y: Self.shadowMargin), size: layout.cardSize),
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
            roundedRect: NSRect(origin: .zero, size: layout.cardSize),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(glass)
        let contentView = glass.contentView

        let mascotColumn = NSView()
        mascotColumn.translatesAutoresizingMaskIntoConstraints = false

        let mascotView = PetMascotView(frame: NSRect(origin: .zero, size: Self.mascotSize))
        mascotView.apply(state: .idle, mode: .selection)
        mascotView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = Self.messageFont
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = layout.textWidth
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let primaryButton = makeButton(title: primaryButtonTitle, action: #selector(primaryTapped))

        contentView.addSubview(mascotColumn)
        mascotColumn.addSubview(mascotView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(messageLabel)
        contentView.addSubview(primaryButton)

        var constraints: [NSLayoutConstraint] = [
            glass.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.shadowMargin),
            glass.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Self.shadowMargin),
            glass.widthAnchor.constraint(equalToConstant: layout.cardSize.width),
            glass.heightAnchor.constraint(equalToConstant: layout.cardSize.height),

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
            titleLabel.widthAnchor.constraint(equalToConstant: layout.textWidth),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            primaryButton.heightAnchor.constraint(equalToConstant: 30),
            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonWidth(for: primaryButtonTitle)),
            primaryButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalPadding)
        ]

        if let secondaryButtonTitle {
            let secondaryButton = makeButton(title: secondaryButtonTitle, action: #selector(secondaryTapped))
            contentView.addSubview(secondaryButton)
            constraints.append(contentsOf: [
                secondaryButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                secondaryButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -8),
                secondaryButton.bottomAnchor.constraint(equalTo: primaryButton.bottomAnchor),
                secondaryButton.heightAnchor.constraint(equalTo: primaryButton.heightAnchor),
                secondaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonWidth(for: secondaryButtonTitle)),
                secondaryButton.widthAnchor.constraint(equalTo: primaryButton.widthAnchor),

                primaryButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor)
            ])
        } else {
            constraints.append(contentsOf: [
                primaryButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                primaryButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor)
            ])
        }

        constraints.append(primaryButton.topAnchor.constraint(greaterThanOrEqualTo: messageLabel.bottomAnchor, constant: 12))
        NSLayoutConstraint.activate(constraints)
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.focusRingType = .none
        return button
    }

    @objc private func primaryTapped() {
        close(with: .alertFirstButtonReturn)
    }

    @objc private func secondaryTapped() {
        close(with: .alertSecondButtonReturn)
    }

    private func close(with response: NSApplication.ModalResponse) {
        NSApp.stopModal(withCode: response)
        window?.orderOut(nil)
    }

    private static func layout(
        title: String,
        message: String,
        primaryButtonTitle: String,
        secondaryButtonTitle: String?
    ) -> AlertLayout {
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        let messageSingleLineWidth = ceil((message as NSString).size(withAttributes: [.font: messageFont]).width)
        let primaryButtonWidth = buttonWidth(for: primaryButtonTitle)
        let buttonWidth: CGFloat
        if let secondaryButtonTitle {
            let secondaryButtonWidth = Self.buttonWidth(for: secondaryButtonTitle)
            buttonWidth = max(primaryButtonWidth, secondaryButtonWidth) * 2 + 8
        } else {
            buttonWidth = primaryButtonWidth
        }

        let textWidth = min(
            max(max(titleWidth, messageSingleLineWidth, buttonWidth), minTextWidth),
            maxTextWidth
        )
        let messageHeight = ceil((message as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: messageFont]
        ).height)
        let textBlockHeight = ceil(titleFont.boundingRectForFont.height) + 4 + messageHeight
        let height = verticalPadding + max(mascotSize.height, textBlockHeight + 12 + 30) + verticalPadding
        let width = horizontalPadding * 2 + mascotSize.width + textGap + textWidth
        return AlertLayout(
            cardSize: NSSize(width: ceil(width), height: max(112, ceil(height))),
            textWidth: textWidth
        )
    }

    private static func buttonWidth(for title: String) -> CGFloat {
        let titleWidth = ceil((title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width)
        return max(54, titleWidth + 28)
    }
}

struct SelectedTextContext {
    let text: String
    let selectionRect: NSRect?
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
                    completion(SelectedTextContext(text: clipboardText, selectionRect: nil))
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

            completion(SelectedTextContext(text: selectedText, selectionRect: nil))
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

        let rect = selectedTextRange(from: focusedElement)
            .flatMap { selectionBounds(from: focusedElement, range: $0) }

        return SelectedTextContext(
            text: trimmed,
            selectionRect: rect
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

    private func selectionBounds(from element: AXUIElement, range: CFRange) -> NSRect? {
        var mutableRange = range
        guard let rangeAXValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeAXValue,
            &boundsValue
        )

        guard result == .success,
              let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = boundsValue as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect,
              AXValueGetValue(axValue, .cgRect, &rect),
              rect.width > 0, rect.height > 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite
        else {
            return nil
        }

        return SelectionReader.convertAXRectToCocoa(rect)
    }

    // AX uses top-left origin of the menu-bar screen; NSScreen uses bottom-left.
    // NSScreen.screens.first is the screen at NSScreen-origin (0,0). Don't use NSScreen.main —
    // it's the screen with the active window, which can be a different display.
    private static func convertAXRectToCocoa(_ axRect: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let flippedY = primary.frame.maxY - axRect.maxY
        return NSRect(x: axRect.origin.x, y: flippedY, width: axRect.width, height: axRect.height)
    }

}

enum ClipboardSelectionReader {
    private static let pollingInterval: TimeInterval = 0.02
    private static let pollingTimeout: TimeInterval = 0.5

    static func readSelectedText(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let originalChangeCount = pasteboard.changeCount

        postCommandC()

        let deadline = Date().addingTimeInterval(pollingTimeout)
        pollForPasteboardChange(
            pasteboard: pasteboard,
            originalChangeCount: originalChangeCount,
            deadline: deadline,
            snapshot: snapshot,
            completion: completion
        )
    }

    private static func pollForPasteboardChange(
        pasteboard: NSPasteboard,
        originalChangeCount: Int,
        deadline: Date,
        snapshot: PasteboardSnapshot,
        completion: @escaping (String?) -> Void
    ) {
        if pasteboard.changeCount != originalChangeCount {
            let copiedText = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.restore(to: pasteboard)
            completion((copiedText?.isEmpty == false) ? copiedText : nil)
            return
        }

        if Date() >= deadline {
            completion(nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollingInterval) {
            pollForPasteboardChange(
                pasteboard: pasteboard,
                originalChangeCount: originalChangeCount,
                deadline: deadline,
                snapshot: snapshot,
                completion: completion
            )
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
            "Yaku needs Screen Recording permission to capture screenshots. Open settings to enable it, then choose Quit Yaku and reopen Yaku for the change to take effect."
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

final class ScreenshotDragTracker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var startLocation: NSPoint?
    private var lastLocation: NSPoint?
    private var currentPanelSide: TranslationPanelController.Side?
    private let onUpdate: @MainActor (NSPoint?, NSPoint?, TranslationPanelController.Side?) -> Void

    init(onUpdate: @escaping @MainActor (NSPoint?, NSPoint?, TranslationPanelController.Side?) -> Void) {
        self.onUpdate = onUpdate
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask =
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let tracker = Unmanaged<ScreenshotDragTracker>.fromOpaque(userInfo).takeUnretainedValue()
                tracker.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
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
        startLocation = nil
        lastLocation = nil
        currentPanelSide = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let location = event.location
        switch type {
        case .leftMouseDown:
            startLocation = location
            lastLocation = location
            currentPanelSide = nil
            notify(startLocation: location, endLocation: nil, panelSide: nil)
        case .leftMouseDragged, .leftMouseUp:
            let referenceLocation = startLocation ?? lastLocation
            if let panelSide = Self.meaningfulPanelSideForDrag(from: referenceLocation, to: location) {
                currentPanelSide = panelSide
            }
            notify(startLocation: startLocation, endLocation: location, panelSide: currentPanelSide)
            lastLocation = location
            if type == .leftMouseUp {
                startLocation = nil
                lastLocation = nil
            }
        default:
            break
        }
    }

    private func notify(
        startLocation: NSPoint?,
        endLocation: NSPoint?,
        panelSide: TranslationPanelController.Side?
    ) {
        Task { @MainActor in
            onUpdate(startLocation, endLocation, panelSide)
        }
    }

    private static func meaningfulPanelSideForDrag(
        from startLocation: NSPoint?,
        to endLocation: NSPoint
    ) -> TranslationPanelController.Side? {
        guard let startLocation else { return nil }

        let dx = endLocation.x - startLocation.x
        let dy = endLocation.y - startLocation.y
        guard abs(dx) >= 5, abs(dx) > abs(dy) else { return nil }
        return dx > 0 ? .right : .left
    }

    deinit {
        disable()
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
    private let consumesEvent: Bool
    private let onCopy: @MainActor () -> Void

    init(consumesEvent: Bool = true, onCopy: @escaping @MainActor () -> Void) {
        self.consumesEvent = consumesEvent
        self.onCopy = onCopy
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: consumesEvent ? .defaultTap : .listenOnly,
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
                return interceptor.consumesEvent ? nil : Unmanaged.passUnretained(event)
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
final class PetController {
    private let panel: NSPanel
    private let petView: PetMascotView
    private let appIconView: NSImageView
    private var workspaceObserver: NSObjectProtocol?
    private var trackingTimer: Timer?
    private var tabInterceptor: TabKeyInterceptor?
    private var selectedText: String?
    private var onTranslate: ((String) -> Void)?
    private var onSmartReply: ((String) -> Void)?
    private var currentMode: TranslationMode
    private var isReadyLockedUntilPanelCloses = false
    private var isThinking = false
    private var lastCursorLocation = NSEvent.mouseLocation
    private var lastCursorMovementDate = Date.distantPast
    private var cursorOffset = PetController.defaultCursorOffset
    private var isReadyState: Bool {
        selectedText != nil || isReadyLockedUntilPanelCloses
    }

    private static let mascotSize = NSSize(width: 42, height: 34)
    private static let appIconSize = NSSize(width: 14, height: 14)
    private static let panelPadding: CGFloat = 6
    private static let panelSize = NSSize(
        width: mascotSize.width + panelPadding * 2,
        height: mascotSize.height + panelPadding * 2
    )
    private static let edgeMargin: CGFloat = 6
    private static let defaultCursorOffset = NSPoint(
        x: 12 - panelPadding,
        y: -mascotSize.height - 8 - panelPadding
    )

    init(initialMode: TranslationMode) {
        currentMode = initialMode
        let origin = PetController.originNearCursor(
            for: NSEvent.mouseLocation,
            size: Self.panelSize,
            offset: cursorOffset
        )
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: Self.panelSize),
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
        panel.ignoresMouseEvents = true

        let container = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        petView = PetMascotView(frame: NSRect(
            origin: .zero,
            size: Self.panelSize
        ))
        petView.wantsLayer = true
        petView.layer?.shadowColor = NSColor.black.cgColor
        petView.layer?.shadowOpacity = 0.32
        petView.layer?.shadowRadius = 3
        petView.layer?.shadowOffset = .zero
        petView.layer?.masksToBounds = false
        container.addSubview(petView)

        appIconView = NSImageView(frame: NSRect(
            x: Self.panelSize.width - Self.appIconSize.width,
            y: Self.panelSize.height - Self.appIconSize.height,
            width: Self.appIconSize.width,
            height: Self.appIconSize.height
        ))
        appIconView.imageScaling = .scaleProportionallyDown
        appIconView.isHidden = true
        container.addSubview(appIconView)

        panel.contentView = container
        petView.onClick = { [weak self] in
            self?.invokeCurrentMode()
        }

        refreshAppIcon()
        subscribeToFrontmostAppChanges()
    }

    private func subscribeToFrontmostAppChanges() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAppIcon()
            }
        }
    }

    private func refreshAppIcon() {
        guard !isReadyState, !isThinking else {
            appIconView.isHidden = true
            return
        }
        guard let runningApp = NSWorkspace.shared.frontmostApplication else {
            appIconView.isHidden = true
            return
        }
        if runningApp.bundleIdentifier == Bundle.main.bundleIdentifier {
            appIconView.isHidden = true
            return
        }
        if let icon = runningApp.icon {
            appIconView.image = icon
            appIconView.isHidden = false
        } else {
            appIconView.isHidden = true
        }
    }

    func show() {
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        startTracking()
    }

    func close() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        clearReady()
        trackingTimer?.invalidate()
        trackingTimer = nil
        panel.close()
    }

    func showReady(
        selectedText: String,
        initialMode: TranslationMode,
        onTranslate: @escaping (String) -> Void,
        onSmartReply: @escaping (String) -> Void
    ) {
        self.selectedText = selectedText
        self.onTranslate = onTranslate
        self.onSmartReply = onSmartReply
        currentMode = initialMode
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = false
        petView.apply(state: .ready, mode: currentMode)
        appIconView.isHidden = true
        enableTabInterceptor()
        show()
    }

    func holdReadyUntilPanelCloses(mode: TranslationMode? = nil) {
        if let mode {
            currentMode = mode
        }
        selectedText = nil
        onTranslate = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = true
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        petView.apply(state: .ready, mode: currentMode)
        appIconView.isHidden = true
    }

    func clearReady() {
        selectedText = nil
        onTranslate = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        petView.apply(state: .idle, mode: currentMode)
        refreshAppIcon()
    }

    func showThinking() {
        isThinking = true
        selectedText = nil
        onTranslate = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        appIconView.isHidden = true
        petView.apply(state: .thinking, mode: currentMode)
        show()
    }

    func clearThinking() {
        isThinking = false
        petView.apply(state: .idle, mode: currentMode)
        refreshAppIcon()
    }

    func setActionMode(_ mode: TranslationMode) {
        currentMode = mode
        petView.apply(state: selectedText == nil && !isReadyLockedUntilPanelCloses ? .idle : .ready, mode: currentMode)
        refreshAppIcon()
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func updateTracking() {
        guard panel.isVisible else { return }

        petView.advanceAnimationFrame()
        guard selectedText == nil, !isReadyLockedUntilPanelCloses, !isThinking else {
            return
        }

        let cursorLocation = NSEvent.mouseLocation
        let cursorMovement = hypot(
            cursorLocation.x - lastCursorLocation.x,
            cursorLocation.y - lastCursorLocation.y
        )
        if cursorMovement > 0.75 {
            cursorOffset = Self.trailingOffset(
                forMovement: NSPoint(
                    x: cursorLocation.x - lastCursorLocation.x,
                    y: cursorLocation.y - lastCursorLocation.y
                ),
                size: Self.panelSize
            )
            lastCursorLocation = cursorLocation
            lastCursorMovementDate = Date()
        }

        let targetOrigin = Self.originNearCursor(
            for: cursorLocation,
            size: Self.panelSize,
            offset: cursorOffset
        )
        let currentOrigin = panel.frame.origin
        let dx = targetOrigin.x - currentOrigin.x
        let dy = targetOrigin.y - currentOrigin.y
        let nextOrigin = NSPoint(
            x: currentOrigin.x + dx * 0.22,
            y: currentOrigin.y + dy * 0.22
        )
        panel.setFrameOrigin(nextOrigin)
        let cursorMovedRecently = Date().timeIntervalSince(lastCursorMovementDate) < 0.16
        petView.apply(state: cursorMovedRecently ? .run : .idle, mode: currentMode)
    }

    private func enableTabInterceptor() {
        tabInterceptor?.disable()
        let interceptor = TabKeyInterceptor { [weak self] in
            self?.toggleMode()
        }
        tabInterceptor = interceptor
        interceptor.enable()
    }

    private func toggleMode() {
        currentMode = currentMode == .smartReply ? .selection : .smartReply
        petView.apply(state: selectedText == nil && !isReadyLockedUntilPanelCloses ? .idle : .ready, mode: currentMode)
    }

    private func invokeCurrentMode() {
        guard let selectedText, !isReadyLockedUntilPanelCloses else { return }

        switch currentMode {
        case .selection, .draftMessage:
            onTranslate?(selectedText)
        case .smartReply:
            onSmartReply?(selectedText)
        }
    }

    private static func originNearCursor(for cursor: NSPoint, size: NSSize, offset: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: cursor.x + offset.x, y: cursor.y + offset.y)

        if origin.y < visibleFrame.minY + edgeMargin {
            origin.y = cursor.y + 12
        }
        if origin.y + size.height > visibleFrame.maxY - edgeMargin {
            origin.y = cursor.y - size.height - 8
        }
        if origin.x < visibleFrame.minX + edgeMargin {
            origin.x = cursor.x + 12
        }
        if origin.x + size.width > visibleFrame.maxX - edgeMargin {
            origin.x = cursor.x - size.width - 12
        }

        origin.x = min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin)
        origin.y = min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
        return origin
    }

    private static func trailingOffset(forMovement movement: NSPoint, size: NSSize) -> NSPoint {
        if abs(movement.x) >= abs(movement.y) {
            let xOffset = movement.x > 0 ? -size.width - 12 : 12
            return NSPoint(x: xOffset, y: -size.height / 2)
        }

        let yOffset = movement.y > 0 ? -size.height - 8 : 12
        return NSPoint(x: -size.width / 2, y: yOffset)
    }
}

@MainActor
final class PetMascotView: NSView {
    enum State: Equatable {
        case idle
        case run
        case ready
        case thinking
    }

    var onClick: (() -> Void)?

    private var state: State = .idle
    private var mode: TranslationMode = .selection
    private var animationFrame = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Yaku"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard state == .ready else { return }
        onClick?()
    }

    func apply(state: State, mode: TranslationMode) {
        let didChange = self.state != state || self.mode != mode
        self.state = state
        self.mode = mode
        toolTip = tooltip(for: state, mode: mode)
        if didChange {
            needsDisplay = true
        }
    }

    func advanceAnimationFrame() {
        animationFrame = (animationFrame + 1) % 240
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = false
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        let rows = spriteRows()
        let cellSize: CGFloat = 2
        let maxColumns = rows.map(\.count).max() ?? 0
        let spriteSize = NSSize(width: CGFloat(maxColumns) * cellSize, height: CGFloat(rows.count) * cellSize)
        let spriteYOffset = spriteYOffset()
        let origin = NSPoint(
            x: floor((bounds.width - spriteSize.width) / 2),
            y: floor((bounds.height - spriteSize.height) / 2) + 1 + spriteYOffset
        )

        drawPixelShadow(origin: origin)
        drawPixelTail(origin: origin, cellSize: cellSize)
        drawPixelRows(rows, origin: origin, cellSize: cellSize)
        if state == .ready {
            drawPixelActionBadge()
        }
        if state == .thinking {
            drawThinkingBadge()
        }
    }

    private func spriteYOffset() -> CGFloat {
        switch state {
        case .idle:
            return animationFrame % 90 >= 72 ? 0.5 : 0
        case .run:
            return (animationFrame / 4) % 2 == 0 ? 1 : 0
        case .ready:
            return animationFrame % 64 < 8 ? 0.75 : 0
        case .thinking:
            let phase = animationFrame % 32
            if phase < 8 { return 0 }
            if phase < 16 { return 0.5 }
            if phase < 24 { return 1 }
            return 0.5
        }
    }

    private func idleFaceOffset() -> Int {
        switch (animationFrame / 32) % 4 {
        case 1:
            return -1
        case 3:
            return 1
        default:
            return 0
        }
    }

    private func spriteRows() -> [String] {
        switch state {
        case .idle:
            return spriteRows(faceOffset: idleFaceOffset(), noseWidth: 1)
        case .run:
            if (animationFrame / 5) % 2 == 0 {
                return [
                    "................",
                    "..WG........GW..",
                    ".GWWW......WWWG.",
                    ".GWWWWWWWWWWWWG.",
                    "GWWWWWWWWWWWWWWG",
                    "WWWWKKWWWWKKWWWW",
                    "WWWWKKWWWWKKWWWW",
                    "GWWWWWWPWWWWWWWG",
                    "WWGWWWWWWWWWWGWW",
                    ".GWWWWWWWWWWWWG.",
                    "...WW......WWW..",
                    "................"
                ]
            } else {
                return [
                    "................",
                    "..WG........GW..",
                    ".GWWW......WWWG.",
                    ".GWWWWWWWWWWWWG.",
                    "GWWWWWWWWWWWWWWG",
                    "WWWWKKWWWWKKWWWW",
                    "WWWWKKWWWWKKWWWW",
                    "GWWWWWWPWWWWWWWG",
                    "WWGWWWWWWWWWWGWW",
                    ".GWWWWWWWWWWWWG.",
                    "..WWW......WW...",
                    "................"
                ]
            }
        case .ready:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .thinking:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        }
    }

    private func spriteRows(faceOffset: Int, noseWidth: Int) -> [String] {
        let eyeRow: String
        let noseRow: String
        switch faceOffset {
        case ..<0:
            eyeRow = "WWWKKWWWWKKWWWWW"
            noseRow = noseWidth == 1 ? "GWWWWWPWWWWWWWWG" : "GWWWWWPPWWWWWWWG"
        case 1...:
            eyeRow = "WWWWWKKWWWWKKWWW"
            noseRow = noseWidth == 1 ? "GWWWWWWWPWWWWWWG" : "GWWWWWWPPWWWWWWG"
        default:
            eyeRow = "WWWWKKWWWWKKWWWW"
            noseRow = noseWidth == 1 ? "GWWWWWWPWWWWWWWG" : "GWWWWWPPWWWWWWG."
        }

        return [
            "................",
            "..WG........GW..",
            ".GWWW......WWWG.",
            ".GWWWWWWWWWWWWG.",
            "GWWWWWWWWWWWWWWG",
            eyeRow,
            eyeRow,
            noseRow,
            "WWGWWWWWWWWWWGWW",
            ".GWWWWWWWWWWWWG.",
            "...WW......WW...",
            "................"
        ]
    }

    private func drawPixelRows(_ rows: [String], origin: NSPoint, cellSize: CGFloat) {
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, pixel) in row.enumerated() {
                guard let color = color(for: pixel) else { continue }
                color.setFill()
                let rect = NSRect(
                    x: origin.x + CGFloat(columnIndex) * cellSize,
                    y: origin.y + CGFloat(rows.count - rowIndex - 1) * cellSize,
                    width: cellSize,
                    height: cellSize
                )
                NSBezierPath(rect: rect).fill()
            }
        }
    }

    private func drawPixelTail(origin: NSPoint, cellSize: CGFloat) {
        let cells: [(Int, Int)]
        switch state {
        case .idle:
            switch (animationFrame / 24) % 3 {
            case 0:
                cells = [(7, 9), (7, 10), (8, 11), (9, 12), (10, 12)]
            case 1:
                cells = [(7, 9), (8, 10), (8, 11), (8, 12), (9, 12)]
            default:
                cells = [(7, 9), (8, 10), (7, 11), (6, 12), (5, 12)]
            }
        case .run:
            if (animationFrame / 5) % 2 == 0 {
                cells = [(7, 9), (7, 10), (8, 11), (10, 12), (11, 12)]
            } else {
                cells = [(8, 9), (8, 10), (7, 11), (5, 12), (4, 12)]
            }
        case .ready, .thinking:
            switch (animationFrame / 16) % 2 {
            case 0:
                cells = [(7, 9), (8, 10), (8, 11), (9, 12), (10, 12)]
            default:
                cells = [(7, 9), (7, 10), (8, 11), (8, 12), (9, 12)]
            }
        }

        let tailColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.90, alpha: 1.0)
        let tailShade = NSColor(srgbRed: 0.68, green: 0.72, blue: 0.73, alpha: 1.0)
        for (index, cell) in cells.enumerated() {
            (index == cells.count - 1 ? tailShade : tailColor).setFill()
            let rect = NSRect(
                x: origin.x + CGFloat(cell.0) * cellSize,
                y: origin.y + CGFloat(cell.1) * cellSize,
                width: cellSize,
                height: cellSize
            )
            NSBezierPath(rect: rect).fill()
        }
    }

    private func drawPixelShadow(origin: NSPoint) {
        NSColor(calibratedWhite: 0.0, alpha: 0.18).setFill()
        NSBezierPath(rect: NSRect(x: origin.x + 4, y: origin.y - 1, width: 22, height: 2)).fill()
        NSBezierPath(rect: NSRect(x: origin.x + 8, y: origin.y - 3, width: 14, height: 2)).fill()
    }

    private func drawPixelActionBadge() {
        switch mode {
        case .selection, .draftMessage:
            drawTranslateBadge()
        case .smartReply:
            drawReplyBadge()
        }
    }

    private func badgeOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
        NSPoint(x: bounds.width - width, y: bounds.height - height)
    }

    private func drawTranslateBadge() {
        let frame = NSRect(origin: badgeOrigin(width: 19, height: 14), size: NSSize(width: 19, height: 14))

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: frame.minX + 2, y: frame.minY - 1, width: 15, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let borderColor = NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        borderColor.setFill()
        shape.fill()

        let inner = frame.insetBy(dx: 1.5, dy: 1.5)
        let leftRect = NSRect(x: inner.minX, y: inner.minY, width: inner.width * 0.52, height: inner.height)
        let rightRect = NSRect(x: leftRect.maxX, y: inner.minY, width: inner.maxX - leftRect.maxX, height: inner.height)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(srgbRed: 0.02, green: 0.55, blue: 0.76, alpha: 1.0).setFill()
        NSBezierPath(rect: leftRect).fill()
        NSColor(srgbRed: 0.80, green: 0.86, blue: 0.87, alpha: 1.0).setFill()
        NSBezierPath(rect: rightRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        drawBadgeText("A", color: .white, fontSize: 8.5, in: NSRect(x: inner.minX - 0.5, y: inner.minY + 0.5, width: leftRect.width, height: inner.height))
        drawBadgeText("文", color: NSColor(srgbRed: 0.19, green: 0.34, blue: 0.39, alpha: 1.0), fontSize: 8, in: NSRect(x: rightRect.minX - 0.5, y: rightRect.minY + 0.5, width: rightRect.width + 1, height: rightRect.height))
    }

    private func drawReplyBadge() {
        let origin = badgeOrigin(width: 18, height: 16)
        let bubbleRect = NSRect(x: origin.x, y: origin.y + 3, width: 18, height: 13)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
        outline.move(to: NSPoint(x: bubbleRect.midX - 2, y: bubbleRect.minY + 1))
        outline.line(to: NSPoint(x: bubbleRect.midX, y: origin.y))
        outline.line(to: NSPoint(x: bubbleRect.midX + 2, y: bubbleRect.minY + 1))
        outline.close()
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let fill = NSBezierPath(roundedRect: bubbleRect.insetBy(dx: 1.7, dy: 1.7), xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        fill.fill()
        let tailFill = NSBezierPath()
        tailFill.move(to: NSPoint(x: bubbleRect.midX - 1.2, y: bubbleRect.minY + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX, y: origin.y + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX + 1.2, y: bubbleRect.minY + 2))
        tailFill.close()
        tailFill.fill()

        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1.0).setFill()
        for x in [bubbleRect.minX + 5, bubbleRect.midX, bubbleRect.maxX - 5] {
            NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: bubbleRect.midY - 1.1, width: 2.2, height: 2.2)).fill()
        }
    }

    private func drawThinkingBadge() {
        let origin = badgeOrigin(width: 18, height: 16)
        let bubbleRect = NSRect(x: origin.x, y: origin.y + 3, width: 18, height: 13)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
        outline.move(to: NSPoint(x: bubbleRect.midX - 2, y: bubbleRect.minY + 1))
        outline.line(to: NSPoint(x: bubbleRect.midX, y: origin.y))
        outline.line(to: NSPoint(x: bubbleRect.midX + 2, y: bubbleRect.minY + 1))
        outline.close()
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let fill = NSBezierPath(roundedRect: bubbleRect.insetBy(dx: 1.7, dy: 1.7), xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        fill.fill()
        let tailFill = NSBezierPath()
        tailFill.move(to: NSPoint(x: bubbleRect.midX - 1.2, y: bubbleRect.minY + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX, y: origin.y + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX + 1.2, y: bubbleRect.minY + 2))
        tailFill.close()
        tailFill.fill()

        // Animated dots: cycle one bright dot at a time
        let activeDot = (animationFrame / 8) % 3
        for (index, x) in [bubbleRect.minX + 5, bubbleRect.midX, bubbleRect.maxX - 5].enumerated() {
            let isActive = index == activeDot
            let color = isActive
                ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1.0)
                : NSColor(srgbRed: 0.55, green: 0.57, blue: 0.58, alpha: 1.0)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: bubbleRect.midY - 1.1, width: 2.2, height: 2.2)).fill()
        }
    }

    private func drawBadgeText(_ text: String, color: NSColor, fontSize: CGFloat, in rect: NSRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .black),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func color(for pixel: Character) -> NSColor? {
        switch pixel {
        case "W":
            return NSColor(srgbRed: 0.95, green: 0.96, blue: 0.92, alpha: 1)
        case "G":
            return NSColor(srgbRed: 0.70, green: 0.75, blue: 0.76, alpha: 1)
        case "K":
            return NSColor(srgbRed: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        case "P":
            return NSColor(srgbRed: 0.96, green: 0.55, blue: 0.65, alpha: 1)
        case "B":
            return NSColor(srgbRed: 0.97, green: 0.96, blue: 0.86, alpha: 1)
        case "D":
            return NSColor(srgbRed: 0.08, green: 0.16, blue: 0.20, alpha: 1)
        default:
            return nil
        }
    }

    private func tooltip(for state: State, mode: TranslationMode) -> String {
        switch state {
        case .idle, .run:
            return "Yaku pet"
        case .ready:
            switch mode {
            case .selection, .draftMessage:
                return "Translate selection - Tab to switch to Reply"
            case .smartReply:
                return "Generate reply - Tab to switch to Translate"
            }
        case .thinking:
            return "Thinking…"
        }
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

    func setLoading() {
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        buttonView.setLoading(true)
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
    private let progressIndicator = NSProgressIndicator()
    private var currentMode: TranslationMode
    private var isLoading = false

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

        let indicatorSize: CGFloat = 16
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.appearance = NSAppearance(named: .darkAqua)
        progressIndicator.frame = NSRect(
            x: (bounds.width - indicatorSize) / 2,
            y: (bounds.height - indicatorSize) / 2,
            width: indicatorSize,
            height: indicatorSize
        )
        progressIndicator.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        progressIndicator.isHidden = true
        glass.contentView.addSubview(progressIndicator)
    }

    func apply(mode: TranslationMode) {
        currentMode = mode
        guard !isLoading else { return }
        applyModeVisuals()
    }

    func setLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
        if loading {
            actionButton.isHidden = true
            actionButton.toolTip = nil
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            actionButton.isHidden = false
            applyModeVisuals()
        }
    }

    private func applyModeVisuals() {
        switch currentMode {
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
    enum Side { case left, right }

    enum Anchor {
        // Click point with explicit side. .right = panel goes right of point
        // (default for LTR drags / unknown direction). .left = panel goes left
        // of point (used when user dragged right-to-left in non-AX apps).
        case point(NSPoint, panelSide: Side)
        case selection(NSRect)      // selection rect, NSScreen coords (bottom-left origin)
    }

    private static let sideGap: CGFloat = 10
    private static let edgeMargin: CGFloat = 16

    private let panel: NSPanel
    private let contentView: TranslationContentView
    private let anchor: Anchor
    private var activeRequestID = UUID()
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    private var commandCopyInterceptor: CommandCopyInterceptor?
    private var didClose = false
    private let onClose: (() -> Void)?

    var panelFrame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }

    private let loadingPlaceholder: String

    init(
        anchor: Anchor,
        sourceText: String,
        targetLanguage: TranslationLanguage,
        resultLabel: String? = nil,
        loadingPlaceholder: String = "Translating",
        onTargetLanguageSelected: ((TranslationLanguage) -> Void)? = nil,
        onReplace: ((String) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.loadingPlaceholder = loadingPlaceholder
        self.anchor = anchor
        self.onClose = onClose
        let referencePoint = Self.anchorReferencePoint(for: anchor)
        let visibleFrame = NSScreen.visibleFrame(containing: referencePoint)
        let panelHeight = min(
            TranslationContentView.preferredHeight(sourceText: sourceText, resultText: "\(loadingPlaceholder)..."),
            visibleFrame.height - 32
        )
        let panelSize = NSSize(width: TranslationContentView.preferredWidth, height: panelHeight)
        let origin = Self.panelOrigin(anchor: anchor, panelSize: panelSize, visibleFrame: visibleFrame)
        let anchorY = TranslationContentView.anchorY(
            for: Self.anchorY(for: anchor),
            panelOriginY: origin.y,
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
        guard !didClose else {
            return
        }

        didClose = true
        contentView.stopLoadingAnimation()
        removeOutsideClickMonitors()
        removeCommandCopyInterceptor()
        panel.close()
        onClose?()
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
        let targetSize = NSSize(width: targetWidth, height: targetHeight)

        let targetOrigin: NSPoint
        if preserveCurrentPosition {
            // Resize-in-place: preserve top edge (panel.maxY) and X. Works
            // identically for both .point and .selection anchors.
            let preservedY = min(
                max(currentFrame.maxY - targetHeight, visibleFrame.minY + Self.edgeMargin),
                visibleFrame.maxY - targetHeight - Self.edgeMargin
            )
            let preservedX = min(
                max(currentFrame.minX, visibleFrame.minX + Self.edgeMargin),
                visibleFrame.maxX - targetWidth - Self.edgeMargin
            )
            targetOrigin = NSPoint(x: preservedX, y: preservedY)
        } else {
            targetOrigin = Self.panelOrigin(
                anchor: anchor,
                panelSize: targetSize,
                visibleFrame: visibleFrame
            )
        }

        let targetAnchorY = TranslationContentView.anchorY(
            for: Self.anchorY(for: anchor),
            panelOriginY: targetOrigin.y,
            panelHeight: targetHeight
        )
        contentView.setAnchorY(targetAnchorY)

        let targetFrame = NSRect(
            x: targetOrigin.x,
            y: targetOrigin.y,
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

    private static func anchorReferencePoint(for anchor: Anchor) -> NSPoint {
        switch anchor {
        case .point(let p, _):    return p
        case .selection(let r):   return NSPoint(x: r.midX, y: r.midY)
        }
    }

    private static func anchorY(for anchor: Anchor) -> CGFloat {
        switch anchor {
        case .point(let p, _):    return p.y
        case .selection(let r):   return r.midY
        }
    }

    private static func panelOrigin(
        anchor: Anchor,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        switch anchor {
        case .point(let p, let panelSide):
            // X depends on which side we want the panel relative to the point.
            // .right is the historical default (panel goes right of click point);
            // .left is used when the user dragged RTL so the panel flips to the
            // left to avoid overlapping the selection in non-AX apps.
            let desiredX: CGFloat
            switch panelSide {
            case .right: desiredX = p.x + sideGap
            case .left:  desiredX = p.x - sideGap - panelSize.width
            }
            let desiredY = p.y - panelSize.height * 0.52
            let clampedX = min(max(desiredX, visibleFrame.minX + edgeMargin),
                               visibleFrame.maxX - panelSize.width - edgeMargin)
            let clampedY = min(max(desiredY, visibleFrame.minY + edgeMargin),
                               visibleFrame.maxY - panelSize.height - edgeMargin)
            return NSPoint(x: clampedX, y: clampedY)

        case .selection(let sel):
            // Prefer right of the selection; fall back to left; if neither side
            // fits, gracefully degrade to .point at the selection center.
            let rightX = sel.maxX + sideGap
            let leftX  = sel.minX - sideGap - panelSize.width
            let rightFits = rightX + panelSize.width <= visibleFrame.maxX - edgeMargin
            let leftFits  = leftX >= visibleFrame.minX + edgeMargin

            let chosenX: CGFloat
            if rightFits {
                chosenX = rightX
            } else if leftFits {
                chosenX = leftX
            } else {
                return panelOrigin(
                    anchor: .point(NSPoint(x: sel.midX, y: sel.midY), panelSide: .right),
                    panelSize: panelSize,
                    visibleFrame: visibleFrame
                )
            }

            // Center-align: panel.midY lines up with sel.midY (vertical center of
            // the selection). Clamp inside the visible frame so a tall panel beside
            // a short selection doesn't escape the screen.
            let desiredY = sel.midY - panelSize.height / 2
            let clampedY = min(max(desiredY, visibleFrame.minY + edgeMargin),
                               visibleFrame.maxY - panelSize.height - edgeMargin)
            let clampedX = min(max(chosenX, visibleFrame.minX + edgeMargin),
                               visibleFrame.maxX - panelSize.width - edgeMargin)
            return NSPoint(x: clampedX, y: clampedY)
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

    func systemPrompt(
        targetLanguage: TranslationLanguage,
        appCategory: AppCategory,
        style: WritingStyle,
        cleanup: CleanupLevel,
        snippets: [Snippet]
    ) -> String {
        switch self {
        case .selection:
            """
            Translate the user's text into natural \(targetLanguage.promptName) by preserving the intended meaning, not by translating word-for-word. Silently clean accidental line breaks, repeated spaces, OCR artifacts, and hyphenated line wraps. Preserve proper names, dates, numbers, URLs, concrete facts, and paragraph/bullet/list structure. If the source is long or dense, split the translation into readable paragraphs instead of returning one wall of text.

            Context — the source text is from \(appCategory.promptHint)

            Cleanup — \(cleanup.promptDescription)\(TranslationMode.glossarySection(for: snippets, includeSnippets: false))

            Return only the \(targetLanguage.promptName) translation. No preamble, no commentary, no quotes around the output. Never write a wrapper like "Here is the translation:" — output the translated text directly.
            """
        case .draftMessage:
            """
            Rewrite the user's drafted outgoing message as a natural message in \(targetLanguage.promptName). Do not translate mechanically. Infer the user's actual intent, emotion, and social situation, then say it the way a native \(targetLanguage.promptName) speaker would send it in a chat or message.

            When goals conflict, follow this priority: (1) meaning, (2) the user's tone and intended directness/formality, (3) cultural naturalness — idioms, honorifics, word order, (4) surface details to preserve verbatim — emojis, URLs, usernames, product names, numbers, line breaks, (5) literal wording (always lowest). If the draft is blunt, the rewrite stays blunt — do not pad a curt one-liner into a polite paragraph just because the target language usually expects polite framing. If the draft is awkward or phrased like a direct translation, smooth it while keeping the same intent. If the draft is a fragment, return a natural sendable fragment without inventing extra context. If the draft is already in \(targetLanguage.promptName), lightly polish it only when needed.

            Context — the user is composing this message in \(appCategory.promptHint)

            Writing style — \(style.promptDescription)

            Cleanup — \(cleanup.promptDescription)\(TranslationMode.glossarySection(for: snippets, includeSnippets: true))

            Return only the final \(targetLanguage.promptName) message, with no commentary, labels, alternatives, quotes, or explanations.
            """
        case .smartReply:
            """
            The user has selected text in another app. The text is either (a) a message they received — email, chat message, DM, comment, support ticket, or similar; or (b) a question they need to answer — a quiz item, exam question, multiple-choice question, or open question. Decide which it is from the text itself, then respond appropriately. Always respond in the SAME language as the source text. Never translate.

            If it is a received message: write a natural, ready-to-send reply as if the user is sending it now. Match the tone, register, formality, and length of the original. Be concise. Don't restate or quote the original. Don't add greetings or sign-offs unless the original suggests them. Don't address the user — produce only the message body they would paste into the reply field.

            If it is a multiple-choice question: identify the correct option and respond with the option letter or number followed by the option text, then a brief one-sentence justification. Example: "B. Mitochondria — they generate most of the cell's ATP."

            If it is an open question: give a clear, direct answer. Keep it short unless the question demands depth.

            Context — the user is replying inside \(appCategory.promptHint)

            Cleanup — \(cleanup.promptDescription)\(TranslationMode.glossarySection(for: snippets, includeSnippets: false))

            Return only the reply or answer text. No commentary, no labels, no preface, no explanation of what you're doing, no quotes around the answer.
            """
        }
    }

    private static func glossarySection(for snippets: [Snippet], includeSnippets: Bool) -> String {
        let usable = snippets.filter(\.isUsable)
        guard !usable.isEmpty else { return "" }

        let expansions = includeSnippets ? usable.filter { $0.kind == .snippet } : []
        let dictionaryTerms = usable.filter { $0.kind == .dictionaryTerm }
        guard !expansions.isEmpty || !dictionaryTerms.isEmpty else { return "" }

        var sections: [String] = []
        sections.append(#"Glossary — apply these user-saved rules exactly when relevant."#)

        if !expansions.isEmpty {
            let lines = expansions.map { snippet -> String in
                let trigger = promptLine(snippet.trigger)
                let value = promptLine(snippet.value)
                return "- \"\(trigger)\" → \(value)"
            }
            sections.append("Snippets — expand BEFORE rewriting for tone/style. After expansion, treat the expanded text as canonical and do not paraphrase it:\n" + lines.joined(separator: "\n"))
        }

        if !dictionaryTerms.isEmpty {
            let lines = dictionaryTerms.map { "- \(promptLine($0.trigger))" }
            sections.append("Dictionary — preserve these terms verbatim. Never translate, paraphrase, or alter spelling/capitalization:\n" + lines.joined(separator: "\n"))
        }

        return "\n\n" + sections.joined(separator: "\n\n")
    }

    private static func promptLine(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum AppCategory: String, CaseIterable, Codable {
    case personalMessages
    case workMessages
    case email
    case other

    var displayName: String {
        switch self {
        case .personalMessages: return "Personal messages"
        case .workMessages: return "Work messages"
        case .email: return "Email"
        case .other: return "Other"
        }
    }

    var promptHint: String {
        switch self {
        case .personalMessages:
            return "a personal messaging app — chats with friends, family, partner. Informal medium where short, lowercased fragments are normal."
        case .workMessages:
            return "a workplace messaging app — Slack, Teams, LinkedIn. Colleagues and clients. Conversational but professional; complete thoughts but not stiff."
        case .email:
            return "an email client. Longer-form medium where greetings, full sentences, and sign-offs are normal."
        case .other:
            return "an unspecified app. No strong medium expectation — defer to the user's chosen style."
        }
    }
}

enum WritingStyle: String, CaseIterable, Codable {
    case formal
    case casual
    case excited

    var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .excited: return "Excited"
        }
    }

    var promptDescription: String {
        switch self {
        case .formal:
            return "full capitalization, complete punctuation, complete sentences. Polite, no exclamation marks unless the source had them."
        case .casual:
            return "natural casual capitalization (still capitalize names and sentence starts). Lighter punctuation — periods optional at the ends of short messages. Conversational rhythm."
        case .excited:
            return "energetic and enthusiastic. More exclamation marks where the source signal warrants them. Capitalization and punctuation otherwise normal."
        }
    }
}

enum CleanupLevel: String, CaseIterable, Codable {
    case none
    case light
    case medium
    case high

    var displayName: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var promptDescription: String {
        switch self {
        case .none:
            return "do not polish wording — preserve the source phrasing as faithfully as the target language allows."
        case .light:
            return "fix obvious typos, grammar errors, OCR/line-break artifacts. Do not rewrite for style."
        case .medium:
            return "edit lightly for clarity and flow — fix typos and awkward phrasing, but do not rephrase aggressively."
        case .high:
            return "polish thoroughly for brevity and clarity. Tighten verbose sentences, drop filler words, keep meaning intact."
        }
    }
}

enum AppCategoryClassifier {
    static let bundleIDMap: [String: AppCategory] = [
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.superhuman.electron": .email,
        "com.tinyspeck.slackmacgap": .workMessages,
        "com.microsoft.teams2": .workMessages,
        "com.microsoft.teams": .workMessages,
        "com.linkedin.LinkedIn": .workMessages,
        "com.apple.MobileSMS": .personalMessages,
        "com.apple.iChat": .personalMessages,
        "ru.keepcoder.Telegram": .personalMessages,
        "org.telegram.desktop": .personalMessages,
        "net.whatsapp.WhatsApp": .personalMessages,
        "com.kakao.KakaoTalk": .personalMessages,
        "com.hnc.Discord": .personalMessages,
    ]

    static func category(for bundleID: String?) -> AppCategory {
        guard let id = bundleID else { return .other }
        if let mapped = bundleIDMap[id] { return mapped }
        let lower = id.lowercased()
        if lower.contains("mail") || lower.contains("outlook") { return .email }
        if lower.contains("slack") || lower.contains("teams") { return .workMessages }
        return .other
    }

    static func detectFrontmost() -> (bundleID: String?, category: AppCategory) {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return (bundleID, category(for: bundleID))
    }
}

struct OllamaClient {
    let baseURL: URL
    let model: String

    func translate(
        _ text: String,
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode = .selection,
        appCategory: AppCategory,
        style: WritingStyle,
        cleanup: CleanupLevel,
        snippets: [Snippet],
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
                    content: mode.systemPrompt(
                        targetLanguage: targetLanguage,
                        appCategory: appCategory,
                        style: style,
                        cleanup: cleanup,
                        snippets: snippets
                    )
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
    case modelDownloading(String)

    var errorDescription: String? {
        switch self {
        case .ollama(let message):
            "Translation request failed: \(message)"
        case .emptyResponse:
            "Got an empty translation. Try again."
        case .serverUnavailable:
            "The translator isn't running. Open setup to fix it."
        case .modelMissing:
            "The translator isn't downloaded yet. Open setup to download it."
        case .signInRequired:
            "Online mode needs sign-in. Open setup to finish."
        case .modelDownloading(let detail):
            "\(detail) Try again when the translator is ready."
        }
    }
}

extension YakuApp: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        usageStatsStore.refresh()
        updateMenuState()
    }
}
