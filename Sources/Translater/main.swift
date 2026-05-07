import AppKit
import ApplicationServices
import Foundation

private enum MenuItemTag: Int {
    case appStatus = 100
    case accessibilityStatus = 101
    case accessibilitySettings = 102
    case refreshAccessibility = 103
    case targetLanguage = 104
    case quit = 105
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

    static func language(id: String) -> TranslationLanguage {
        all.first { $0.id == id } ?? defaultLanguage
    }
}

private enum TextNormalizer {
    static func cleanedSelection(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")

        cleaned = cleaned.replacingOccurrences(
            of: #"(?<=\p{L})-\n(?=\p{L})"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]*\n[ \t]*"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
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
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanedTranslation(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")

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
final class TranslaterApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mouseMonitor: Any?
    private let selectionReader = SelectionReader()
    private let ollamaClient = OllamaClient(
        baseURL: URL(string: "http://127.0.0.1:11434")!,
        model: "gpt-oss:120b-cloud"
    )

    private var translateButtonController: FloatingTranslateButtonController?
    private var translationPanelController: TranslationPanelController?
    private var translationPrefetch: TranslationPrefetch?
    private lazy var translationCache = TranslationCache()
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

    private let prefetchDelayMilliseconds: UInt64 = 220
    private let prefetchMaxCharacterCount = 1_200

    static func main() {
        let app = NSApplication.shared
        let delegate = TranslaterApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        requestAccessibilityPermissionIfNeeded()
        startMouseMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "あ"
        statusItem.button?.toolTip = "Translater"

        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: "Translater", action: nil, keyEquivalent: "")
        status.tag = MenuItemTag.appStatus.rawValue
        status.isEnabled = false
        menu.addItem(status)

        let accessibilityStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        accessibilityStatus.tag = MenuItemTag.accessibilityStatus.rawValue
        accessibilityStatus.isEnabled = false
        menu.addItem(accessibilityStatus)

        menu.addItem(NSMenuItem.separator())

        let accessibilitySettingsItem = NSMenuItem(
            title: "Open Accessibility Settings",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilitySettingsItem.tag = MenuItemTag.accessibilitySettings.rawValue
        accessibilitySettingsItem.target = self
        menu.addItem(accessibilitySettingsItem)

        let refreshItem = NSMenuItem(
            title: "Refresh Accessibility Status",
            action: #selector(refreshAccessibilityStatus),
            keyEquivalent: "r"
        )
        refreshItem.tag = MenuItemTag.refreshAccessibility.rawValue
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let targetLanguageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        targetLanguageItem.tag = MenuItemTag.targetLanguage.rawValue
        targetLanguageItem.submenu = makeTargetLanguageMenu()
        menu.addItem(targetLanguageItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.tag = MenuItemTag.quit.rawValue
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
        updateMenuState()
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

    private func startMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            self?.handleMouseUp(event)
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

            guard let selection = self.selectionReader.readSelectedText(), !selection.text.isEmpty else {
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

            self.showTranslateButton(for: cleanedSelection, near: NSEvent.mouseLocation)
        }
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
    private func translate(_ text: String, near screenPoint: NSPoint) {
        let language = targetLanguage
        let controller = TranslationPanelController(
            screenPoint: screenPoint,
            sourceText: text,
            targetLanguage: language
        )
        translationPanelController?.close()
        translationPanelController = controller
        controller.showLoading()

        if let cachedTranslation = translationCache.translation(for: text, targetLanguage: language) {
            controller.showTranslation(cachedTranslation)
            return
        }

        if let translationPrefetch,
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
                let translated = try await ollamaClient.translate(text, to: language) { partialTranslation in
                    Task { @MainActor in
                        controller.showTranslation(partialTranslation)
                    }
                }
                await MainActor.run {
                    self.translationCache.store(translated, for: text, targetLanguage: language)
                    controller.showTranslation(translated)
                }
            } catch {
                await MainActor.run {
                    controller.showError(error.localizedDescription)
                }
            }
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
        menu.item(withTag: MenuItemTag.appStatus.rawValue)?.title = trusted
            ? "Translater Ready"
            : "Translater Needs Permission"
        menu.item(withTag: MenuItemTag.accessibilityStatus.rawValue)?.title = trusted
            ? "Accessibility: Enabled"
            : "Enable Accessibility, then quit and reopen"
        menu.item(withTag: MenuItemTag.targetLanguage.rawValue)?.title = "Translate To: \(targetLanguage.displayName)"

        if let languageMenu = menu.item(withTag: MenuItemTag.targetLanguage.rawValue)?.submenu {
            for item in languageMenu.items {
                guard let languageID = item.representedObject as? String else { continue }
                item.state = languageID == targetLanguage.id ? .on : .off
            }
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func refreshAccessibilityStatus() {
        updateMenuState()
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

struct SelectedText {
    let text: String
}

final class SelectionReader {
    func readSelectedText() -> SelectedText? {
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

        guard let text = selectedText(from: focusedElement as! AXUIElement) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return SelectedText(text: trimmed)
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

final class FloatingTranslateButtonController {
    private let panel: NSPanel
    private let selectedText: String
    private let onTranslate: (String) -> Void

    init(screenPoint: NSPoint, selectedText: String, onTranslate: @escaping (String) -> Void) {
        self.selectedText = selectedText
        self.onTranslate = onTranslate

        let size = NSSize(width: 28, height: 28)
        let origin = NSPoint(x: screenPoint.x + 5, y: screenPoint.y - size.height - 5)
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
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
        panel.ignoresMouseEvents = false
        panel.contentView = FloatingTranslateButtonView { [weak self] in
            guard let self else { return }
            self.onTranslate(self.selectedText)
        }
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
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        wantsLayer = true
        buildUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func buildUI() {
        let glass = GlassHostView(
            frame: bounds,
            cornerRadius: 9,
            tintColor: NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.28, alpha: 0.52),
            style: .regular
        )
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        let button = NSButton(title: "あ", target: self, action: #selector(buttonTapped))
        button.frame = glass.contentView.bounds
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

    init(screenPoint: NSPoint, sourceText: String, targetLanguage: TranslationLanguage) {
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

        contentView = TranslationContentView(sourceText: sourceText, targetLanguage: targetLanguage)
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
    private static let resultFontSize: CGFloat = 17
    private static let boxInsetX: CGFloat = 14
    private static let boxInsetY: CGFloat = 10

    var onClose: (() -> Void)?

    private let sourceText: String
    private let targetLanguage: TranslationLanguage
    private var resultText = "Translating..."
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
    private var selectionCopyBubble: GlassHostView?
    private var selectionCopyButton: NSButton?
    private var selectedSnippetToCopy: String?
    private weak var selectedTextView: NSTextView?
    private var shouldScrollSourceToTop = true
    private var shouldScrollResultToTop = true

    init(sourceText: String, targetLanguage: TranslationLanguage) {
        self.sourceText = sourceText
        self.targetLanguage = targetLanguage
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
            font: NSFont.systemFont(ofSize: resultFontSize, weight: .medium),
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
        Self.preferredHeight(sourceText: sourceText, resultText: resultText)
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

        let fitsInScrollFrame = rawTextHeight + 4 <= scrollFrame.height
        let verticalInset: CGFloat
        let textViewHeight: CGFloat
        if fitsInScrollFrame {
            verticalInset = floor(max(2, (scrollFrame.height - rawTextHeight) / 2))
            textViewHeight = scrollFrame.height
        } else {
            verticalInset = 2
            textViewHeight = max(scrollFrame.height, rawTextHeight + 8)
        }

        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: scrollFrame.width, height: textViewHeight)
        )
        textView.minSize = NSSize(width: 0, height: scrollFrame.height)
        textView.textContainer?.containerSize = NSSize(
            width: scrollFrame.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.hasVerticalScroller = !fitsInScrollFrame
    }

    private static func textHeight(for text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let cleanText = text.isEmpty ? " " : text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let rect = (cleanText as NSString).boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraph
            ]
        )
        return ceil(rect.height)
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

        let sourceBox = GlassHostView(
            frame: .zero,
            cornerRadius: 12,
            tintColor: NSColor(calibratedWhite: 0.0, alpha: 0.22),
            style: .clear
        )
        content.addSubview(sourceBox)
        self.sourceBox = sourceBox

        sourceScrollView.drawsBackground = false
        sourceScrollView.hasVerticalScroller = true
        sourceScrollView.autohidesScrollers = true
        sourceScrollView.borderType = .noBorder
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

        let resultBox = GlassHostView(
            frame: .zero,
            cornerRadius: 12,
            tintColor: NSColor(calibratedWhite: 0.0, alpha: 0.22),
            style: .clear
        )
        content.addSubview(resultBox)
        self.resultBox = resultBox

        resultScrollView.drawsBackground = false
        resultScrollView.hasVerticalScroller = true
        resultScrollView.autohidesScrollers = true
        resultScrollView.borderType = .noBorder

        configureTextView(
            resultTextView,
            text: resultText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .medium),
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
        targetTitleLabel.frame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth - Self.buttonSize - 8,
            height: Self.labelHeight
        )
        copyButton?.frame = NSRect(
            x: bounds.width - Self.panelPaddingX - Self.buttonSize,
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
            for: resultText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .medium),
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

        let isStreamingAppend = !resultText.isEmpty && cleanedText.hasPrefix(resultText)
        if !isStreamingAppend {
            shouldScrollResultToTop = true
        }

        if isStreamingAppend, let textStorage = resultTextView.textStorage {
            let suffix = String(cleanedText.dropFirst(resultText.count))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: resultTextView.font ?? NSFont.systemFont(ofSize: Self.resultFontSize, weight: .medium),
                .foregroundColor: resultTextView.textColor ?? NSColor.white
            ]
            textStorage.append(NSAttributedString(string: suffix, attributes: attrs))
        } else {
            resultTextView.string = cleanedText
        }

        resultText = cleanedText
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

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct OllamaClient {
    let baseURL: URL
    let model: String

    func translate(_ text: String, to targetLanguage: TranslationLanguage, onPartial: @escaping (String) -> Void) async throws -> String {
        let sourceText = TextNormalizer.cleanedSelection(text)
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
                    content: """
                    Translate the user's text into natural \(targetLanguage.promptName). The source may come from a messy UI text selection, so silently clean accidental line breaks, repeated spaces, and hyphenated line wraps before translating. Preserve the intended meaning, proper names, dates, and paragraph-like readability. Return only the \(targetLanguage.promptName) translation, with no commentary.
                    """
                ),
                ChatMessage(role: "user", content: sourceText)
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw TranslationError.ollama("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        var translated = ""
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else {
                continue
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

enum TranslationError: LocalizedError {
    case ollama(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .ollama(let message):
            "Ollama request failed: \(message)"
        case .emptyResponse:
            "Ollama returned an empty translation."
        }
    }
}

extension TranslaterApp: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
    }
}
