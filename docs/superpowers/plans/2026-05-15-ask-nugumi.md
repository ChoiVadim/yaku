# Ask Nugumi Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Ask Nugumi: double-Control opens a near-cursor prompt, sends the prompt plus active-screen screenshot to a vision LLM, shows the answer, and optionally moves the pet to a returned normalized target.

**Architecture:** Add pure Ask Nugumi data/parsing/coordinate logic in a focused source file so it is unit-testable. Keep AppKit UI wiring in `App.swift` near existing floating panel, screenshot, backend, and pet controllers. Add a modifier-only Control detector in `GlobalShortcuts.swift` because Carbon hotkeys cannot detect double-Control.

**Tech Stack:** Swift 6 package, macOS 14 AppKit, XCTest, Vision-capable OpenAI-compatible chat completion backends, existing Nugumi `ImageInput`, `LLMBackend`, `ScreenshotCapture`, `TranslationPanelController`, and `PetController`.

---

## File Structure

- Create `Sources/Nugumi/AskNugumi.swift`: pure models, JSON extraction/parsing, normalized coordinate validation, AppKit coordinate mapping.
- Create `Tests/NugumiTests/AskNugumiTests.swift`: parser and coordinate conversion tests.
- Modify `Sources/Nugumi/App.swift`: prompt controller, full-screen capture API, backend `ask` method, app orchestration, result presentation, pet pointing.
- Modify `Sources/Nugumi/GlobalShortcuts.swift`: `DoubleControlPressDetector` for modifier-only gesture.
- No docs update required beyond the design and this implementation plan.

Do not edit unrelated cloud-backend, invisibility-mode, or menu-copy work unless a compile error requires integration.

## Task 1: Ask Nugumi Models, Parser, And Coordinate Tests

**Files:**
- Create: `Sources/Nugumi/AskNugumi.swift`
- Create: `Tests/NugumiTests/AskNugumiTests.swift`

- [ ] **Step 1: Write failing parser and coordinate tests**

Create `Tests/NugumiTests/AskNugumiTests.swift`:

```swift
import XCTest
@testable import Nugumi

final class AskNugumiTests: XCTestCase {
    func testParsesStrictJSONResponse() throws {
        let raw = """
        {"message":"Click Save.","petTarget":{"x":0.82,"y":0.18,"coordinateSpace":"screenshot_normalized"}}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Click Save.")
        XCTAssertEqual(response.petTarget?.x, 0.82)
        XCTAssertEqual(response.petTarget?.y, 0.18)
        XCTAssertEqual(response.petTarget?.coordinateSpace, .screenshotNormalized)
    }

    func testExtractsJSONFromFencedResponse() throws {
        let raw = """
        Here is the answer:
        ```json
        {"message":"Use the button on the right.","petTarget":{"x":0.9,"y":0.5,"coordinateSpace":"screenshot_normalized"}}
        ```
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Use the button on the right.")
        XCTAssertEqual(response.petTarget?.x, 0.9)
        XCTAssertEqual(response.petTarget?.y, 0.5)
    }

    func testFallsBackToPlainMessageForNonJSON() {
        let response = AskNugumiResponse.parse("The save button is at the top right.")

        XCTAssertEqual(response.message, "The save button is at the top right.")
        XCTAssertNil(response.petTarget)
    }

    func testRejectsInvalidTargetCoordinates() {
        let raw = """
        {"message":"Click there.","petTarget":{"x":1.4,"y":0.2,"coordinateSpace":"screenshot_normalized"}}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Click there.")
        XCTAssertNil(response.petTarget)
    }

    func testRejectsUnsupportedCoordinateSpace() {
        let raw = """
        {"message":"Click there.","petTarget":{"x":0.4,"y":0.2,"coordinateSpace":"screen_pixels"}}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Click there.")
        XCTAssertNil(response.petTarget)
    }

    func testMapsTopLeftNormalizedCoordinateToAppKitScreenPoint() {
        let screenFrame = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let visibleFrame = CGRect(x: 100, y: 200, width: 1000, height: 760)
        let target = AskNugumiPetTarget(
            x: 0.25,
            y: 0.10,
            coordinateSpace: .screenshotNormalized
        )

        let point = AskNugumiCoordinateMapper.screenPoint(
            for: target,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(point.x, 350, accuracy: 0.001)
        XCTAssertEqual(point.y, 920, accuracy: 0.001)
    }

    func testClampsMappedCoordinateToVisibleFrame() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let visibleFrame = CGRect(x: 50, y: 40, width: 900, height: 700)
        let target = AskNugumiPetTarget(
            x: 1.0,
            y: 1.0,
            coordinateSpace: .screenshotNormalized
        )

        let point = AskNugumiCoordinateMapper.screenPoint(
            for: target,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(point.x, 950, accuracy: 0.001)
        XCTAssertEqual(point.y, 40, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter AskNugumiTests
```

