import AppKit
import ApplicationServices
import Foundation

private enum MenuItemTag: Int {
    case appStatus = 100
    case accessibilityStatus = 101
    case accessibilitySettings = 102
    case refreshAccessibility = 103
    case quit = 104
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

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.tag = MenuItemTag.quit.rawValue
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
        updateMenuState()
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }

            guard let selection = self.selectionReader.readSelectedText(), !selection.text.isEmpty else {
                self.translateButtonController?.close()
                self.translateButtonController = nil
                return
            }

            self.showTranslateButton(for: selection.text, near: NSEvent.mouseLocation)
        }
    }

    private func showTranslateButton(for selectedText: String, near screenPoint: NSPoint) {
        translationPanelController?.close()
        translateButtonController?.close()

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

    private func translate(_ text: String, near screenPoint: NSPoint) {
        let controller = TranslationPanelController(
            screenPoint: screenPoint,
            sourceText: text
        )
        translationPanelController?.close()
        translationPanelController = controller
        controller.showLoading()

        Task {
            do {
                let translated = try await ollamaClient.translateToRussian(text)
                await MainActor.run {
                    controller.showTranslation(translated)
                }
            } catch {
                await MainActor.run {
                    controller.showError(error.localizedDescription)
                }
            }
        }
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
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func refreshAccessibilityStatus() {
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

    init(screenPoint: NSPoint, sourceText: String) {
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

        contentView = TranslationContentView(sourceText: sourceText)
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
        resizeToFitContent(animated: true)
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
        panel.setFrame(targetFrame, display: true, animate: animated)
        contentView.setFrameSize(targetFrame.size)
        contentView.layoutForCurrentSize()
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

final class TranslationContentView: NSView {
    static let preferredWidth: CGFloat = 440
    private static let minHeight: CGFloat = 238
    private static let maxHeight: CGFloat = 520
    private static let contentWidth: CGFloat = 404
    private static let minimumSourceBoxHeight: CGFloat = 46
    private static let minimumResultBoxHeight: CGFloat = 78
    private static let maximumSourceBoxHeight: CGFloat = 136
    private static let maximumResultBoxHeight: CGFloat = 260

    var onClose: (() -> Void)?

    private let sourceText: String
    private var resultText = "Translating..."
    private let resultTextView = NSTextView()
    private let sourceTitleLabel = NSTextField(labelWithString: "source")
    private let russianTitleLabel = NSTextField(labelWithString: "russian")
    private let sourceTextField: NSTextField
    private let resultScrollView = NSScrollView()
    private var panelGlass: GlassHostView?
    private var sourceBox: GlassHostView?
    private var resultBox: GlassHostView?
    private var closeButton: NSButton?
    private var copyButton: NSButton?

    init(sourceText: String) {
        self.sourceText = sourceText
        sourceTextField = NSTextField(labelWithString: sourceText)
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
            font: NSFont.systemFont(ofSize: 16, weight: .medium),
            width: contentWidth - 24,
            minimum: minimumSourceBoxHeight,
            maximum: maximumSourceBoxHeight
        )
        let resultBoxHeight = boxHeight(
            for: resultText,
            font: NSFont.systemFont(ofSize: 17, weight: .medium),
            width: contentWidth - 60,
            minimum: minimumResultBoxHeight,
            maximum: maximumResultBoxHeight
        )

        let fixedHeight: CGFloat = 24 + 18 + 7 + 14 + 18 + 7 + 18
        return min(max(fixedHeight + sourceBoxHeight + resultBoxHeight, minHeight), maxHeight)
    }

    func preferredHeightForCurrentContent() -> CGFloat {
        Self.preferredHeight(sourceText: sourceText, resultText: resultText)
    }

    private static func boxHeight(for text: String, font: NSFont, width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let height = textHeight(for: text, font: font, width: width) + 20
        return min(max(height, minimum), maximum)
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
            cornerRadius: 24,
            tintColor: NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.23, alpha: 0.48),
            style: .regular
        )
        panelGlass.autoresizingMask = [.width, .height]
        addSubview(panelGlass)
        let content = panelGlass.contentView
        self.panelGlass = panelGlass

        closeButton = addToolbarButton(
            symbolName: "xmark",
            accessibilityDescription: "Close",
            frame: .zero,
            target: self,
            action: #selector(closeTapped),
            to: content
        )

        configureLabel(sourceTitleLabel)
        content.addSubview(sourceTitleLabel)

        let sourceBox = GlassHostView(
            frame: .zero,
            cornerRadius: 16,
            tintColor: NSColor(calibratedRed: 0.02, green: 0.05, blue: 0.11, alpha: 0.28),
            style: .clear
        )
        content.addSubview(sourceBox)
        self.sourceBox = sourceBox

        sourceTextField.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        sourceTextField.textColor = .white
        sourceTextField.lineBreakMode = .byWordWrapping
        sourceTextField.maximumNumberOfLines = 0
        sourceBox.contentView.addSubview(sourceTextField)

        configureLabel(russianTitleLabel)
        content.addSubview(russianTitleLabel)

        let resultBox = GlassHostView(
            frame: .zero,
            cornerRadius: 16,
            tintColor: NSColor(calibratedRed: 0.02, green: 0.05, blue: 0.11, alpha: 0.28),
            style: .clear
        )
        content.addSubview(resultBox)
        self.resultBox = resultBox

        copyButton = addToolbarButton(
            symbolName: "square.on.square",
            accessibilityDescription: "Copy translation",
            frame: .zero,
            target: self,
            action: #selector(copyResult),
            to: content
        )

        resultScrollView.drawsBackground = false
        resultScrollView.hasVerticalScroller = true
        resultScrollView.autohidesScrollers = true
        resultScrollView.borderType = .noBorder

        resultTextView.drawsBackground = false
        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.textColor = .white
        resultTextView.font = NSFont.systemFont(ofSize: 17, weight: .medium)
        resultTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        resultTextView.isVerticallyResizable = true
        resultTextView.isHorizontallyResizable = false
        resultTextView.autoresizingMask = [.width]
        resultTextView.textContainer?.widthTracksTextView = true
        resultTextView.textContainerInset = NSSize(width: 0, height: 2)
        resultScrollView.documentView = resultTextView
        resultBox.contentView.addSubview(resultScrollView)

        setResult(resultText)
    }

    @discardableResult
    private func addToolbarButton(
        symbolName: String,
        accessibilityDescription: String,
        frame: NSRect,
        target: AnyObject,
        action: Selector,
        to parent: NSView
    ) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.frame = frame
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor(calibratedRed: 0.78, green: 0.82, blue: 0.88, alpha: 0.9)
        button.toolTip = accessibilityDescription
        parent.addSubview(button)
        return button
    }

    private func configureLabel(_ label: NSTextField) {
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.96, alpha: 0.88)
    }

    func layoutForCurrentSize() {
        let sourceBoxHeight = Self.boxHeight(
            for: sourceText,
            font: NSFont.systemFont(ofSize: 16, weight: .medium),
            width: Self.contentWidth - 24,
            minimum: Self.minimumSourceBoxHeight,
            maximum: Self.maximumSourceBoxHeight
        )
        let fixedHeight: CGFloat = 24 + 18 + 7 + 14 + 18 + 7 + 18
        let availableBoxHeight = max(
            Self.minimumSourceBoxHeight + Self.minimumResultBoxHeight,
            bounds.height - fixedHeight
        )
        let resolvedSourceBoxHeight = min(
            sourceBoxHeight,
            max(Self.minimumSourceBoxHeight, availableBoxHeight - Self.minimumResultBoxHeight)
        )
        let resolvedResultBoxHeight = max(Self.minimumResultBoxHeight, availableBoxHeight - resolvedSourceBoxHeight)

        closeButton?.frame = NSRect(x: bounds.width - 46, y: bounds.height - 46, width: 24, height: 24)

        var y = bounds.height - 24 - 18
        sourceTitleLabel.frame = NSRect(x: 24, y: y, width: 130, height: 18)
        y -= 7 + resolvedSourceBoxHeight
        sourceBox?.frame = NSRect(x: 18, y: y, width: Self.contentWidth, height: resolvedSourceBoxHeight)
        sourceTextField.frame = NSRect(
            x: 12,
            y: 8,
            width: Self.contentWidth - 24,
            height: resolvedSourceBoxHeight - 16
        )

        y -= 14 + 18
        russianTitleLabel.frame = NSRect(x: 24, y: y, width: 130, height: 18)
        y -= 7 + resolvedResultBoxHeight
        let resultBoxFrame = NSRect(x: 18, y: y, width: Self.contentWidth, height: resolvedResultBoxHeight)
        resultBox?.frame = resultBoxFrame
        copyButton?.frame = NSRect(
            x: resultBoxFrame.maxX - 36,
            y: resultBoxFrame.maxY - 34,
            width: 24,
            height: 24
        )

        let resultScrollFrame = NSRect(
            x: 12,
            y: 10,
            width: Self.contentWidth - 60,
            height: resolvedResultBoxHeight - 20
        )
        resultScrollView.frame = resultScrollFrame
        let resultTextHeight = Self.textHeight(
            for: resultText,
            font: NSFont.systemFont(ofSize: 17, weight: .medium),
            width: resultScrollFrame.width
        ) + 8
        resultTextView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: resultScrollFrame.width, height: max(resultScrollFrame.height, resultTextHeight))
        )
        resultTextView.minSize = NSSize(width: 0, height: resultScrollFrame.height)
        resultTextView.textContainer?.containerSize = NSSize(
            width: resultScrollFrame.width,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    func setResult(_ text: String) {
        resultText = text
        resultTextView.string = text
        layoutForCurrentSize()
    }

    @objc private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultTextView.string, forType: .string)
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

struct OllamaClient {
    let baseURL: URL
    let model: String

    func translateToRussian(_ text: String) async throws -> String {
        let url = baseURL.appending(path: "api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body = ChatRequest(
            model: model,
            stream: false,
            messages: [
                ChatMessage(
                    role: "system",
                    content: "You translate text into Russian. Return only the Russian translation, with no commentary."
                ),
                ChatMessage(role: "user", content: text)
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown Ollama error"
            throw TranslationError.ollama(body)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let translated = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else {
            throw TranslationError.emptyResponse
        }

        return translated
    }
}

struct ChatRequest: Encodable {
    let model: String
    let stream: Bool
    let messages: [ChatMessage]
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatResponse: Decodable {
    let message: ChatMessage
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
