import Foundation
import MCP
#if os(macOS)
import System
#endif

/// Owns live MCP `Client` sessions, keeps a namespaced tool registry, and
/// dispatches tool calls. Remote servers use Streamable HTTP (+ optional SSE);
/// macOS additionally supports stdio servers launched as subprocesses.
@MainActor
@Observable
final class MCPConnectionManager: MCPClientProtocol {
    private(set) var states: [UUID: MCPConnectionState] = [:]
    private(set) var toolsByServer: [UUID: [ResolvedTool]] = [:]

    private var clients: [UUID: Client] = [:]
    /// namespacedName -> (owning server, original tool name)
    private var registry: [String: (serverID: UUID, original: String)] = [:]
    #if os(macOS)
    private var processes: [UUID: Process] = [:]
    #endif

    // MARK: - Lifecycle

    func syncConnections(configs: [MCPServerConfig]) async {
        let enabled = configs.filter(\.enabled)
        let wanted = Set(enabled.map(\.id))

        // Drop connections that are gone or disabled.
        for id in clients.keys where !wanted.contains(id) {
            await disconnect(serverID: id)
        }
        // Connect anything not already connected — concurrently, so one slow
        // or unreachable server doesn't stall the rest.
        await withTaskGroup(of: Void.self) { group in
            for config in enabled where clients[config.id] == nil {
                group.addTask { await self.connect(config) }
            }
        }
    }