Expected: compile failure because `AskNugumiResponse`, `AskNugumiPetTarget`, and `AskNugumiCoordinateMapper` do not exist.

- [ ] **Step 3: Implement pure Ask Nugumi types**

Create `Sources/Nugumi/AskNugumi.swift`:

```swift
import Foundation
import CoreGraphics

enum AskNugumiCoordinateSpace: String, Codable, Equatable {
    case screenshotNormalized = "screenshot_normalized"
}

struct AskNugumiPetTarget: Codable, Equatable {
    let x: Double
    let y: Double
    let coordinateSpace: AskNugumiCoordinateSpace

    var isValid: Bool {
        x.isFinite
            && y.isFinite
            && (0.0...1.0).contains(x)
            && (0.0...1.0).contains(y)
            && coordinateSpace == .screenshotNormalized
    }
}

struct AskNugumiResponse: Codable, Equatable {
    let message: String
    let petTarget: AskNugumiPetTarget?

    static func parse(_ rawText: String) -> AskNugumiResponse {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AskNugumiResponse(message: "", petTarget: nil)
        }

        if let decoded = decode(from: trimmed) {
            return decoded
        }

        if let json = firstJSONObject(in: trimmed),
           let decoded = decode(from: json) {
            return decoded
        }

        return AskNugumiResponse(message: trimmed, petTarget: nil)
    }

    private static func decode(from text: String) -> AskNugumiResponse? {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AskNugumiResponse.self, from: data)
        else {
            return nil
        }

        let cleanMessage = decoded.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty else {
            return nil
        }

        return AskNugumiResponse(
            message: cleanMessage,
            petTarget: decoded.petTarget.flatMap { $0.isValid ? $0 : nil }
        )
    }

    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }

            index = text.index(after: index)
        }

        return nil
    }
}

enum AskNugumiCoordinateMapper {
    static func screenPoint(
        for target: AskNugumiPetTarget,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGPoint {
        let rawX = screenFrame.minX + CGFloat(target.x) * screenFrame.width
        let rawY = screenFrame.maxY - CGFloat(target.y) * screenFrame.height
        return CGPoint(
            x: min(max(rawX, visibleFrame.minX), visibleFrame.maxX),
            y: min(max(rawY, visibleFrame.minY), visibleFrame.maxY)
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
swift test --filter AskNugumiTests
```

Expected: all `AskNugumiTests` pass.

- [ ] **Step 5: Run full test suite**

Run:

```bash
swift test
```

