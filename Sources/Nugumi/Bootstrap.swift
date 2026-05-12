import AppKit
import Foundation

enum BootstrapStepStatus: Equatable {
    case unknown
    case checking
    case ok
    case needsAction(String)
    case working(String)
    case failed(String)

    var isTerminalOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

struct BootstrapState: Equatable {
    var ollamaInstalled: BootstrapStepStatus = .unknown
    var serverRunning: BootstrapStepStatus = .unknown
    var ollamaSignedIn: BootstrapStepStatus = .unknown
    var modelReady: [String: BootstrapStepStatus] = [:]

    func modelReady(for modelID: String) -> BootstrapStepStatus {
        modelReady[modelID] ?? .unknown
    }

    func isReady(for modelID: String, requiresAccount: Bool) -> Bool {
        guard ollamaInstalled.isTerminalOK, serverRunning.isTerminalOK else { return false }
        if requiresAccount, !ollamaSignedIn.isTerminalOK { return false }
        return modelReady(for: modelID).isTerminalOK
    }
}

@MainActor
final class OllamaBootstrap {
    let baseURL: URL
    let models: [OllamaModelOption]

    var requiresOllamaAccount: Bool {
        models.contains(where: { $0.isCloud })
    }

    private(set) var state = BootstrapState()
    var onChange: ((BootstrapState) -> Void)?

    private let downloadPageURL = URL(string: "https://ollama.com/download/mac")!
    private let knownBundleIDs = [
        "com.electron.ollama",
        "com.ollama.ollama",
        "ai.ollama.app",
        "ai.ollama.Ollama"
    ]

    private var refreshTask: Task<Void, Never>?
    private var pullTasks: [String: Task<Void, Never>] = [:]

    init(baseURL: URL, models: [OllamaModelOption]) {
        self.baseURL = baseURL
        self.models = models
    }

    func isReady(for modelID: String) -> Bool {
        let requiresAccount = models.first(where: { $0.id == modelID })?.isCloud ?? false
        return state.isReady(for: modelID, requiresAccount: requiresAccount)
    }

