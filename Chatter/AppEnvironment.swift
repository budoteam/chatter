import Foundation
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
    let engine: ChatEngine

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

    /// Bumped by the macOS "New Chat" menu command; observed by `RootView`.
    private(set) var newSessionRequestID = UUID()

    init() {
        let ollama = OllamaService()
        let mcp = MCPConnectionManager()
        let knowledge = KnowledgeToolProvider()
        self.ollama = ollama
        self.mcp = mcp
        self.knowledge = knowledge
        self.engine = ChatEngine(ollama: ollama, mcp: mcp, knowledge: knowledge)
    }

    func requestNewSession() { newSessionRequestID = UUID() }

    /// Selects a session and switches the detail column back to the chat view
    /// (used when starting/opening a chat from the Agents overview).
    func openChat(_ session: ChatSession) {
        selectedSession = session
        mainScreen = .chat
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
