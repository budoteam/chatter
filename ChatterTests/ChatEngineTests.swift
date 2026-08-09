import XCTest
import SwiftData
@testable import Chatter

/// Tool loop, dispatch routing, cancellation and the tool-round budget of
/// `ChatEngine`, driven by scripted `OllamaServiceProtocol` / `MCPClientProtocol`
/// / `KnowledgeToolProviding` mocks against an in-memory store.
@MainActor
final class ChatEngineTests: XCTestCase {
    // ModelContext does not retain its container; a local would deallocate on
    // return and the first insert would trap inside SwiftData.
    private var container: ModelContainer?

    override func tearDown() {
        // Global UserDefaults-backed setting; without a reset the vision
        // fallback tests would bleed into each other and into other suites.
        AppSettings.visionModel = ""
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Agent.self, ChatSession.self, Message.self, Artifact.self,
            // In the hosted test process the `.automatic` default would hook
            // the in-memory store into the app's CloudKit mirroring (crash on
            // save: "No eligible connection available").
            configurations: ModelConfiguration(
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        )
        self.container = container
        return container.mainContext
    }

    private func makeSession(
        in context: ModelContext,
        mcpServerIDs: [UUID] = []
    ) -> (Agent, ChatSession) {
        // Web tools are gated on a Keychain API key; disabling them keeps the
        // offered tool set fully deterministic.
        let agent = Agent(name: "Test", modelId: "test-model", mcpServerIDs: mcpServerIDs, webAccessEnabled: false)
        context.insert(agent)
        let session = ChatSession()
        session.agent = agent
        context.insert(session)
        return (agent, session)
    }

    // MARK: - Mocks

    private final class MockOllamaService: OllamaServiceProtocol {
        /// Called per `streamChat` (call index, offered tools); returns the
        /// scripted stream for that round.
        var makeStream: ((Int, [OllamaTool]) -> AsyncThrowingStream<OllamaChatChunk, Error>)?
        /// Scripted `/api/show` capabilities per model name.
        var capabilities: [String: [String]] = [:]
        private(set) var callCount = 0
        private(set) var toolsPerCall: [Int] = []
        private(set) var modelsPerCall: [String] = []
        private(set) var messagesPerCall: [[OllamaChatMessage]] = []

        func listModels() async throws -> [OllamaModel] { [] }

        func modelCapabilities(model: String) async throws -> [String] {
            capabilities[model] ?? []
        }

        func streamChat(
            model: String,
            messages: [OllamaChatMessage],
            tools: [OllamaTool],
            temperature: Double,
            think: OllamaThinkValue?
        ) -> AsyncThrowingStream<OllamaChatChunk, Error> {
            let index = callCount
            callCount += 1
            toolsPerCall.append(tools.count)
            modelsPerCall.append(model)
            messagesPerCall.append(messages)
            guard let makeStream else {
                return AsyncThrowingStream { $0.finish() }
            }
            return makeStream(index, tools)
        }
    }

    @MainActor
    private final class MockMCPClient: MCPClientProtocol {
        var states: [UUID: MCPConnectionState] = [:]
        var resolvedTools: [ResolvedTool] = []
        var result = "mcp-result"
        private(set) var calls: [(name: String, argumentsJSON: String)] = []

        func syncConnections(configs: [MCPServerConfig]) async {}
        func connect(_ config: MCPServerConfig) async {}
        func disconnect(serverID: UUID) async {}
        func tools(forServerIDs ids: [UUID]) -> [ResolvedTool] { resolvedTools }
        func callTool(namespacedName: String, argumentsJSON: String) async throws -> String {
            calls.append((namespacedName, argumentsJSON))
            return result
        }
    }

    @MainActor
    private final class FakeKnowledge: KnowledgeToolProviding {
        private(set) var callNames: [String] = []

        func tools(bundleIDs: [UUID], context: ModelContext) -> [OllamaTool] { [] }
        func call(
            namespacedName: String,
            argumentsJSON: String,
            bundleIDs: [UUID],
            context: ModelContext
        ) throws -> String {
            callNames.append(namespacedName)
            return "knowledge-result"
        }
        func systemPromptSection(bundleIDs: [UUID], context: ModelContext) -> String? { nil }
    }

    private func stream(of chunks: [OllamaChatChunk]) -> AsyncThrowingStream<OllamaChatChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    // MARK: - Tests