    // MARK: - Public actions

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.runRefresh()
        }
    }

    func openInstallPage() {
        NSWorkspace.shared.open(downloadPageURL)
    }

    func revealOllamaApp() {
        if let url = ollamaAppURL() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(downloadPageURL)
        }
    }

    func launchOllamaApp() {
        guard let url = ollamaAppURL() else {
            NSWorkspace.shared.open(downloadPageURL)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.refresh()
            }
        }
    }

    func openOllamaForSignIn() {
        launchOllamaApp()
    }

    func startModelPull(for modelID: String) {
        guard pullTasks[modelID] == nil else { return }
        guard let model = models.first(where: { $0.id == modelID }) else { return }
        if model.isCloud {
            update(\.ollamaSignedIn, .working("Checking sign-in…"))
        }
        setModelReady(modelID, .working(model.isCloud
            ? "Setting up the translator…"
            : "Downloading translator (this can take several minutes)…"))
        pullTasks[modelID] = Task { [weak self] in
            await self?.runPull(for: model)
            await MainActor.run { self?.pullTasks[modelID] = nil }
        }
    }

    func cancelPull(for modelID: String) {
        pullTasks[modelID]?.cancel()
        pullTasks[modelID] = nil
    }

    func cancelAllPulls() {
        for (_, task) in pullTasks {
            task.cancel()
        }
        pullTasks.removeAll()
    }

    // MARK: - Detection

    private func runRefresh() async {
        update(\.ollamaInstalled, .checking)
        update(\.serverRunning, .checking)
        update(\.ollamaSignedIn, .checking)
        for model in models {
            // Don't clobber an in-flight pull's progress text.
            if pullTasks[model.id] == nil {
                setModelReady(model.id, .checking)
            }
        }

        let appPresent = ollamaAppURL() != nil
        let serverAlive = await pingServer()

        // A live server on localhost:11434 is sufficient evidence that Ollama
        // is installed — covers Homebrew and other non-.app installs.
        if appPresent || serverAlive {
            update(\.ollamaInstalled, .ok)
        } else {
            update(\.ollamaInstalled, .needsAction("Ollama isn't installed yet."))
            update(\.serverRunning, .needsAction("Install Ollama first."))
            update(\.ollamaSignedIn, .needsAction("Install Ollama first."))
            for model in models {
                if pullTasks[model.id] == nil {
                    setModelReady(model.id, .needsAction("Install Ollama first."))
                }
            }
            return
        }

        if serverAlive {
            update(\.serverRunning, .ok)
        } else {
            update(\.serverRunning, .needsAction("Ollama isn't running. Open it to start."))
            update(\.ollamaSignedIn, .needsAction("Start Ollama first."))
            for model in models {
                if pullTasks[model.id] == nil {
                    setModelReady(model.id, .needsAction("Start Ollama first."))
                }
            }
            return
        }

        let presentIDs: Set<String>
        do {
            presentIDs = try await modelsPresent()
        } catch {
            for model in models where pullTasks[model.id] == nil {
                setModelReady(model.id, .failed(error.localizedDescription))
            }
            return
        }

        let anyCloudPresent = models.contains { $0.isCloud && presentIDs.contains($0.id) }
        if anyCloudPresent {
            update(\.ollamaSignedIn, .ok)
        } else {
            update(\.ollamaSignedIn, requiresOllamaAccount
                ? .needsAction("Open Ollama and sign in (free).")
                : .ok)
        }

        for model in models where pullTasks[model.id] == nil {
            if presentIDs.contains(model.id) {
                setModelReady(model.id, .ok)
            } else {
                setModelReady(model.id, .needsAction(model.isCloud
                    ? "Free and instant. Needs internet to translate."
                    : "Free and private. Several GB download, then works without internet."))
            }
        }
    }

    private func pingServer() async -> Bool {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200..<500).contains(http.statusCode)
            }
            return true
        } catch {
            return false
        }
    }

    private func modelsPresent() async throws -> Set<String> {
        let url = baseURL.appending(path: "api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let payload = try JSONDecoder().decode(TagsResponse.self, from: data)
        var found: Set<String> = []
        for entry in payload.models {
            let candidates = [entry.name, entry.model].compactMap { $0 }
            for model in models where candidates.contains(model.id) {
                found.insert(model.id)
            }
        }
        return found
    }

    private func ollamaAppURL() -> URL? {
        let candidates = [
            "/Applications/Ollama.app",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications/Ollama.app")
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        for bundleID in knownBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }
        return nil
    }

    // MARK: - Pull streaming

    private func runPull(for model: OllamaModelOption) async {
        let modelID = model.id
        let url = baseURL.appending(path: "api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60 * 60

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelID, "stream": true])

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                setModelReady(modelID, .failed("Download failed: invalid response."))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                update(\.ollamaSignedIn, .needsAction("Open Ollama and sign in (free)."))
                setModelReady(modelID, .needsAction("Sign in to Ollama first, then tap Set up."))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                setModelReady(modelID, .failed("Download failed (HTTP \(http.statusCode))."))
                return
            }

            let decoder = JSONDecoder()
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }

                if let streamError = try? decoder.decode(StreamError.self, from: data),
                   let message = streamError.error {
                    let classified = OllamaClient.classifyStreamError(message: message, model: modelID)
                    if case .signInRequired = classified {
                        update(\.ollamaSignedIn, .needsAction("Open Ollama and sign in (free)."))
                        setModelReady(modelID, .needsAction("Sign in to Ollama first, then tap Set up."))
                    } else {
                        setModelReady(modelID, .failed(message))
                    }
                    return
                }

                if let progress = try? decoder.decode(PullProgress.self, from: data) {
                    let label = progress.humanReadableStatus()
                    setModelReady(modelID, .working(label))
                }
            }
            // Re-check tags to confirm.
            do {
                let presentIDs = try await modelsPresent()
                let present = presentIDs.contains(modelID)
                if present, model.isCloud {
                    update(\.ollamaSignedIn, .ok)
                }
                setModelReady(modelID, present
                    ? .ok
                    : .failed("Download finished but the translator isn't visible. Try Re-check."))
            } catch {
                setModelReady(modelID, .failed(error.localizedDescription))
            }
        } catch is CancellationError {
            setModelReady(modelID, .needsAction("Download cancelled."))
        } catch {
            setModelReady(modelID, .failed(error.localizedDescription))
        }
    }

    // MARK: - State plumbing

    private func update<V>(_ keyPath: WritableKeyPath<BootstrapState, V>, _ value: V) where V: Equatable {
        if state[keyPath: keyPath] == value { return }
        state[keyPath: keyPath] = value
        onChange?(state)
    }

    private func setModelReady(_ modelID: String, _ value: BootstrapStepStatus) {
        if state.modelReady[modelID] == value { return }
        state.modelReady[modelID] = value
        onChange?(state)
    }
}

