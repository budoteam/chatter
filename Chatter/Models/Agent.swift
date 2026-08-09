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
    /// Additional models offered in the chat composer for quick switching.
    /// The primary model stays `modelId`.
    var alternateModelIds: [String] = []
    var temperature: Double = 0.7
    var iconSymbol: String = "sparkles"
    var colorHex: String = "6C5CE7"
    /// IDs of the `MCPServerConfig`s this agent is allowed to use.
    var mcpServerIDs: [UUID] = []
    /// IDs of the `KnowledgeBundle`s this agent can consult.
    var knowledgeBundleIDs: [UUID] = []
    /// IDs of the global `Skill`s this agent has enabled.
    var skillIDs: [UUID] = []
    /// Whether this agent keeps a persistent memory (prompt injection + the
    /// memory__save/update/delete tools).
    var memoryEnabled: Bool = false
    /// Whether this agent may create/update skills in the shared pool.
    var skillAuthoringEnabled: Bool = false
    /// Whether the built-in web research tools (search & fetch) are offered.
    var webAccessEnabled: Bool = true
    /// Raw `ThinkingMode` — how the model's reasoning mode is requested.
    var thinkingModeRaw: String = ""
    var createdAt: Date = Date()
    var isDefault: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \ChatSession.agent)
    var sessions: [ChatSession]? = []

    init(
        name: String = "New Agent",
        systemPrompt: String = "",
        modelId: String = "",
        alternateModelIds: [String] = [],
        temperature: Double = 0.7,
        iconSymbol: String = "sparkles",
        colorHex: String = "6C5CE7",
        mcpServerIDs: [UUID] = [],
        knowledgeBundleIDs: [UUID] = [],
        skillIDs: [UUID] = [],
        memoryEnabled: Bool = false,
        skillAuthoringEnabled: Bool = false,
        webAccessEnabled: Bool = true,
        isDefault: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.systemPrompt = systemPrompt
        self.modelId = modelId
        self.alternateModelIds = alternateModelIds
        self.temperature = temperature
        self.iconSymbol = iconSymbol
        self.colorHex = colorHex
        self.mcpServerIDs = mcpServerIDs
        self.knowledgeBundleIDs = knowledgeBundleIDs
        self.skillIDs = skillIDs
        self.memoryEnabled = memoryEnabled
        self.skillAuthoringEnabled = skillAuthoringEnabled
        self.webAccessEnabled = webAccessEnabled
        self.createdAt = Date()
        self.isDefault = isDefault
    }

    var color: Color { Color(hex: colorHex) }

    /// Primary model first, then alternates — what the composer offers.
    var allModelIds: [String] {
        var seen = Set<String>()
        return ([modelId] + alternateModelIds).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var thinkingMode: ThinkingMode {
        get { ThinkingMode(rawValue: thinkingModeRaw) ?? .standard }
        set { thinkingModeRaw = newValue.rawValue }
    }
}

/// How reasoning ("thinking") is requested from the model. `.standard` sends
/// nothing and lets the model use its default; on/off are booleans; the levels
/// are for models like gpt-oss that require an effort level instead.
enum ThinkingMode: String, CaseIterable, Identifiable {
    case standard = ""
    case off
    case on
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Default (model decides)"
        case .off: return "Off"
        case .on: return "On"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// The `think` value sent to Ollama (nil = let the model decide).
    var ollamaValue: OllamaThinkValue? {
        switch self {
        case .standard: return nil
        case .off: return .enabled(false)
        case .on: return .enabled(true)
        case .low, .medium, .high: return .level(rawValue)
        }
    }
}
