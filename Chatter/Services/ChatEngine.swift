import Foundation
import SwiftData

/// Drives a single assistant turn, including the MCP tool loop:
/// stream → if the model requested tools, run them and feed results back →
/// stream again, until the model answers or we hit the iteration cap.
@MainActor
final class ChatEngine {
    private let ollama: OllamaServiceProtocol
    private let mcp: MCPConnectionManager
    private let maxToolIterations = 6

    init(ollama: OllamaServiceProtocol, mcp: MCPConnectionManager) {
        self.ollama = ollama
        self.mcp = mcp
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
        let tools = resolved.map {
            OllamaTool(function: .init(
                name: $0.namespacedName,
                description: $0.toolDescription,
                parameters: $0.parameters
            ))
        }

        var iteration = 0
        while iteration < maxToolIterations {
            iteration += 1

            // Build the request from the persisted history (system prompt first).
            var msgs: [OllamaChatMessage] = []
            if let prompt = agent?.systemPrompt, !prompt.isEmpty {
                msgs.append(OllamaChatMessage(role: "system", content: prompt))
            }
            msgs.append(contentsOf: session.orderedMessages.map(Self.toOllama))

            // Live assistant message the view streams into.
            let assistant = Message(
                role: .assistant, content: "",
                orderIndex: session.nextOrderIndex, isStreaming: true
            )
            assistant.session = session
            context.insert(assistant)

            var toolCalls: [OllamaToolCall] = []
            do {
                for try await chunk in ollama.streamChat(
                    model: model, messages: msgs, tools: tools,
                    temperature: agent?.temperature ?? 0.7
                ) {
                    switch chunk {
                    case .delta(let piece): assistant.content += piece
                    case .toolCalls(let calls): toolCalls.append(contentsOf: calls)
                    case .done: break
                    }
                }
            } catch is CancellationError {
                // User stopped — keep whatever streamed in, no error surface.
                assistant.isStreaming = false
                session.updatedAt = .now
                try? context.save()
                return
            } catch {
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
                    result = try await mcp.callTool(namespacedName: name, argumentsJSON: argsJSON)
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