private struct TagsResponse: Decodable {
    let models: [Entry]

    struct Entry: Decodable {
        let name: String?
        let model: String?
    }
}

private struct PullProgress: Decodable {
    let status: String?
    let total: Int64?
    let completed: Int64?

    func humanReadableStatus() -> String {
        let base = friendlyStatus(status)
        guard let total, total > 0, let completed else {
            return base
        }
        let percent = Int(Double(completed) / Double(total) * 100)
        return "\(base) \(percent)%"
    }

    private func friendlyStatus(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Downloading translator…" }
        let lower = raw.lowercased()
        if lower.contains("downloading") || lower.contains("pulling") {
            return "Downloading translator…"
        }
        if lower.contains("verifying") {
            return "Verifying download…"
        }
        if lower.contains("writing") || lower.contains("manifest") {
            return "Finishing setup…"
        }
        if lower.contains("success") {
            return "Ready."
        }
        return "Setting up the translator…"
    }
}

// MARK: - Onboarding window

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let bootstrap: OllamaBootstrap
    private let onClose: () -> Void
    private var installRow: StepRow?
    private var serverRow: StepRow?
    private var signInRow: StepRow?
    private var modelRows: [String: StepRow] = [:]

    init(bootstrap: OllamaBootstrap, onClose: @escaping () -> Void) {
        self.bootstrap = bootstrap
        self.onClose = onClose

        let modelCount = bootstrap.models.count
        // title + subtitle + 2 section headers + 3 ollama rows + footer
        let baseHeight: CGFloat = 420
        let perModelRow: CGFloat = 58
        let height = baseHeight + perModelRow * CGFloat(modelCount)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Nugumi Setup"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.center()

        super.init(window: window)
        window.delegate = self
        buildUI()
        bootstrap.onChange = { [weak self] state in
            self?.render(state: state)
        }
        render(state: bootstrap.state)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func presentAndRefresh() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        bootstrap.refresh()
    }

    private func buildUI() {
        guard let rootView = window?.contentView else { return }
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        let glass = GlassHostView(
            frame: rootView.bounds,
            cornerRadius: 18,
            tintColor: nil,
            style: .regular
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(glass)
        let contentView = glass.contentView

        let title = NSTextField(labelWithString: "Set up Nugumi")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString:
            "Nugumi translates whatever you select. To do that, it talks to Ollama — a small free app you'll install once. Two short sections below: get Ollama ready, then pick how Nugumi translates.")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let ollamaSectionHeader = Self.makeSectionHeader("1. Get Ollama ready (one time)")
        let translatorSectionHeader = Self.makeSectionHeader("2. Pick a translator (Online alone is enough)")

        let installRow = StepRow(
            title: "Install Ollama",
            primaryActionTitle: "Open download page"
        ) { [weak self] in
            self?.bootstrap.openInstallPage()
        }
        installRow.secondaryAction = { [weak self] in
            self?.bootstrap.refresh()
        }
        installRow.secondaryActionTitle = "Re-check"
        self.installRow = installRow

        let serverRow = StepRow(
            title: "Start Ollama",
            primaryActionTitle: "Open Ollama"
        ) { [weak self] in
            self?.bootstrap.launchOllamaApp()
        }
        self.serverRow = serverRow

        let signInRow = StepRow(
            title: "Sign in to Ollama (free)",
            primaryActionTitle: "Open Ollama"
        ) { [weak self] in
            self?.bootstrap.openOllamaForSignIn()
        }
        signInRow.secondaryAction = { [weak self] in
            self?.bootstrap.refresh()
        }
        signInRow.secondaryActionTitle = "Re-check"
        self.signInRow = signInRow

        var perModelRows: [StepRow] = []
        for model in bootstrap.models {
            let row = StepRow(
                title: Self.translatorRowTitle(for: model),
                primaryActionTitle: "Set up"
            ) { [weak self] in
                self?.bootstrap.startModelPull(for: model.id)
            }
            row.secondaryActionTitle = "Sign in"
            row.secondaryAction = { [weak self] in
                self?.bootstrap.openOllamaForSignIn()
            }
            modelRows[model.id] = row
            perModelRows.append(row)
        }

        let footerNote = NSTextField(wrappingLabelWithString:
            "Online is enough to start. You can add Offline or switch between the two anytime from the Nugumi menu.")
        footerNote.font = NSFont.systemFont(ofSize: 11)
        footerNote.textColor = .tertiaryLabelColor
        footerNote.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(title)
        contentView.addSubview(subtitle)
        contentView.addSubview(ollamaSectionHeader)
        contentView.addSubview(installRow)
        contentView.addSubview(serverRow)
        contentView.addSubview(signInRow)
        contentView.addSubview(translatorSectionHeader)
        for row in perModelRows {
            contentView.addSubview(row)
        }
        contentView.addSubview(footerNote)

        let leading: CGFloat = 24
        let trailing: CGFloat = -24
        let rowSpacing: CGFloat = 14
        let sectionGap: CGFloat = 22

        var constraints: [NSLayoutConstraint] = [
            glass.topAnchor.constraint(equalTo: rootView.topAnchor),
            glass.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 62),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: trailing),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            ollamaSectionHeader.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: sectionGap),
            ollamaSectionHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            ollamaSectionHeader.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: trailing),

            installRow.topAnchor.constraint(equalTo: ollamaSectionHeader.bottomAnchor, constant: 10),
            installRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            installRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: trailing),

            serverRow.topAnchor.constraint(equalTo: installRow.bottomAnchor, constant: rowSpacing),
            serverRow.leadingAnchor.constraint(equalTo: installRow.leadingAnchor),
            serverRow.trailingAnchor.constraint(equalTo: installRow.trailingAnchor),

            signInRow.topAnchor.constraint(equalTo: serverRow.bottomAnchor, constant: rowSpacing),
            signInRow.leadingAnchor.constraint(equalTo: installRow.leadingAnchor),
            signInRow.trailingAnchor.constraint(equalTo: installRow.trailingAnchor),

            translatorSectionHeader.topAnchor.constraint(equalTo: signInRow.bottomAnchor, constant: sectionGap),
            translatorSectionHeader.leadingAnchor.constraint(equalTo: installRow.leadingAnchor),
            translatorSectionHeader.trailingAnchor.constraint(equalTo: installRow.trailingAnchor)
        ]

        var previousBottomAnchor = translatorSectionHeader.bottomAnchor
        var firstTranslatorRow = true
        for row in perModelRows {
            constraints.append(contentsOf: [
                row.topAnchor.constraint(equalTo: previousBottomAnchor, constant: firstTranslatorRow ? 10 : rowSpacing),
                row.leadingAnchor.constraint(equalTo: installRow.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: installRow.trailingAnchor)
            ])
            previousBottomAnchor = row.bottomAnchor
            firstTranslatorRow = false
        }

        constraints.append(contentsOf: [
            footerNote.topAnchor.constraint(greaterThanOrEqualTo: previousBottomAnchor, constant: 16),
            footerNote.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            footerNote.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: trailing),
            footerNote.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        NSLayoutConstraint.activate(constraints)
    }

    private static func makeSectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private static func translatorRowTitle(for model: OllamaModelOption) -> String {
        model.isCloud ? "Online translator" : "Offline translator (optional)"
    }

    private func render(state: BootstrapState) {
        installRow?.apply(state.ollamaInstalled)
        serverRow?.apply(state.serverRunning)
        if !bootstrap.requiresOllamaAccount, case .ok = state.ollamaSignedIn {
            signInRow?.applyOk(message: "Not needed if you only use Offline.")
        } else if case .ok = state.ollamaSignedIn {
            signInRow?.applyOk(message: "Signed in to your free Ollama account.")
        } else {
            signInRow?.apply(state.ollamaSignedIn)
        }
        for model in bootstrap.models {
            let status = state.modelReady(for: model.id)
            if case .ok = status {
                modelRows[model.id]?.applyOk(message: model.isCloud
                    ? "Quick translations through Ollama Cloud."
                    : "Lives on your Mac. Private, works without internet.")
            } else {
                modelRows[model.id]?.apply(status)
            }
        }
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.onClose()
        }
    }
}