    func connect(_ config: MCPServerConfig) async {
        states[config.id] = .connecting
        do {
            let transport = try makeTransport(for: config)
            let client = Client(name: "Chatter", version: "1.0.0")
            _ = try await client.connect(transport: transport)

            let (tools, _) = try await client.listTools()
            let resolved = tools.map { tool in
                ResolvedTool(
                    namespacedName: Self.namespaced(server: config.name, tool: tool.name),
                    originalName: tool.name,
                    toolDescription: tool.description ?? "",
                    parameters: Self.jsonValue(from: tool.inputSchema),
                    serverID: config.id,
                    serverName: config.name
                )
            }

            clients[config.id] = client
            toolsByServer[config.id] = resolved
            for t in resolved {
                registry[t.namespacedName] = (config.id, t.originalName)
            }
            states[config.id] = .connected(toolCount: resolved.count)
            AppLogger.mcp.info("Connected MCP '\(config.name, privacy: .public)' — \(resolved.count) tools")
        } catch {
            states[config.id] = .failed(error.localizedDescription)
            AppLogger.mcp.error("MCP connect '\(config.name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tears down all live sessions and reconnects the enabled ones. Used on
    /// iOS when returning to the foreground: suspension kills the sockets
    /// while the clients still report connected, so every tool call would
    /// hang until the app is force-quit.
    func refreshConnections(configs: [MCPServerConfig]) async {
        for id in Array(clients.keys) {
            await disconnect(serverID: id)
        }
        await syncConnections(configs: configs)
    }

    func disconnect(serverID: UUID) async {
        if let client = clients[serverID] {
            // Bounded: disconnecting over a dead socket must not hang either.
            try? await Self.withHardTimeout(seconds: 5, label: "disconnect") {
                await client.disconnect()
            }
        }
        clients[serverID] = nil
        // Purge this server's tools from the registry.
        for t in toolsByServer[serverID] ?? [] {
            registry[t.namespacedName] = nil
        }
        toolsByServer[serverID] = nil
        #if os(macOS)
        processes[serverID]?.terminate()
        processes[serverID] = nil
        #endif
        states[serverID] = .disconnected
    }

    // MARK: - Tools

    func tools(forServerIDs ids: [UUID]) -> [ResolvedTool] {
        ids.flatMap { toolsByServer[$0] ?? [] }
    }

    /// Hard ceiling for a single tool call. Dead transports (iOS suspends the
    /// app and its sockets die silently while the client still reports
    /// connected) would otherwise hang a call forever.
    private static let toolCallTimeout: TimeInterval = 60

    func callTool(namespacedName: String, argumentsJSON: String) async throws -> String {
        guard let entry = registry[namespacedName], let client = clients[entry.serverID] else {
            throw MCPError.toolUnavailable(namespacedName)
        }
        let arguments = Self.mcpArguments(from: argumentsJSON)
        let (content, isError) = try await Self.withHardTimeout(
            seconds: Self.toolCallTimeout, label: namespacedName
        ) {
            try await client.callTool(name: entry.original, arguments: arguments)
        }
        let text = Self.text(from: content)
        if isError == true {
            return "Tool error: \(text)"
        }
        return text.isEmpty ? "(no output)" : text
    }

    /// Awaits `operation` but is guaranteed to resume: with its result, with
    /// `MCPError.toolTimeout` after `seconds`, or with `CancellationError`
    /// when the calling task is cancelled — even if the underlying SDK call
    /// never honors cancellation (hung network call on a dead socket). A hung
    /// operation task may linger in the background, but the caller unblocks.
    private static func withHardTimeout<T: Sendable>(
        seconds: TimeInterval,
        label: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = HardTimeoutRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                race.store(cont)
                race.work = Task {
                    do { race.finish(.success(try await operation())) }
                    catch { race.finish(.failure(error)) }
                }
                race.timer = Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    race.finish(.failure(MCPError.toolTimeout(label)))
                }
                // onCancel may have fired before the continuation was stored.
                if Task.isCancelled {
                    race.finish(.failure(CancellationError()))
                }
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    // MARK: - Transport construction

    private func makeTransport(for config: MCPServerConfig) throws -> any Transport {
        switch config.transport {
        case .http, .sse:
            guard let url = URL(string: config.url), url.scheme != nil else {
                throw MCPError.badURL(config.url)
            }
            let key = config.headerKey.trimmingCharacters(in: .whitespaces)
            let value = config.headerValue
            let modifier: (URLRequest) -> URLRequest = { request in
                guard !key.isEmpty else { return request }
                var req = request
                req.setValue(value, forHTTPHeaderField: key)
                return req
            }
            if config.transport == .sse {
                // Legacy HTTP+SSE protocol (supergateway/mcp-proxy style
                // "/sse" endpoints) — these answer 405 to Streamable HTTP.
                return LegacySSEClientTransport(endpoint: url, requestModifier: modifier)
            }
            return HTTPClientTransport(
                endpoint: url,
                streaming: false,
                requestModifier: modifier
            )

        case .stdio:
            #if os(macOS)
            // Configs may sync in from an unsandboxed Mac; sandboxed builds
            // (TestFlight/App Store) can't spawn subprocesses.
            guard MCPTransportKind.stdioAvailable else { throw MCPError.stdioUnsupported }
            return try makeStdioTransport(for: config)
            #else
            throw MCPError.stdioUnsupported
            #endif
        }
    }

    #if os(macOS)
    private func makeStdioTransport(for config: MCPServerConfig) throws -> any Transport {
        let command = config.command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { throw MCPError.badCommand }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = config.args

        let toChild = Pipe()   // we write -> child's stdin
        let fromChild = Pipe() // child's stdout -> we read
        process.standardInput = toChild
        process.standardOutput = fromChild

        try process.run()
        processes[config.id] = process

        let input = FileDescriptor(rawValue: fromChild.fileHandleForReading.fileDescriptor)
        let output = FileDescriptor(rawValue: toChild.fileHandleForWriting.fileDescriptor)
        return StdioTransport(input: input, output: output)
    }
    #endif

    // MARK: - Conversions (JSONValue <-> MCP Value)

    private static func jsonValue(from value: Value) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let jv = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object(["type": .string("object")])
        }
        return jv
    }

    private static func mcpArguments(from json: String) -> [String: Value]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: Value].self, from: data)
    }

    private static func text(from contents: [Tool.Content]) -> String {
        contents.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - Naming

    /// Namespaces a tool name with a sanitized server slug so identically named
    /// tools on different servers stay distinct for the model.
    static func namespaced(server: String, tool: String) -> String {
        let slug = server.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .prefix(24)
        return "\(String(slug))__\(tool)"
    }

    /// Resume-exactly-once bookkeeping for `withHardTimeout` (Swift doesn't
    /// allow nested types inside generic functions).
    private final class HardTimeoutRace<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?

        func store(_ c: CheckedContinuation<T, Error>) {
            lock.lock(); continuation = c; lock.unlock()
        }

        /// Resumes the continuation exactly once; later calls are no-ops.
        func finish(_ result: Result<T, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            guard let c else { return }
            work?.cancel()
            timer?.cancel()
            c.resume(with: result)
        }
    }

    enum MCPError: LocalizedError {
        case badURL(String)
        case badCommand
        case stdioUnsupported
        case toolUnavailable(String)
        case toolTimeout(String)

        var errorDescription: String? {
            switch self {
            case .badURL(let s): return "Invalid server URL: \(s)"
            case .badCommand: return "Missing stdio command."
            case .stdioUnsupported: return "stdio MCP servers need an unsandboxed macOS build (not available in TestFlight/App Store builds)."
            case .toolUnavailable(let name): return "Tool '\(name)' is not available."
            case .toolTimeout(let name): return "Tool '\(name)' timed out — the server may be unreachable."
            }
        }
    }
}
