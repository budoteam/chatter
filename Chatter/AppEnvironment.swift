import Foundation
import SwiftUI

/// Root observable object: owns the shared services and cross-view UI state
/// (current selection, cached model list, API-key presence).
@MainActor
@Observable
final class AppEnvironment {
    let ollama: OllamaServiceProtocol
    let mcp: MCPConnectionManager
    let engine: ChatEngine

    var selectedSession: ChatSession?
    var models: [OllamaModel] = []
    var isLoadingModels = false
    var modelLoadError: String?
    var hasAPIKey: Bool = KeychainService.hasAPIKey
    /// Text to pre-fill the composer of the next opened chat (welcome chips).
    var pendingPrompt: String?

    /// Bumped by the macOS "New Chat" menu command; observed by `RootView`.
    private(set) var newSessionRequestID = UUID()

    init() {
        let ollama = OllamaService()
        let mcp = MCPConnectionManager()
        self.ollama = ollama
        self.mcp = mcp
        self.engine = ChatEngine(ollama: ollama, mcp: mcp)
    }

    func requestNewSession() { newSessionRequestID = UUID() }

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
}