@MainActor
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private var accessibilityRow: StepRow!
    private var screenRecordingRow: StepRow!
    private var pollTimer: Timer?

    private static let accessibilityCopy = "Translate the text you select in any app."
    private static let screenRecordingCopy = "Translate text in screen areas you capture."

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Nugumi"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.center()

        super.init(window: window)
        window.delegate = self
        buildUI()
        refreshState()
        startPolling()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func presentAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func buildUI() {
        guard let rootView = window?.contentView else { return }
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        let glass = GlassHostView(
            frame: rootView.bounds,
            cornerRadius: 18,
            tintColor: nil,
            style: .regular
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(glass)
        let contentView = glass.contentView

        let title = NSTextField(labelWithString: "Welcome to Nugumi")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString:
            "Two quick permissions to start translating selected text and screen areas. Nugumi only sees what you actively highlight or capture — nothing else, nothing in the background.")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let accessibilityRow = StepRow(
            title: "Accessibility",
            primaryActionTitle: "Open settings"
        ) { [weak self] in
            self?.openAccessibilitySettings()
        }
        self.accessibilityRow = accessibilityRow

        let screenRecordingRow = StepRow(
            title: "Screen recording",
            primaryActionTitle: "Open settings"
        ) { [weak self] in
            self?.openScreenRecordingSettings()
        }
        self.screenRecordingRow = screenRecordingRow

        let footerNote = NSTextField(wrappingLabelWithString:
            "Skip for now — you can grant these later from the Nugumi menu.")
        footerNote.font = NSFont.systemFont(ofSize: 11)
        footerNote.textColor = .tertiaryLabelColor
        footerNote.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(title)
        contentView.addSubview(subtitle)
        contentView.addSubview(accessibilityRow)
        contentView.addSubview(screenRecordingRow)
        contentView.addSubview(footerNote)

        let leading: CGFloat = 24
        let trailing: CGFloat = -24
        let rowSpacing: CGFloat = 20

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: rootView.topAnchor),
            glass.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 62),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: trailing),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            accessibilityRow.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 22),
            accessibilityRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            accessibilityRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: trailing),

            screenRecordingRow.topAnchor.constraint(equalTo: accessibilityRow.bottomAnchor, constant: rowSpacing),
            screenRecordingRow.leadingAnchor.constraint(equalTo: accessibilityRow.leadingAnchor),
            screenRecordingRow.trailingAnchor.constraint(equalTo: accessibilityRow.trailingAnchor),

            footerNote.topAnchor.constraint(greaterThanOrEqualTo: screenRecordingRow.bottomAnchor, constant: 18),
            footerNote.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            footerNote.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: trailing),
            footerNote.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState()
            }
        }
    }

    private func refreshState() {
        let axTrusted = AXIsProcessTrusted()
        let scrTrusted = CGPreflightScreenCaptureAccess()

        if axTrusted {
            accessibilityRow.applyOk(message: "Granted.")
        } else {
            accessibilityRow.apply(.needsAction(Self.accessibilityCopy))
        }

        if scrTrusted {
            screenRecordingRow.applyOk(message: "Granted — relaunch Nugumi to activate.")
        } else {
            screenRecordingRow.apply(.needsAction(Self.screenRecordingCopy))
        }

        if axTrusted && scrTrusted {
            close()
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        closeBeforeOpeningSystemPermissionUI()
        NSWorkspace.shared.open(url)
    }

    private func openScreenRecordingSettings() {
        // First click registers Nugumi in TCC so it appears in the Screen
        // Recording list. Apple's stock dialog is unavoidable, but Nugumi's
        // own permissions window must be gone before that modal appears.
        let needsSystemPrompt = !CGPreflightScreenCaptureAccess()
        closeBeforeOpeningSystemPermissionUI()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if needsSystemPrompt {
                _ = CGRequestScreenCaptureAccess()
            } else {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func closeBeforeOpeningSystemPermissionUI() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.orderOut(nil)
        close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            self.onClose()
        }
    }
}