Expected: all tests pass, including existing `UsageStatsSnapshotTests`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/AskNugumi.swift Tests/NugumiTests/AskNugumiTests.swift
git commit -m "Add Ask Nugumi response parsing"
```

## Task 2: Full Active-Screen Capture API

**Files:**
- Modify: `Sources/Nugumi/App.swift`
- Test: manual permission/capture verification in `swift run Nugumi`

- [ ] **Step 1: Add capture result type and screen capture method**

In `Sources/Nugumi/App.swift`, near `enum ScreenshotCapture`, add:

```swift
struct AskNugumiScreenCapture {
    let image: ImageInput
    let screenFrame: CGRect
    let visibleFrame: CGRect
}
```

Inside `enum ScreenshotCapture`, add:

```swift
static func captureActiveScreen(containing point: NSPoint = NSEvent.mouseLocation) async throws -> AskNugumiScreenCapture {
    guard CGPreflightScreenCaptureAccess() else {
        throw ScreenshotTranslationError.screenRecordingPermissionDenied
    }

    let screen = NSScreen.screens.first { $0.frame.contains(point) }
        ?? NSScreen.main
        ?? NSScreen.screens.first

    guard let screen else {
        throw ScreenshotTranslationError.captureFailedDetail("No screen is available.")
    }

    guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
          let cgImage = CGDisplayCreateImage(screenID)
    else {
        throw ScreenshotTranslationError.captureFailedDetail("Could not capture the active screen.")
    }

    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw ScreenshotTranslationError.captureFailedDetail("Could not encode the active screen.")
    }

    return AskNugumiScreenCapture(
        image: ImageInput(data: pngData, mediaType: "image/png"),
        screenFrame: screen.frame,
        visibleFrame: screen.visibleFrame
    )
}
```

- [ ] **Step 2: Build to catch compile errors**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Add active screen capture for Ask Nugumi"
```

## Task 3: Backend Ask Method For Vision Models

**Files:**
- Modify: `Sources/Nugumi/App.swift`
- Test: `swift build`; manual API test after full flow is wired

- [ ] **Step 1: Extend `LLMBackend` protocol**

In `Sources/Nugumi/App.swift`, update `protocol LLMBackend` to include:

```swift
func ask(
    prompt: String,
    image: ImageInput,
    onPartial: @escaping (String) -> Void
) async throws -> AskNugumiResponse
```

- [ ] **Step 2: Add unsupported implementation to `OllamaClient`**

Inside `struct OllamaClient`, add:

```swift
func ask(
    prompt: String,
    image: ImageInput,
    onPartial: @escaping (String) -> Void
) async throws -> AskNugumiResponse {
    throw TranslationError.ollama("Ask Nugumi needs a vision model.")
}
```

- [ ] **Step 3: Add Ask prompt to `OpenAIChatClient`**

Inside `struct OpenAIChatClient`, add:

```swift
private static let askSystemPrompt = """
You are Nugumi, a concise desktop visual assistant. The user will provide a screenshot and a question about what is visible on screen.

Return only JSON with this shape:
{"message":"short helpful answer","petTarget":{"x":0.0,"y":0.0,"coordinateSpace":"screenshot_normalized"}}

Rules:
- `message` is required and must be useful on its own.
- Include `petTarget` only when pointing to a visible screen location helps.
- `petTarget.x` is left-to-right from 0.0 to 1.0 across the screenshot.
- `petTarget.y` is top-to-bottom from 0.0 to 1.0 across the screenshot.
- Use coordinateSpace exactly "screenshot_normalized".
- Do not click, automate, or claim you took an action.
- If uncertain, omit `petTarget` and explain what to look for in `message`.
"""
```

- [ ] **Step 4: Implement `OpenAIChatClient.ask`**

Inside `struct OpenAIChatClient`, add:

