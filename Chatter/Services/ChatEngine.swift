import Foundation
import SwiftData

/// Drives a single assistant turn, including the MCP tool loop:
/// stream → if the model requested tools, run them and feed results back →
/// stream again, until the model answers or we hit the iteration cap.
@MainActor
final class ChatEngine {
    private let ollama: OllamaServiceProtocol
    private let mcp: MCPConnectionManager
    private let knowledge: KnowledgeToolProvider
    private let maxToolIterations = 6

    init(ollama: OllamaServiceProtocol, mcp: MCPConnectionManager, knowledge: KnowledgeToolProvider) {
        self.ollama = ollama
        self.mcp = mcp
        self.knowledge = knowledge
    }

    enum EngineError: LocalizedError {
        case noModel
        var errorDescription: String? {
            switch self {
            case .noModel: return "No model selected. Pick a model for this agent in its settings."
            }
        }
    }

    /// Appends the user's message, then runs the assistant turn(s).
    func send(text: String, session: ChatSession, agent: Agent?, context: ModelContext) async throws {
        let model = resolveModel(agent: agent, session: session)
        guard !model.isEmpty else { throw EngineError.noModel }
        session.modelId = model

        let userMsg = Message(role: .user, content: text, orderIndex: session.nextOrderIndex)
        userMsg.session = session
        context.insert(userMsg)
        session.updatedAt = .now
        try? context.save()

        // Tool schemas for this agent's allowed servers.
        let resolved = mcp.tools(forServerIDs: agent?.mcpServerIDs ?? [])
        var tools = resolved.map {
            OllamaTool(function: .init(
                name: $0.namespacedName,
                description: $0.toolDescription,
                parameters: $0.parameters
            ))
        }
        // Built-in knowledge tools for this agent's assigned bundles. Dispatch
        // below routes by the exact names offered here, so MCP tools that
        // happen to be namespaced "knowledge__…" (a server named "Knowledge")
        // are only shadowed when the built-ins are actually active.
        let knowledgeBundleIDs = agent?.knowledgeBundleIDs ?? []
        let knowledgeTools = knowledge.tools(bundleIDs: knowledgeBundleIDs, context: context)
        let knowledgeToolNames = Set(knowledgeTools.map(\.function.name))
        tools += knowledgeTools

        // The knowledge overview is stable within one send; compute it once
        // instead of per tool-loop iteration (it fetches and walks bundles).
        let knowledgeSection = knowledge.systemPromptSection(
            bundleIDs: knowledgeBundleIDs, context: context
        )

        var iteration = 0
        while iteration < maxToolIterations {
            iteration += 1

            // Build the request from the persisted history (system prompt first).
            // Rebuilt every iteration, so the timestamp stays current across
            // long tool loops.
            var msgs: [OllamaChatMessage] = [
                OllamaChatMessage(
                    role: "system",
                    content: Self.systemPrompt(for: agent, knowledgeSection: knowledgeSection)
                )
            ]
            msgs.append(contentsOf: session.orderedMessages.map(Self.toOllama))

            // Live assistant message the view streams into.
            let assistant = Message(
                role: .assistant, content: "",
                orderIndex: session.nextOrderIndex, isStreaming: true
            )
            assistant.session = session
            context.insert(assistant)

            var toolCalls: [OllamaToolCall] = []
            // Tokens are buffered and flushed at ~12 Hz: mutating the @Model
            // per token re-renders (and re-parses Markdown for) the whole
            // message on every delta, which stalls the main thread on long
            // answers (gesture-gate / pasteboard timeouts).
            var pendingContent = ""
            var pendingThinking = ""
            var lastFlush = ContinuousClock.now

            func flushPending(force: Bool = false) {
                let now = ContinuousClock.now
                guard force || now - lastFlush > .milliseconds(80) else { return }
                if !pendingContent.isEmpty {
                    assistant.content += pendingContent
                    pendingContent = ""
                }
                if !pendingThinking.isEmpty {
                    assistant.thinking = (assistant.thinking ?? "") + pendingThinking
                    pendingThinking = ""
                }
                lastFlush = now
            }

            do {
                for try await chunk in ollama.streamChat(
                    model: model, messages: msgs, tools: tools,
                    temperature: agent?.temperature ?? 0.7
                ) {
                    switch chunk {
                    case .delta(let piece): pendingContent += piece
                    case .thinking(let piece): pendingThinking += piece
                    case .toolCalls(let calls): toolCalls.append(contentsOf: calls)
                    case .done: break
                    }
                    flushPending()
                }
                flushPending(force: true)
            } catch is CancellationError {
                // User stopped — keep whatever streamed in, no error surface.
                flushPending(force: true)
                assistant.isStreaming = false
                session.updatedAt = .now
                try? context.save()
                return
            } catch {
                flushPending(force: true)
                assistant.isStreaming = false
                // Don't leave an empty bubble behind; the error is surfaced
                // via the view model's alert.
                if assistant.content.isEmpty {
                    context.delete(assistant)
                }
                try? context.save()
                throw error
            }
            assistant.isStreaming = false

            // No tools requested → this is the final answer.
            if toolCalls.isEmpty {
                maybeAutoTitle(session)
                session.updatedAt = .now
                try? context.save()
                return
            }

            // Persist the requested calls on the assistant turn, then run them.
            assistant.toolCalls = toolCalls.map {
                ToolCall(name: $0.function.name, argumentsJSON: $0.function.arguments.jsonString)
            }
            try? context.save()

            for call in toolCalls {
                let name = call.function.name
                let argsJSON = call.function.arguments.jsonString
                let result: String
                do {
                    if knowledgeToolNames.contains(name) {
                        result = try knowledge.call(
                            namespacedName: name, argumentsJSON: argsJSON,
                            bundleIDs: knowledgeBundleIDs, context: context
                        )
                    } else {
                        result = try await mcp.callTool(namespacedName: name, argumentsJSON: argsJSON)
                    }
                } catch {
                    result = "Tool error: \(error.localizedDescription)"
                }
                let toolMsg = Message(
                    role: .tool, content: result,
                    orderIndex: session.nextOrderIndex, toolName: name
                )
                toolMsg.session = session
                context.insert(toolMsg)
            }
            session.updatedAt = .now
            try? context.save()
            // Loop: model gets another turn with the tool results in history.
        }

        maybeAutoTitle(session)
        session.updatedAt = .now
        try? context.save()
    }

