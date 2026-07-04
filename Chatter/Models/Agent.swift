import Foundation
import SwiftData
import SwiftUI

/// A configurable assistant persona: its own model, system prompt, and the set
/// of MCP servers whose tools it may call.
@Model
final class Agent {
    var id: UUID = UUID()
    var name: String = "New Agent"
    var systemPrompt: String = ""
    /// Ollama model id, e.g. "qwen3-coder:480b-cloud".
    var modelId: String = ""
    var temperature: Double = 0.7
    var iconSymbol: String = "sparkles"
    var colorHex: String = "6C5CE7"
    /// IDs of the `MCPServerConfig`s this agent is allowed to use.
    var mcpServerIDs: [UUID] = []
    /// IDs of the `KnowledgeBundle`s this agent can consult.
    var knowledgeBundleIDs: [UUID] = []
    var createdAt: Date = Date()
    var isDefault: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \ChatSession.agent)
    var sessions: [ChatSession]? = []

    init(
        name: String = "New Agent",
        systemPrompt: String = "",
        modelId: String = "",
        temperature: Double = 0.7,
        iconSymbol: String = "sparkles",
        colorHex: String = "6C5CE7",
        mcpServerIDs: [UUID] = [],
        knowledgeBundleIDs: [UUID] = [],
        isDefault: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.systemPrompt = systemPrompt
        self.modelId = modelId
        self.temperature = temperature
        self.iconSymbol = iconSymbol
        self.colorHex = colorHex
        self.mcpServerIDs = mcpServerIDs
        self.knowledgeBundleIDs = knowledgeBundleIDs
        self.createdAt = Date()
        self.isDefault = isDefault
    }

    var color: Color { Color(hex: colorHex) }
}
