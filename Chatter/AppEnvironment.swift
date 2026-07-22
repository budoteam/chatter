import Foundation
import SwiftData
import SwiftUI

/// Which screen the detail (main) column shows. `.chat` falls back to the
/// welcome view when no session is selected.
enum MainScreen {
    case chat
    case agents
    case knowledge
    case skills
}

/// Root observable object: owns the shared services and cross-view UI state
/// (current selection, cached model list, API-key presence).
@MainActor
@Observable
final class AppEnvironment {
    let ollama: OllamaServiceProtocol
    let mcp: MCPConnectionManager
    let knowledge: KnowledgeToolProvider
    let artifacts: ArtifactToolProvider
    let engine: ChatEngine
    /// Watches CloudKit sync events for the Settings status section.
    let sync = CloudSyncMonitor()

    var selectedSession: ChatSession?
    /// Which screen the detail column shows (chat / agents / knowledge).
    var mainScreen: MainScreen = .chat
    var models: [OllamaModel] = []
    var isLoadingModels = false
    var modelLoadError: String?
    var hasAPIKey: Bool = KeychainService.hasAPIKey
    /// Cached `/api/show` capabilities per model name (lowercased set).
    var modelCapabilities: [String: Set<String>] = [:]
    /// Text to pre-fill the composer of the next opened chat (welcome chips).
    var pendingPrompt: String?

    /// Artifact shown in the side panel (macOS) or sheet (iOS); set by
    /// tapping an artifact pill in the chat, cleared by closing the panel.
    var openArtifactID: PersistentIdentifier?

    /// Bumped by the macOS "New Chat" menu command; observed by `RootView`.
    private(set) var newSessionRequestID = UUID()

    /// Bumped on every explicit pick of a screen or chat; observed by
    /// `RootView` to surface the detail column on iPhone. A plain
    /// `onChange(of: mainScreen)` misses re-picking the still-active screen
    /// after popping back to the sidebar (value unchanged → no change event).
    private(set) var detailRequestID = UUID()

    /// Live assistant turns keyed by session id. Owned here (not by the chat
    /// view) because `ChatView` — and with it any view-local state — is
    /// recreated whenever the selection changes (`.id(session.id)`); the turn
    /// keeps running across that, and coming back must still show Stop and
    /// refuse a concurrent second send into the same session.
    private var activeTurns: [UUID: Task<Void, Never>] = [:]

    init() {
        let ollama = OllamaService()
        let mcp = MCPConnectionManager()
        let knowledge = KnowledgeToolProvider()
        let artifacts = ArtifactToolProvider()
        self.ollama = ollama
        self.mcp = mcp
        self.knowledge = knowledge
        self.artifacts = artifacts
        self.engine = ChatEngine(ollama: ollama, mcp: mcp, knowledge: knowledge, artifacts: artifacts)
        #if os(iOS) || os(watchOS)
        // iCloud Keychain doesn't reliably sync to watchOS; the watch pulls
        // the API key from the paired iPhone over WatchConnectivity instead.
        WatchKeySync.shared.activate()
        #if os(watchOS)
        WatchKeySync.shared.onKeyReceived = { [weak self] in
            self?.refreshAPIKeyState()
            Task { await self?.refreshModels() }
        }
        #endif
        #endif
    }

    func requestNewSession() { newSessionRequestID = UUID() }

    /// Switches the detail column to a screen (sidebar nav buttons).
    func showScreen(_ screen: MainScreen) {
        mainScreen = screen
        detailRequestID = UUID()
    }

    /// Selects a session and switches the detail column back to the chat view
    /// (used when starting/opening a chat from the Agents overview).
    func openChat(_ session: ChatSession) {
        selectedSession = session
        mainScreen = .chat
        detailRequestID = UUID()
    }

    // MARK: - Turn lifecycle

    func isSending(_ session: ChatSession) -> Bool {
        activeTurns[session.id] != nil
    }

    /// Runs one assistant turn for the session; no-op while one is running.
    func runTurn(for session: ChatSession, _ body: @escaping @MainActor () async -> Void) {
        let id = session.id
        guard activeTurns[id] == nil else { return }
        activeTurns[id] = Task { @MainActor in
            await body()
            activeTurns[id] = nil
        }
    }

    func stopTurn(for session: ChatSession) {
        activeTurns[session.id]?.cancel()
    }

    /// Cancels a running turn and waits for its teardown (final flush and
    /// saves) to finish — required before deleting the session, so the engine
    /// never mutates models that are already gone.
    func cancelTurnAndWait(for session: ChatSession) async {
        guard let task = activeTurns[session.id] else { return }
        task.cancel()
        await task.value
    }

    func refreshAPIKeyState() { hasAPIKey = KeychainService.hasAPIKey }

    /// Loads the model list from Ollama Cloud (best-effort).
    func refreshModels() async {
        guard hasAPIKey else {
            models = []
            modelLoadError = "Add your Ollama API key in Settings."
            return
        }
        isLoadingModels = true
        modelLoadError = nil
        defer { isLoadingModels = false }
        do {
            models = try await ollama.listModels()
        } catch {
            modelLoadError = error.localizedDescription
            AppLogger.api.error("listModels failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether `model` reports `capability` via `/api/show`. Best-effort and
    /// cached: on any failure it returns false so gated features stay off
    /// rather than sending requests a model would ignore.
    func supports(_ capability: String, model: String) async -> Bool {
        guard !model.isEmpty else { return false }
        if let cached = modelCapabilities[model] { return cached.contains(capability) }
        guard hasAPIKey else { return false }
        do {
            let caps = Set(try await ollama.modelCapabilities(model: model).map { $0.lowercased() })
            modelCapabilities[model] = caps
            return caps.contains(capability)
        } catch {
            AppLogger.api.error("modelCapabilities failed for \(model, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Whether `model` supports image input (gates the composer photo button).
    func supportsVision(_ model: String) async -> Bool {
        await supports("vision", model: model)
    }
}