```swift
func ask(
    prompt: String,
    image: ImageInput,
    onPartial: @escaping (String) -> Void
) async throws -> AskNugumiResponse {
    guard !apiKey.isEmpty else {
        throw TranslationError.invalidAPIKey(provider)
    }

    guard LLMModel.option(id: model).supportsImages else {
        throw TranslationError.cloudError(provider, "Ask Nugumi needs a vision model.")
    }

    guard image.data.count <= Self.maxImageBytes else {
        throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
    }

    let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanPrompt.isEmpty else {
        return AskNugumiResponse(message: "", petTarget: nil)
    }

    let userContent = OpenAIContent.parts([
        .text(cleanPrompt),
        .imageURL(image.openAIDataURI)
    ])

    let body = OpenAIRequest(
        model: model,
        stream: true,
        messages: [
            OpenAIMessage(role: "system", content: .string(Self.askSystemPrompt)),
            OpenAIMessage(role: "user", content: userContent)
        ]
    )

    var request = URLRequest(url: provider.baseURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 120
    request.httpBody = try JSONEncoder().encode(body)

    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
        (bytes, response) = try await URLSession.shared.bytes(for: request)
    } catch let urlError as URLError where urlError.code == .cannotConnectToHost
        || urlError.code == .cannotFindHost
        || urlError.code == .networkConnectionLost
        || urlError.code == .notConnectedToInternet
        || urlError.code == .timedOut {
        throw TranslationError.serverUnavailable
    }

    guard let httpResponse = response as? HTTPURLResponse else {
        throw TranslationError.cloudError(provider, "invalid response")
    }

    switch httpResponse.statusCode {
    case 200..<300:
        break
    case 401, 403:
        throw TranslationError.invalidAPIKey(provider)
    case 429:
        throw TranslationError.rateLimited(provider)
    default:
        throw TranslationError.cloudError(provider, "HTTP \(httpResponse.statusCode)")
    }

    var answer = ""
    let decoder = JSONDecoder()
    for try await rawLine in bytes.lines {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix(":") { continue }
        guard line.hasPrefix("data:") else { continue }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { break }
        guard let data = payload.data(using: .utf8),
              let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: data)
        else { continue }
        if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
            answer += delta
            onPartial(answer)
        }
        if chunk.choices.first?.finishReason != nil { break }
    }

    let parsed = AskNugumiResponse.parse(answer)
    guard !parsed.message.isEmpty else {
        throw TranslationError.emptyResponse
    }
    return parsed
}
```

- [ ] **Step 5: Build**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Add Ask Nugumi vision backend call"
```

## Task 4: Prompt Controller

**Files:**
- Modify: `Sources/Nugumi/App.swift`
- Test: manual app verification

- [ ] **Step 1: Add `AskPromptController`**

In `Sources/Nugumi/App.swift`, near `FloatingTranslateButtonController`, add a compact controller:

```swift
@MainActor
final class AskPromptController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static let panelSize = NSSize(width: 360, height: 52)
    private static let edgeMargin: CGFloat = 12

    private let panel: NSPanel
    private let textField: NSTextField
    private let onSubmit: (String) -> Void
    private let onClose: () -> Void
    private var didClose = false

    var isVisible: Bool { panel.isVisible }

    init(
        near screenPoint: NSPoint,
        onSubmit: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onClose = onClose

        let origin = Self.origin(near: screenPoint, size: Self.panelSize)
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true

        textField = NSTextField(frame: NSRect(x: 14, y: 11, width: Self.panelSize.width - 28, height: 30))
        textField.placeholderString = "Ask about this screen..."
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .none
        textField.font = NSFont.systemFont(ofSize: 14)
        root.addSubview(textField)

        panel.contentView = root

        super.init()
        panel.delegate = self
        textField.delegate = self
    }

    func show() {
        panel.orderFrontRegardless()
        panel.makeFirstResponder(textField)
    }

    func setLoading() {
        textField.isEnabled = false
        textField.placeholderString = "Looking..."
    }

    func showError(_ message: String) {
        textField.isEnabled = true
        textField.stringValue = ""
        textField.placeholderString = message
        panel.makeFirstResponder(textField)
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        panel.close()
        onClose()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let movement = notification.userInfo?["NSTextMovement"] as? Int else {
            return
        }
        if movement == NSReturnTextMovement {
            submit()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.close()
        }
    }

    private func submit() {
        let prompt = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            panel.makeFirstResponder(textField)
            return
        }
        onSubmit(prompt)
    }

    private static func origin(near point: NSPoint, size: NSSize) -> NSPoint {
        let visibleFrame = NSScreen.visibleFrame(containing: point)
        var origin = NSPoint(x: point.x + 12, y: point.y - size.height - 10)
        origin.x = min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin)
        origin.y = min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
        return origin
    }
}
```

- [ ] **Step 2: Build**

Run:

```bash
swift build
```

Expected: build succeeds. If `cancelOperation` is not called by the field, add a small `AskPromptTextField` subclass that overrides `cancelOperation(_:)` and calls a closure.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Add Ask Nugumi prompt controller"
```