@MainActor
private final class StepRow: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIndicator = NSImageView()
    private let progressIndicator = NSProgressIndicator()
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)

    var primaryAction: (() -> Void)?
    var secondaryAction: (() -> Void)?
    var secondaryActionTitle: String? {
        didSet {
            secondaryButton.title = secondaryActionTitle ?? ""
        }
    }

    init(title: String, primaryActionTitle: String, primaryAction: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        self.primaryAction = primaryAction

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.stringValue = title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = 320

        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusIndicator.imageScaling = .scaleProportionallyUpOrDown

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isHidden = true

        primaryButton.title = primaryActionTitle
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .regular

        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryTapped)
        secondaryButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryButton.bezelStyle = .rounded
        secondaryButton.controlSize = .regular
        secondaryButton.isHidden = true

        addSubview(statusIndicator)
        addSubview(progressIndicator)
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(primaryButton)
        addSubview(secondaryButton)

        NSLayoutConstraint.activate([
            statusIndicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusIndicator.topAnchor.constraint(equalTo: titleLabel.topAnchor, constant: 1),
            statusIndicator.widthAnchor.constraint(equalToConstant: 18),
            statusIndicator.heightAnchor.constraint(equalToConstant: 18),

            progressIndicator.centerXAnchor.constraint(equalTo: statusIndicator.centerXAnchor),
            progressIndicator.centerYAnchor.constraint(equalTo: statusIndicator.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: statusIndicator.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: primaryButton.leadingAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: primaryButton.leadingAnchor, constant: -10),

            primaryButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            primaryButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            secondaryButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -8),
            secondaryButton.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor),

            heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyOk(message: String) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusIndicator.isHidden = false
        statusIndicator.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Ready")
        statusIndicator.contentTintColor = .systemGreen
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        primaryButton.isEnabled = false
        secondaryButton.isHidden = true
    }

    func apply(_ status: BootstrapStepStatus) {
        switch status {
        case .unknown, .checking:
            statusIndicator.isHidden = true
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            statusLabel.stringValue = "Checking…"
            statusLabel.textColor = .secondaryLabelColor
            primaryButton.isEnabled = false
            secondaryButton.isHidden = true
        case .ok:
            applyOk(message: "Ready.")
            return
        case .needsAction(let message):
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusIndicator.isHidden = false
            statusIndicator.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Needs action")
            statusIndicator.contentTintColor = .systemOrange
            statusLabel.stringValue = message
            statusLabel.textColor = .secondaryLabelColor
            primaryButton.isEnabled = true
            secondaryButton.isHidden = secondaryActionTitle == nil
                || !message.lowercased().contains("sign in")
        case .working(let message):
            statusIndicator.isHidden = true
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            statusLabel.stringValue = message
            statusLabel.textColor = .secondaryLabelColor
            primaryButton.isEnabled = false
            secondaryButton.isHidden = true
        case .failed(let message):
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusIndicator.isHidden = false
            statusIndicator.image = NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: "Failed")
            statusIndicator.contentTintColor = .systemRed
            statusLabel.stringValue = message
            statusLabel.textColor = .systemRed
            primaryButton.isEnabled = true
            secondaryButton.isHidden = secondaryActionTitle == nil
        }
    }

    @objc private func primaryTapped() {
        primaryAction?()
    }

    @objc private func secondaryTapped() {
        secondaryAction?()
    }
}
