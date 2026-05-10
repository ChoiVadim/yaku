import AppKit
import Foundation

enum BootstrapStepID: String, CaseIterable {
    case ollamaInstalled
    case serverRunning
    case ollamaSignedIn
    case modelReady
}

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
    var modelReady: BootstrapStepStatus = .unknown

    var isReady: Bool {
        ollamaInstalled.isTerminalOK && serverRunning.isTerminalOK && ollamaSignedIn.isTerminalOK && modelReady.isTerminalOK
    }
}

@MainActor
final class OllamaBootstrap {
    let baseURL: URL
    let model: String
    let requiresOllamaAccount: Bool

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
    private var pullTask: Task<Void, Never>?

    init(baseURL: URL, model: String, requiresOllamaAccount: Bool) {
        self.baseURL = baseURL
        self.model = model
        self.requiresOllamaAccount = requiresOllamaAccount
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

    func startModelPull() {
        guard pullTask == nil else { return }
        if requiresOllamaAccount {
            update(\.ollamaSignedIn, .working("Checking sign-in…"))
        }
        update(\.modelReady, .working(requiresOllamaAccount
            ? "Setting up the translator…"
            : "Downloading translator (this can take several minutes)…"))
        pullTask = Task { [weak self] in
            await self?.runPull()
            await MainActor.run { self?.pullTask = nil }
        }
    }

    func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
    }

    // MARK: - Detection

    private func runRefresh() async {
        update(\.ollamaInstalled, .checking)
        update(\.serverRunning, .checking)
        update(\.ollamaSignedIn, .checking)
        update(\.modelReady, .checking)

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
            update(\.modelReady, .needsAction("Install Ollama first."))
            return
        }

        if serverAlive {
            update(\.serverRunning, .ok)
        } else {
            update(\.serverRunning, .needsAction("Ollama isn't running. Open it to start."))
            update(\.ollamaSignedIn, .needsAction("Start Ollama first."))
            update(\.modelReady, .needsAction("Start Ollama first."))
            return
        }

        do {
            let hasModel = try await modelIsPresent()
            if hasModel {
                update(\.ollamaSignedIn, .ok)
                update(\.modelReady, .ok)
            } else {
                update(\.ollamaSignedIn, requiresOllamaAccount
                    ? .needsAction("Open Ollama and sign in (free).")
                    : .ok)
                update(\.modelReady, .needsAction(requiresOllamaAccount
                    ? "Translator isn't set up yet."
                    : "Translator isn't downloaded yet (several GB)."))
            }
        } catch {
            update(\.modelReady, .failed(error.localizedDescription))
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

    private func modelIsPresent() async throws -> Bool {
        let url = baseURL.appending(path: "api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let payload = try JSONDecoder().decode(TagsResponse.self, from: data)
        return payload.models.contains { entry in
            entry.name == model || entry.model == model
        }
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

    private func runPull() async {
        let url = baseURL.appending(path: "api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60 * 60

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                update(\.modelReady, .failed("Download failed: invalid response."))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                update(\.ollamaSignedIn, .needsAction("Open Ollama and sign in (free)."))
                update(\.modelReady, .needsAction("Sign in is required for online mode."))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                update(\.modelReady, .failed("Download failed (HTTP \(http.statusCode))."))
                return
            }

            let decoder = JSONDecoder()
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }

                if let streamError = try? decoder.decode(StreamError.self, from: data),
                   let message = streamError.error {
                    let classified = OllamaClient.classifyStreamError(message: message, model: model)
                    if case .signInRequired = classified {
                        update(\.ollamaSignedIn, .needsAction("Open Ollama and sign in (free)."))
                        update(\.modelReady, .needsAction("Sign in is required for online mode."))
                    } else {
                        update(\.modelReady, .failed(message))
                    }
                    return
                }

                if let progress = try? decoder.decode(PullProgress.self, from: data) {
                    let label = progress.humanReadableStatus()
                    update(\.modelReady, .working(label))
                }
            }
            // Re-check tags to confirm
            do {
                let present = try await modelIsPresent()
                if present {
                    update(\.ollamaSignedIn, .ok)
                }
                update(\.modelReady, present ? .ok : .failed("Download finished but the translator isn't visible. Try Re-check."))
            } catch {
                update(\.modelReady, .failed(error.localizedDescription))
            }
        } catch is CancellationError {
            update(\.modelReady, .needsAction("Download cancelled."))
        } catch {
            update(\.modelReady, .failed(error.localizedDescription))
        }
    }