    /// Tool round → tool message with the result is persisted, the second
    /// stream round runs and its text lands as an assistant message.
    func testToolRoundFeedsResultIntoSecondStream() async throws {
        let context = try makeContext()
        let (agent, session) = makeSession(in: context)
        let ollama = MockOllamaService()
        let call = OllamaToolCall(function: .init(
            name: "testserver__echo",
            arguments: .object(["text": .string("hi")])
        ))
        ollama.makeStream = { index, _ in
            switch index {
            case 0:
                return self.stream(of: [.toolCalls([call]), .done(reason: nil)])
            default:
                return self.stream(of: [.delta("Hello"), .delta(" world"), .done(reason: "stop")])
            }
        }
        let mcp = MockMCPClient()
        mcp.result = "echo: hi"
        let engine = ChatEngine(ollama: ollama, mcp: mcp, knowledge: FakeKnowledge(), artifacts: ArtifactToolProvider())

        try await engine.send(text: "ping", session: session, agent: agent, context: context)

        XCTAssertEqual(mcp.calls.map { $0.name }, ["testserver__echo"])
        XCTAssertEqual(mcp.calls.map { $0.argumentsJSON }, [#"{"text":"hi"}"#])
        XCTAssertEqual(ollama.callCount, 2, "tool result must trigger a second stream round")

        let messages = session.orderedMessages
        let toolMessages = messages.filter { $0.role == .tool }
        XCTAssertEqual(toolMessages.count, 1)
        XCTAssertEqual(toolMessages.first?.toolName, "testserver__echo")
        XCTAssertEqual(toolMessages.first?.content, "echo: hi")

        let last = try XCTUnwrap(messages.last)
        XCTAssertEqual(last.role, .assistant)
        XCTAssertEqual(last.content, "Hello world")
        XCTAssertFalse(last.isStreaming)

        // The assistant turn that requested the call persisted it, so the
        // request/response pair replays structurally valid on later sends.
        let requesting = messages.first { $0.role == .assistant }
        XCTAssertEqual(requesting?.toolCalls.map(\.name), ["testserver__echo"])
    }

    /// Dispatch routing: with no knowledge bundles the knowledge fake offers
    /// no tools, so even a `knowledge__…`-named call falls through to MCP —
    /// built-ins only shadow MCP names they actually offered.
    func testCallWithUnknownPrefixIsRoutedToMCP() async throws {
        let context = try makeContext()
        let (agent, session) = makeSession(in: context)
        let ollama = MockOllamaService()
        let call = OllamaToolCall(function: .init(
            name: "knowledge__list",
            arguments: .object([:])
        ))
        ollama.makeStream = { index, _ in
            index == 0
                ? self.stream(of: [.toolCalls([call]), .done(reason: nil)])
                : self.stream(of: [.delta("done"), .done(reason: "stop")])
        }
        let mcp = MockMCPClient()
        let knowledge = FakeKnowledge()
        let engine = ChatEngine(ollama: ollama, mcp: mcp, knowledge: knowledge, artifacts: ArtifactToolProvider())

        try await engine.send(text: "ping", session: session, agent: agent, context: context)

        XCTAssertEqual(mcp.calls.map { $0.name }, ["knowledge__list"])
        XCTAssertTrue(knowledge.callNames.isEmpty, "unoffered knowledge__ names belong to MCP")
    }

    /// Cancelling mid-stream keeps the already-streamed partial content and
    /// does not surface an error out of `send`.
    func testCancelDuringStreamKeepsPartialContent() async throws {
        let context = try makeContext()
        let (agent, session) = makeSession(in: context)
        let ollama = MockOllamaService()
        ollama.makeStream = { _, _ in
            // Never finishes on its own; cancellation of the consuming task
            // ends the stream (AsyncStream returns nil on the next await).
            AsyncThrowingStream { continuation in
                continuation.yield(.delta("Teilwort"))
            }
        }
        let engine = ChatEngine(ollama: ollama, mcp: MockMCPClient(), knowledge: FakeKnowledge(), artifacts: ArtifactToolProvider())

        let turn = Task { @MainActor in
            do {
                try await engine.send(text: "ping", session: session, agent: agent, context: context)
                return nil as Error?
            } catch {
                return error
            }
        }
        // Let the first delta arrive and the loop suspend on the next chunk.
        try await Task.sleep(nanoseconds: 300_000_000)
        turn.cancel()
        let surfacedError = await turn.value

        XCTAssertNil(surfacedError, "user-initiated stop must not surface as an error")
        let assistant = try XCTUnwrap(session.orderedMessages.last)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.content, "Teilwort", "partial content must survive the stop")
        XCTAssertFalse(assistant.isStreaming)
    }

    /// Budget: after 42 tool rounds the engine streams one final round
    /// without offering tools, so the turn still ends in a text answer.
    func testToolBudgetEndsWithToollessFinalRound() async throws {
        let context = try makeContext()
        let serverID = UUID()
        let (agent, session) = makeSession(in: context, mcpServerIDs: [serverID])
        let ollama = MockOllamaService()
        let call = OllamaToolCall(function: .init(name: "srv__loop", arguments: .object([:])))
        ollama.makeStream = { index, _ in
            index < 42
                ? self.stream(of: [.toolCalls([call]), .done(reason: nil)])
                : self.stream(of: [.delta("Fertig."), .done(reason: "stop")])
        }
        let mcp = MockMCPClient()
        mcp.resolvedTools = [ResolvedTool(
            namespacedName: "srv__loop",
            originalName: "loop",
            toolDescription: "Loops forever.",
            parameters: .object([:]),
            serverID: serverID,
            serverName: "srv"
        )]
        let engine = ChatEngine(ollama: ollama, mcp: mcp, knowledge: FakeKnowledge(), artifacts: ArtifactToolProvider())

        try await engine.send(text: "ping", session: session, agent: agent, context: context)

        XCTAssertEqual(mcp.calls.count, 42, "one tool execution per budgeted round")
        XCTAssertEqual(ollama.callCount, 43, "42 tool rounds + 1 final round")
        // 6 tools per round: the MCP loop tool + the built-in artifact tool +
        // the four always-on reminder tools.
        XCTAssertTrue(ollama.toolsPerCall.prefix(42).allSatisfy { $0 == 6 })
        XCTAssertEqual(ollama.toolsPerCall.last, 0, "final round must offer no tools")
        XCTAssertEqual(session.orderedMessages.last?.content, "Fertig.")
    }

    /// Non-vision chat model + configured fallback: the vision model describes
    /// the image once, the description persists on the message and is inlined
    /// as text into the main turn instead of the images.
    func testNonVisionModelUsesVisionFallbackForImages() async throws {
        let context = try makeContext()
        let (agent, session) = makeSession(in: context)
        let ollama = MockOllamaService()
        ollama.capabilities = [
            "test-model": ["completion"],
            "vision-cloud": ["completion", "vision"]
        ]
        AppSettings.visionModel = "vision-cloud"
        ollama.makeStream = { index, _ in
            index == 0
                ? self.stream(of: [.delta("A red square."), .done(reason: "stop")])
                : self.stream(of: [.delta("answer"), .done(reason: "stop")])
        }
        let engine = ChatEngine(ollama: ollama, mcp: MockMCPClient(), knowledge: FakeKnowledge(), artifacts: ArtifactToolProvider())

        try await engine.send(
            text: "what is this?",
            images: [ImageAttachment(base64: "aW1n")],
            session: session, agent: agent, context: context
        )

        XCTAssertEqual(ollama.callCount, 2, "one describe call + one main turn")
        XCTAssertEqual(ollama.modelsPerCall, ["vision-cloud", "test-model"])
        let sentUser = try XCTUnwrap(ollama.messagesPerCall[1].first { $0.role == "user" })
        XCTAssertNil(sentUser.images, "non-vision model must not receive the images")
        XCTAssertTrue(sentUser.content.contains("A red square."))
        XCTAssertTrue(sentUser.content.contains("what is this?"))
        let persistedUser = try XCTUnwrap(session.orderedMessages.first { $0.role == .user })
        XCTAssertTrue(persistedUser.imageNote.contains("A red square."))
        XCTAssertEqual(session.orderedMessages.last?.content, "answer")
    }

    /// The invisible describe phase is exposed via `turnPhase`: set while the
    /// describe streams, cleared (defer) before the main turn starts.
    func testVisionFallbackExposesDescribingPhase() async throws {
        let context = try makeContext()
        let (agent, session) = makeSession(in: context)
        let ollama = MockOllamaService()
        ollama.capabilities = [
            "test-model": ["completion"],
            "vision-cloud": ["completion", "vision"]
        ]
        AppSettings.visionModel = "vision-cloud"
        let engine = ChatEngine(ollama: ollama, mcp: MockMCPClient(), knowledge: FakeKnowledge(), artifacts: ArtifactToolProvider())
        ollama.makeStream = { index, _ in
            // streamChat is non-async and the engine is @MainActor, so this
            // closure runs synchronously on the MainActor.
            MainActor.assumeIsolated {
                if index == 0 {
                    XCTAssertEqual(
                        engine.turnPhase[session.id],
                        .describingImages(model: "vision-cloud", current: 1, total: 1)
                    )
                } else {
                    XCTAssertNil(engine.turnPhase[session.id], "defer cleared the phase before the main turn")
                }
            }
            return index == 0
                ? self.stream(of: [.delta("A red square."), .done(reason: "stop")])
                : self.stream(of: [.delta("answer"), .done(reason: "stop")])
        }

        try await engine.send(
            text: "what is this?",
            images: [ImageAttachment(base64: "aW1n")],
            session: session, agent: agent, context: context
        )

        XCTAssertNil(engine.turnPhase[session.id])
    }

    /// Vision-capable chat model: images go directly to the model; the
    /// configured fallback is not used and no description is persisted.
    func testVisionCapableModelReceivesImagesDirectly() async throws {
        let context = try makeContext()
        let (agent, session) = makeSession(in: context)
        let ollama = MockOllamaService()
        ollama.capabilities = ["test-model": ["completion", "vision"]]
        AppSettings.visionModel = "vision-cloud"
        ollama.makeStream = { _, _ in
            self.stream(of: [.delta("answer"), .done(reason: "stop")])
        }
        let engine = ChatEngine(ollama: ollama, mcp: MockMCPClient(), knowledge: FakeKnowledge(), artifacts: ArtifactToolProvider())

        try await engine.send(
            text: "what is this?",
            images: [ImageAttachment(base64: "aW1n")],
            session: session, agent: agent, context: context
        )

        XCTAssertEqual(ollama.callCount, 1, "no describe call for a vision-capable model")
        let sentUser = try XCTUnwrap(ollama.messagesPerCall[0].first { $0.role == "user" })
        XCTAssertEqual(sentUser.images, ["aW1n"])
        let persistedUser = try XCTUnwrap(session.orderedMessages.first { $0.role == .user })
        XCTAssertTrue(persistedUser.imageNote.isEmpty)
    }

    /// No fallback configured and no model vision: today's passthrough stays
    /// untouched — images are attached as-is, no description is persisted.
    func testNonVisionModelWithoutFallbackKeepsPassthrough() async throws {
        let context = try makeContext()
        let (agent, session) = makeSession(in: context)
        let ollama = MockOllamaService()
        AppSettings.visionModel = ""
        ollama.makeStream = { _, _ in
            self.stream(of: [.delta("answer"), .done(reason: "stop")])
        }
        let engine = ChatEngine(ollama: ollama, mcp: MockMCPClient(), knowledge: FakeKnowledge(), artifacts: ArtifactToolProvider())

        try await engine.send(
            text: "what is this?",
            images: [ImageAttachment(base64: "aW1n")],
            session: session, agent: agent, context: context
        )

        XCTAssertEqual(ollama.callCount, 1)
        let sentUser = try XCTUnwrap(ollama.messagesPerCall[0].first { $0.role == "user" })
        XCTAssertEqual(sentUser.images, ["aW1n"])
        let persistedUser = try XCTUnwrap(session.orderedMessages.first { $0.role == .user })
        XCTAssertTrue(persistedUser.imageNote.isEmpty)
    }

    /// A failing describe call fails the turn visibly (EngineError) instead of
    /// silently dropping the images; no truncated description is persisted.
    func testVisionFallbackFailureSurfaces() async throws {
        let context = try makeContext()
        let (agent, session) = makeSession(in: context)
        let ollama = MockOllamaService()
        ollama.capabilities = ["test-model": ["completion"]]
        AppSettings.visionModel = "vision-cloud"
        ollama.makeStream = { _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(domain: "test", code: 1))
            }
        }
        let engine = ChatEngine(ollama: ollama, mcp: MockMCPClient(), knowledge: FakeKnowledge(), artifacts: ArtifactToolProvider())