## Task 5: Double-Control Detector

**Files:**
- Modify: `Sources/Nugumi/GlobalShortcuts.swift`
- Modify: `Sources/Nugumi/App.swift`
- Test: manual app verification

- [ ] **Step 1: Add detector to `GlobalShortcuts.swift`**

Add below `GlobalHotKey` or near other shortcut helpers:

```swift
@MainActor
final class DoubleControlPressDetector {
    private let interval: TimeInterval
    private let onDetected: @MainActor () -> Void
    private var monitor: Any?
    private var lastControlDownDate: Date?
    private var wasControlDown = false
    var isEnabled = true

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
```

- [ ] **Step 2: Wire detector property in `NugumiApp`**

In `NugumiApp`, add a property:

```swift
private var doubleControlDetector: DoubleControlPressDetector?
```

In `applicationDidFinishLaunching`, after `setupGlobalHotKeys()`:

```swift
setupDoubleControlDetector()
```

Add method:

```swift
private func setupDoubleControlDetector() {
    let detector = DoubleControlPressDetector { [weak self] in
        self?.startAskNugumiPrompt()
    }
    doubleControlDetector = detector
    detector.start()
}
```

In `recordKeyboardShortcut(_:)`, immediately after the `guard` block and before `shortcutRecorderWindowController?.close()`:

```swift
doubleControlDetector?.isEnabled = false
```

In the shortcut recorder close callback, restore:

```swift
self?.doubleControlDetector?.isEnabled = true
```

- [ ] **Step 3: Add temporary stub for `startAskNugumiPrompt()`**

In `NugumiApp`, add:

```swift
@MainActor
private func startAskNugumiPrompt() {
    NSLog("Nugumi: Ask prompt requested")
}
```

This stub is replaced in Task 7.

- [ ] **Step 4: Build**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 5: Manual smoke check**

Run:

```bash
swift run Nugumi
```