    // MARK: - State plumbing

    private func update<V>(_ keyPath: WritableKeyPath<BootstrapState, V>, _ value: V) where V: Equatable {
        if state[keyPath: keyPath] == value { return }
        state[keyPath: keyPath] = value
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
    private var stepRows: [BootstrapStepID: StepRow] = [:]

    init(bootstrap: OllamaBootstrap, onClose: @escaping () -> Void) {
        self.bootstrap = bootstrap
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 410),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Yaku Setup"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
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
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        let title = NSTextField(labelWithString: "Set up Yaku")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString:
            "Yaku translates the text you select. It runs through Ollama — a free helper app that lives on your Mac. Finish the quick steps below; Yaku checks each one for you.")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

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

        let serverRow = StepRow(
            title: "Start Ollama",
            primaryActionTitle: "Open Ollama"
        ) { [weak self] in
            self?.bootstrap.launchOllamaApp()
        }

        let signInRow = StepRow(
            title: "Sign in (online mode only)",
            primaryActionTitle: "Open Ollama"
        ) { [weak self] in
            self?.bootstrap.openOllamaForSignIn()
        }
        signInRow.secondaryAction = { [weak self] in
            self?.bootstrap.refresh()
        }
        signInRow.secondaryActionTitle = "Re-check"

        let modelRow = StepRow(
            title: "Set up the translator",
            primaryActionTitle: "Set up"
        ) { [weak self] in
            self?.bootstrap.startModelPull()
        }
        modelRow.secondaryActionTitle = "Sign in"
        modelRow.secondaryAction = { [weak self] in
            self?.bootstrap.openOllamaForSignIn()
        }

        stepRows[.ollamaInstalled] = installRow
        stepRows[.serverRunning] = serverRow
        stepRows[.ollamaSignedIn] = signInRow
        stepRows[.modelReady] = modelRow

        let footerNote = NSTextField(wrappingLabelWithString:
            "Online mode is fast and uses your free Ollama account. Offline mode keeps everything on your Mac — it downloads several GB and runs slower, especially on older Macs. You can switch modes anytime from the Yaku menu.")
        footerNote.font = NSFont.systemFont(ofSize: 11)
        footerNote.textColor = .tertiaryLabelColor
        footerNote.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(title)
        contentView.addSubview(subtitle)
        contentView.addSubview(installRow)
        contentView.addSubview(serverRow)
        contentView.addSubview(signInRow)
        contentView.addSubview(modelRow)
        contentView.addSubview(footerNote)

        let leading: CGFloat = 24
        let trailing: CGFloat = -24
        let rowSpacing: CGFloat = 16

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

            installRow.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            installRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            installRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: trailing),

            serverRow.topAnchor.constraint(equalTo: installRow.bottomAnchor, constant: rowSpacing),
            serverRow.leadingAnchor.constraint(equalTo: installRow.leadingAnchor),
            serverRow.trailingAnchor.constraint(equalTo: installRow.trailingAnchor),

            signInRow.topAnchor.constraint(equalTo: serverRow.bottomAnchor, constant: rowSpacing),
            signInRow.leadingAnchor.constraint(equalTo: installRow.leadingAnchor),
            signInRow.trailingAnchor.constraint(equalTo: installRow.trailingAnchor),

            modelRow.topAnchor.constraint(equalTo: signInRow.bottomAnchor, constant: rowSpacing),
            modelRow.leadingAnchor.constraint(equalTo: installRow.leadingAnchor),
            modelRow.trailingAnchor.constraint(equalTo: installRow.trailingAnchor),

            footerNote.topAnchor.constraint(greaterThanOrEqualTo: modelRow.bottomAnchor, constant: 18),
            footerNote.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            footerNote.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: trailing),
            footerNote.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    private func render(state: BootstrapState) {
        stepRows[.ollamaInstalled]?.apply(state.ollamaInstalled)
        stepRows[.serverRunning]?.apply(state.serverRunning)
        if !bootstrap.requiresOllamaAccount, case .ok = state.ollamaSignedIn {
            stepRows[.ollamaSignedIn]?.applyOk(message: "Not needed in offline mode.")
        } else {
            stepRows[.ollamaSignedIn]?.apply(state.ollamaSignedIn)
        }
        stepRows[.modelReady]?.apply(state.modelReady)
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