        do {
            try await engine.send(
                text: "what is this?",
                images: [ImageAttachment(base64: "aW1n")],
                session: session, agent: agent, context: context
            )
            XCTFail("a failing describe call must fail the turn")
        } catch let error as ChatEngine.EngineError {
            guard case .visionFallbackFailed = error else {
                return XCTFail("expected visionFallbackFailed, got \(error)")
            }
        }

        let persistedUser = try XCTUnwrap(session.orderedMessages.first { $0.role == .user })
        XCTAssertTrue(persistedUser.imageNote.isEmpty)
        XCTAssertNil(session.orderedMessages.first { $0.role == .assistant },
                     "no assistant turn may start after a failed describe")
    }

    /// A cancelled describe must surface as CancellationError (user-stop
    /// semantics), never wrapped into EngineError.
    func testCancelledDescribeSurfacesAsCancellation() async throws {
        let context = try makeContext()
        let (agent, session) = makeSession(in: context)
        let ollama = MockOllamaService()
        ollama.capabilities = ["test-model": ["completion"]]
        AppSettings.visionModel = "vision-cloud"
        ollama.makeStream = { _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: CancellationError())
            }
        }
        let engine = ChatEngine(ollama: ollama, mcp: MockMCPClient(), knowledge: FakeKnowledge(), artifacts: ArtifactToolProvider())

        do {
            try await engine.send(
                text: "what is this?",
                images: [ImageAttachment(base64: "aW1n")],
                session: session, agent: agent, context: context
            )
            XCTFail("a cancelled describe must throw")
        } catch is CancellationError {
            // expected — must not be wrapped in EngineError
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let persistedUser = try XCTUnwrap(session.orderedMessages.first { $0.role == .user })
        XCTAssertTrue(persistedUser.imageNote.isEmpty)
    }

    /// A per-chat model pin (composer quick-switch) beats the agent's model and
    /// becomes the session snapshot; clearing it falls back to the agent.
    func testModelOverrideWinsOverAgentModel() async throws {
        let context = try makeContext()
        let (agent, session) = makeSession(in: context)
        session.modelOverride = "override-model"
        let ollama = MockOllamaService()
        ollama.makeStream = { _, _ in self.stream(of: [.delta("ok"), .done(reason: "stop")]) }
        let engine = ChatEngine(ollama: ollama, mcp: MockMCPClient(), knowledge: FakeKnowledge(), artifacts: ArtifactToolProvider())

        try await engine.send(text: "hi", session: session, agent: agent, context: context)
        XCTAssertEqual(ollama.modelsPerCall, ["override-model"])
        XCTAssertEqual(session.modelId, "override-model")

        session.modelOverride = ""
        try await engine.regenerate(session: session, agent: agent, context: context)
        XCTAssertEqual(ollama.modelsPerCall, ["override-model", "test-model"])
    }

    /// Regenerate must not re-describe already-described messages: the
    /// persisted imageNote is reused, only the main turn is streamed again.
    func testRegenerateSkipsAlreadyDescribedImages() async throws {
        let context = try makeContext()
        let (agent, session) = makeSession(in: context)
        let ollama = MockOllamaService()
        ollama.capabilities = ["test-model": ["completion"]]
        AppSettings.visionModel = "vision-cloud"
        ollama.makeStream = { index, _ in
            index == 0
                ? self.stream(of: [.delta("A red square."), .done(reason: "stop")])
                : self.stream(of: [.delta("answer"), .done(reason: "stop")])
        }
        let engine = ChatEngine(ollama: ollama, mcp: MockMCPClient(), knowledge: FakeKnowledge(), artifacts: ArtifactToolProvider())

        try await engine.send(
            text: "what is this?",
            images: [ImageAttachment(base64: "aW1n")],
            session: session, agent: agent, context: context
        )
        XCTAssertEqual(ollama.callCount, 2)

        try await engine.regenerate(session: session, agent: agent, context: context)

        XCTAssertEqual(ollama.callCount, 3, "regenerate adds exactly one main turn")
        XCTAssertEqual(ollama.modelsPerCall, ["vision-cloud", "test-model", "test-model"],
                       "no second describe call for the persisted imageNote")
        let sentUser = try XCTUnwrap(ollama.messagesPerCall[2].first { $0.role == "user" })
        XCTAssertNil(sentUser.images)
        XCTAssertTrue(sentUser.content.contains("A red square."),
                      "regenerate still inlines the persisted description")
    }
}