    // MARK: - Helpers

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    /// The agent's system prompt plus its knowledge-base overview, always
    /// ending with the current date & time.
    private static func systemPrompt(for agent: Agent?, knowledgeSection: String?) -> String {
        let timestamp = "Current Date and Time: \(timestampFormatter.string(from: Date()))"
        var parts: [String] = []
        let prompt = agent?.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prompt.isEmpty { parts.append(prompt) }
        if let knowledgeSection { parts.append(knowledgeSection) }
        parts.append(timestamp)
        return parts.joined(separator: "\n\n")
    }

    private func resolveModel(agent: Agent?, session: ChatSession) -> String {
        if let m = agent?.modelId, !m.isEmpty { return m }
        return session.modelId
    }

    private func maybeAutoTitle(_ session: ChatSession) {
        guard session.title == "New Chat" || session.title.isEmpty else { return }
        guard let first = session.orderedMessages.first(where: { $0.role == .user }) else { return }
        let text = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.title = String(text.prefix(48))
    }

    private static func toOllama(_ m: Message) -> OllamaChatMessage {
        switch m.role {
        case .assistant:
            let calls = m.toolCalls.map {
                OllamaToolCall(function: .init(name: $0.name, arguments: JSONValue.parse($0.argumentsJSON)))
            }
            return OllamaChatMessage(
                role: "assistant", content: m.content,
                toolCalls: calls.isEmpty ? nil : calls
            )
        case .tool:
            return OllamaChatMessage(role: "tool", content: m.content, toolName: m.toolName)
        case .system:
            return OllamaChatMessage(role: "system", content: m.content)
        case .user:
            return OllamaChatMessage(role: "user", content: m.content)
        }
    }
}