Expected: app launches. Double-Control should log `Nugumi: Ask prompt requested` to the terminal. Shortcut recorder should not trigger Ask Nugumi while recording a shortcut.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/GlobalShortcuts.swift Sources/Nugumi/App.swift
git commit -m "Detect double Control for Ask Nugumi"
```

## Task 6: Pet Pointing Animation

**Files:**
- Modify: `Sources/Nugumi/App.swift`
- Test: manual app verification

- [ ] **Step 1: Add pointing state to `PetController`**

In `PetController`, add properties:

```swift
private var pointingTarget: NSPoint?
private var pointingReturnTimer: Timer?
private var isPointing: Bool { pointingTarget != nil }
```

- [ ] **Step 2: Add public pointing method**

Inside `PetController`, add:

```swift
func pointTemporarily(at destination: NSPoint, holdDuration: TimeInterval = 3.0) {
    pointingReturnTimer?.invalidate()
    pointingTarget = destination
    selectedText = nil
    onTranslate = nil
    onRewrite = nil
    onSmartReply = nil
    isReadyLockedUntilPanelCloses = false
    isThinking = false
    panel.ignoresMouseEvents = true
    tabInterceptor?.disable()
    tabInterceptor = nil
    appIconView.isHidden = true
    petView.apply(state: .run, mode: currentMode)
    show()

    let timer = Timer(timeInterval: holdDuration, repeats: false) { [weak self] _ in
        Task { @MainActor [weak self] in
            self?.pointingTarget = nil
            self?.pointingReturnTimer = nil
            self?.refreshAppIcon()
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    pointingReturnTimer = timer
}
```

- [ ] **Step 3: Stop timers on close**

In `PetController.close()`, before `panel.close()`:

```swift
pointingReturnTimer?.invalidate()
pointingReturnTimer = nil
pointingTarget = nil
```

- [ ] **Step 4: Update tracking to animate toward target**

At the top of `updateTracking()` after `petView.advanceAnimationFrame()`:

```swift
if let pointingTarget {
    let targetOrigin = Self.originNearPoint(pointingTarget, size: Self.panelSize)
    let currentOrigin = panel.frame.origin
    let dx = targetOrigin.x - currentOrigin.x
    let dy = targetOrigin.y - currentOrigin.y
    let nextOrigin = NSPoint(
        x: currentOrigin.x + dx * 0.18,
        y: currentOrigin.y + dy * 0.18
    )
    panel.setFrameOrigin(nextOrigin)
    let distance = hypot(dx, dy)
    petView.apply(state: distance > 3 ? .run : .ready, mode: currentMode)
    return
}
```

Add helper near `originNearCursor`:

```swift
private static func originNearPoint(_ point: NSPoint, size: NSSize) -> NSPoint {
    let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
    origin.x = min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin)
    origin.y = min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
    return origin
}
```

- [ ] **Step 5: Build**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Add temporary pet pointing animation"
```

## Task 7: Wire Ask Nugumi End-To-End

**Files:**
- Modify: `Sources/Nugumi/App.swift`
- Test: manual app verification with a vision model

- [ ] **Step 1: Add app state properties**

In `NugumiApp`, add:

```swift
private var askPromptController: AskPromptController?
private var isAskNugumiRunning = false
```

- [ ] **Step 2: Replace `startAskNugumiPrompt()` stub**

Replace the Task 5 stub with:

```swift
@MainActor
private func startAskNugumiPrompt() {
    guard !isAskNugumiRunning else { return }
    guard askPromptController?.isVisible != true else { return }

    translateButtonController?.close()
    translateButtonController = nil
    translationPanelController?.close()
    translationPanelController = nil
    cancelPrefetch()

    let controller = AskPromptController(
        near: NSEvent.mouseLocation,
        onSubmit: { [weak self] prompt in
            self?.submitAskNugumiPrompt(prompt)
        },
        onClose: { [weak self] in
            self?.askPromptController = nil
        }
    )
    askPromptController = controller
    controller.show()
}
```

- [ ] **Step 3: Add submit method**

In `NugumiApp`, add:

```swift
@MainActor
private func submitAskNugumiPrompt(_ prompt: String) {
    let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanPrompt.isEmpty else { return }

    if let setupError = translationErrorIfBootstrapNeedsSetup() {
        askPromptController?.showError(translationFailureMessage(for: setupError))
        return
    }

    guard LLMModel.option(id: selectedModelID).supportsImages else {
        askPromptController?.showError("Ask Nugumi needs a vision model.")
        return
    }

    isAskNugumiRunning = true
    askPromptController?.setLoading()
    petController?.showThinking()

    let cursorLocation = NSEvent.mouseLocation
    let backend = currentBackend
    Task { [weak self] in
        do {
            let capture = try await ScreenshotCapture.captureActiveScreen(containing: cursorLocation)
            let response = try await backend.ask(
                prompt: cleanPrompt,
                image: capture.image
            ) { _ in }
            await MainActor.run {
                self?.presentAskNugumiResult(response, capture: capture, prompt: cleanPrompt)
            }
        } catch {
            await MainActor.run {
                guard let self else { return }
                self.isAskNugumiRunning = false
                self.petController?.clearThinking()
                let routed = self.handleTranslationFailure(error)
                if !routed {
                    self.askPromptController?.showError(error.localizedDescription)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Add result presentation**

In `NugumiApp`, add:

```swift
@MainActor
private func presentAskNugumiResult(
    _ response: AskNugumiResponse,
    capture: AskNugumiScreenCapture,
    prompt: String
) {
    isAskNugumiRunning = false
    petController?.clearThinking()
    askPromptController?.close()
    askPromptController = nil

    let mouseLocation = NSEvent.mouseLocation
    let controller = TranslationPanelController(
        anchor: .point(mouseLocation, panelSide: .right),
        sourceText: prompt,
        targetLanguage: targetLanguage,
        resultLabel: "Answer"
    ) { [weak self] in
        self?.translationPanelController = nil
        self?.petController?.clearReady()
    }
    translationPanelController?.close()
    translationPanelController = controller
    let requestID = controller.showLoading(targetLanguage: targetLanguage)
    controller.showTranslation(response.message, requestID: requestID)

    if let target = response.petTarget {
        let point = AskNugumiCoordinateMapper.screenPoint(
            for: target,
            screenFrame: capture.screenFrame,
            visibleFrame: capture.visibleFrame
        )
        if petController == nil {
            petController = PetController(initialMode: .selection)
        }
        petController?.pointTemporarily(at: NSPoint(x: point.x, y: point.y))
    }
}
```

- [ ] **Step 5: Build**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nugumi/App.swift
git commit -m "Wire Ask Nugumi prompt flow"
```

## Task 8: Verification And Polish

**Files:**
- Modify only files required by compile or manual verification findings.
- Test: `swift test`, `swift build`, `swift run Nugumi`

- [ ] **Step 1: Run unit tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 2: Build app**

Run:

```bash
swift build
```

Expected: build succeeds without warnings that indicate unreachable Ask Nugumi code.

- [ ] **Step 3: Manual verify prompt behavior**

Run:

```bash
swift run Nugumi
```

Verify:

- Double-Control opens the prompt near the cursor.
- Prompt clamps near screen edges.
- Escape closes the prompt.
- Empty Enter keeps the prompt open.
- Enter with text moves to loading state.
- Opening keyboard shortcut recorder disables double-Control detection.

- [ ] **Step 4: Manual verify screenshot and model behavior**

With a vision-capable model selected and API key configured, ask:

```text
Where is the button I should press to save this?
```

Verify:

- Nugumi sends screenshot image input.
- Answer panel shows a useful message.
- If the model returns `petTarget`, pet moves to the target, pauses, and returns.
- If the model returns no `petTarget`, answer appears and pet does not move.

- [ ] **Step 5: Manual verify error paths**

Verify:

- Text-only Ollama model shows `Ask Nugumi needs a vision model.`
- Missing Screen Recording permission routes to existing permission UX.
- Invalid API key routes to existing API-key/onboarding UX.
- Network failure shows a concise error in the prompt/result UI.

- [ ] **Step 6: Multi-display check**

On a secondary display or simulated non-origin screen frame, verify:

- Prompt opens on the display containing the cursor.
- Captured screen matches the display containing the cursor.
- Pet target conversion lands on the correct display.

- [ ] **Step 7: Final status and commit any verification fixes**

Run:

```bash
git status --short
```

If fixes were needed:

```bash
git add Sources/Nugumi/App.swift Sources/Nugumi/GlobalShortcuts.swift Sources/Nugumi/AskNugumi.swift Tests/NugumiTests/AskNugumiTests.swift
git commit -m "Polish Ask Nugumi verification paths"
```

Expected final state after implementation: no uncommitted Ask Nugumi changes. Existing unrelated working-tree changes may remain only if they predated this plan execution and were intentionally left untouched.

## Self-Review Checklist

- Spec coverage: double-Control prompt, prompt+screenshot LLM input, structured JSON, normalized coordinate mapping, pet move/pause/return, and graceful failure paths all have tasks.
- Placeholder scan: no task uses reserved placeholder markers or fill-in instructions.
- Type consistency: `AskNugumiResponse`, `AskNugumiPetTarget`, `AskNugumiCoordinateMapper`, `AskPromptController`, `DoubleControlPressDetector`, `AskNugumiScreenCapture`, and backend `ask(...)` signatures are used consistently across tasks.
- Verification coverage: unit tests cover parser and coordinate mapping; manual verification covers AppKit UI, permissions, model calls, pet animation, and multi-display behavior.
