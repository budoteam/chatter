import Foundation
import SwiftData

/// Drives a single assistant turn, including the MCP tool loop:
/// stream → if the model requested tools, run them and feed results back →
/// stream again, until the model answers. After `maxToolIterations` tool
/// rounds a last round is streamed without offering tools, so the turn
/// always ends in a text answer instead of dropping silently.
@MainActor
final class ChatEngine {
    private let ollama: OllamaServiceProtocol
    private let mcp: MCPClientProtocol
    private let knowledge: KnowledgeToolProviding
    private let web: WebToolProvider
    private let memory = MemoryToolProvider()
    private let skills = SkillToolProvider()
    private let maxToolIterations = 42

    init(ollama: OllamaServiceProtocol, mcp: MCPClientProtocol, knowledge: KnowledgeToolProviding) {
        self.ollama = ollama
        self.mcp = mcp
        self.knowledge = knowledge
        self.web = WebToolProvider(ollama: ollama)
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
    func send(
        text: String,
        images: [ImageAttachment] = [],
        session: ChatSession,
        agent: Agent?,
        context: ModelContext
    ) async throws {
        let model = resolveModel(agent: agent, session: session)
        guard !model.isEmpty else { throw EngineError.noModel }
        session.modelId = model

        let userMsg = Message(role: .user, content: text, orderIndex: session.nextOrderIndex)
        userMsg.imageAttachments = images
        userMsg.session = session
        context.insert(userMsg)
        session.updatedAt = .now
        context.saveOrLog()

        try await runTurns(model: model, session: session, agent: agent, context: context)
    }

    /// Re-runs the assistant turn on the existing history — no new user
    /// message is appended (message resend/regenerate).
    func regenerate(session: ChatSession, agent: Agent?, context: ModelContext) async throws {
        let model = resolveModel(agent: agent, session: session)
        guard !model.isEmpty else { throw EngineError.noModel }
        session.modelId = model
        try await runTurns(model: model, session: session, agent: agent, context: context)
    }

    /// The agentic tool loop: stream → run requested tools → stream again.
    private func runTurns(
        model: String,
        session: ChatSession,
        agent: Agent?,
        context: ModelContext
    ) async throws {
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

        // Built-in web research tools (ollama.com web search API), offered
        // when the agent allows web access and an API key is present.
        let webTools = (agent?.webAccessEnabled ?? true) && KeychainService.hasAPIKey
            ? web.tools() : []
        let webToolNames = Set(webTools.map(\.function.name))
        tools += webTools

        // Built-in self-managed memory tools, offered when the agent has
        // memory enabled.
        let memoryEnabled = agent?.memoryEnabled ?? false
        let memoryTools = memoryEnabled ? memory.tools() : []
        let memoryToolNames = Set(memoryTools.map(\.function.name))
        tools += memoryTools

        // Built-in skill tools: read for enabled skills, plus authoring when
        // the agent may write to the shared pool.
        let skillIDs = agent?.skillIDs ?? []
        let skillTools = skills.tools(
            skillIDs: skillIDs,
            authoringEnabled: agent?.skillAuthoringEnabled ?? false,
            context: context
        )
        let skillToolNames = Set(skillTools.map(\.function.name))
        tools += skillTools

        // The knowledge overview is stable within one send; compute it once
        // instead of per tool-loop iteration (it fetches and walks bundles).
        // Same for the skill index and the memory listing — a mid-turn save
        // is confirmed by its tool result and shows up fully on the next send.
        let knowledgeSection = knowledge.systemPromptSection(
            bundleIDs: knowledgeBundleIDs, context: context
        )
        let skillsSection = skills.systemPromptSection(
            skillIDs: skillIDs,
            authoringEnabled: agent?.skillAuthoringEnabled ?? false,
            context: context
        )
        let memorySection = memoryEnabled
            ? memory.systemPromptSection(agentID: agent?.id, context: context)
            : nil

        var iteration = 0
        while true {
            iteration += 1
            try Task.checkCancellation()
            // Tool budget exhausted → withhold the tools so the model has to
            // answer in text (summarizing how far it got) instead of the turn
            // ending without any reply.
            let finalRound = iteration > maxToolIterations

            // Build the request from the persisted history (system prompt first).
            // Rebuilt every iteration, so the timestamp stays current across
            // long tool loops.
            var msgs: [OllamaChatMessage] = [
                OllamaChatMessage(
                    role: "system",
                    content: Self.systemPrompt(
                        for: agent,
                        knowledgeSection: knowledgeSection,
                        skillsSection: skillsSection,
                        memorySection: memorySection
                    )
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
                    model: model, messages: msgs, tools: finalRound ? [] : tools,
                    temperature: agent?.temperature ?? 0.7,
                    think: agent?.thinkingMode.ollamaValue
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
                context.saveOrLog()
                return
            } catch {
                flushPending(force: true)
                assistant.isStreaming = false
                // Don't leave an empty bubble behind; the error is surfaced
                // via the view model's alert.
                if assistant.content.isEmpty {
                    context.delete(assistant)
                }
                context.saveOrLog()
                throw error
            }
            assistant.isStreaming = false

            // No tools requested → this is the final answer. Same on the
            // forced final round: no tools were offered, and any calls a model
            // emits anyway would have nobody left to answer them.
            if toolCalls.isEmpty || finalRound {
                maybeAutoTitle(session)
                session.updatedAt = .now
                context.saveOrLog()
                return
            }

            // Persist the requested calls on the assistant turn, then run them.
            assistant.toolCalls = toolCalls.map {
                ToolCall(name: $0.function.name, argumentsJSON: $0.function.arguments.jsonString)
            }
            context.saveOrLog()

            /// Stop mid-execution answers every call the model is still
            /// waiting on with a cancellation marker: `toolCalls` persisted
            /// without their tool responses would be replayed on the next
            /// send and make every later request structurally invalid.
            func cancelUnanswered(from index: Int) {
                for unanswered in toolCalls[index...] {
                    let toolMsg = Message(
                        role: .tool, content: "Cancelled by user.",
                        orderIndex: session.nextOrderIndex, toolName: unanswered.function.name
                    )
                    toolMsg.session = session
                    context.insert(toolMsg)
                }
                session.updatedAt = .now
                context.saveOrLog()
            }

            var answered = 0
            for call in toolCalls {
                // Stop must abort the turn even between/while tool calls —
                // a swallowed CancellationError would keep the loop running.
                if Task.isCancelled {
                    cancelUnanswered(from: answered)
                    return
                }
                let name = call.function.name
                let argsJSON = call.function.arguments.jsonString
                let result: String
                do {
                    if knowledgeToolNames.contains(name) {
                        result = try knowledge.call(
                            namespacedName: name, argumentsJSON: argsJSON,
                            bundleIDs: knowledgeBundleIDs, context: context
                        )
                    } else if webToolNames.contains(name) {
                        result = try await web.call(name: name, argumentsJSON: argsJSON)
                    } else if memoryToolNames.contains(name) {
                        result = try memory.call(
                            namespacedName: name, argumentsJSON: argsJSON,
                            agentID: agent?.id, context: context
                        )
                    } else if skillToolNames.contains(name), let agent {
                        result = try skills.call(
                            namespacedName: name, argumentsJSON: argsJSON,
                            agent: agent, context: context
                        )
                    } else {
                        result = try await mcp.callTool(namespacedName: name, argumentsJSON: argsJSON)
                    }
                } catch is CancellationError {
                    cancelUnanswered(from: answered)
                    return
                } catch {
                    result = "Tool error: \(error.localizedDescription)"
                }
                let toolMsg = Message(
                    role: .tool, content: result,
                    orderIndex: session.nextOrderIndex, toolName: name
                )
                toolMsg.session = session
                context.insert(toolMsg)
                answered += 1
            }
            session.updatedAt = .now
            context.saveOrLog()
            // Loop: model gets another turn with the tool results in history.
        }
    }

    // MARK: - Helpers

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    /// The agent's system prompt plus its knowledge overview, skill index and
    /// memory listing, always ending with the current date & time.
    private static func systemPrompt(
        for agent: Agent?,
        knowledgeSection: String?,
        skillsSection: String?,
        memorySection: String?
    ) -> String {
        let timestamp = "Current Date and Time: \(timestampFormatter.string(from: Date()))"
        var parts: [String] = []
        let prompt = agent?.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prompt.isEmpty { parts.append(prompt) }
        if let knowledgeSection { parts.append(knowledgeSection) }
        if let skillsSection { parts.append(skillsSection) }
        if let memorySection { parts.append(memorySection) }
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
            let images = m.imageAttachments.map(\.base64)
            return OllamaChatMessage(
                role: "user", content: m.content,
                images: images.isEmpty ? nil : images
            )
        }
    }
}
