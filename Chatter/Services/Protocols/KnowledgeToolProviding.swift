import Foundation
import SwiftData

/// Abstraction over the built-in knowledge tools so `ChatEngine` can be
/// tested against a mock. Mirrors exactly the three `KnowledgeToolProvider`
/// entry points the engine uses; the conformance below is declared here so
/// the provider itself stays untouched.
@MainActor
protocol KnowledgeToolProviding {
    /// Tool schemas for the agent's assigned bundles (empty when none resolve).
    func tools(bundleIDs: [UUID], context: ModelContext) -> [OllamaTool]

    /// Run one of the offered knowledge tools; returns the textual result.
    func call(
        namespacedName: String,
        argumentsJSON: String,
        bundleIDs: [UUID],
        context: ModelContext
    ) throws -> String

    /// The knowledge overview injected into the system prompt (nil when the
    /// agent has no resolvable bundles).
    func systemPromptSection(bundleIDs: [UUID], context: ModelContext) -> String?
}

extension KnowledgeToolProvider: KnowledgeToolProviding {}
