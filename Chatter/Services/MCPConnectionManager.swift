import Foundation
import MCP
#if os(macOS)
import AppKit
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
    /// Last configs seen by `syncConnections`, so a silently dead session
    /// (sleep, network change, crashed stdio subprocess) can be rebuilt
    /// without waiting for the next app launch.
    private var configs: [UUID: MCPServerConfig] = [:]
    /// namespacedName -> (owning server, original tool name)
    private var registry: [String: (serverID: UUID, original: String)] = [:]
    /// Servers with a connect currently in flight. Without tracking them, a
    /// concurrent sync/refresh would start a second connect whose late finish
    /// leaks the first client's transport/subprocess on overwrite.
    private var connecting: Set<UUID> = []
    /// In-flight reactive reconnect per server (see callTool). Concurrent
    /// failures on the same server await the shared reconnect instead of
    /// racing a second connect that would early-return empty-handed and
    /// misreport toolUnavailable.
    private var reconnects: [UUID: Task<Void, Never>] = [:]
    /// Namespace slug reserved by each connected/connecting server. Two
    /// servers whose names sanitize to the same slug ("My API" vs "my-api")
    /// would register identical tool names and silently route calls to the
    /// wrong server, so the second one is refused.
    private var slugs: [UUID: String] = [:]
    #if os(macOS)
    private var processes: [UUID: Process] = [:]
    /// The manager is owned by AppEnvironment and lives as long as the app,
    /// so this observer deliberately has no matching removeObserver.
    private var wakeObserver: NSObjectProtocol?
    #endif

    // MARK: - Lifecycle

    func syncConnections(configs: [MCPServerConfig]) async {
        let enabled = configs.filter(\.enabled)
        let wanted = Set(enabled.map(\.id))
        self.configs = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
        #if os(macOS)
        startObservingWakeIfNeeded()
        #endif

        // Drop connections that are gone or disabled.
        for id in clients.keys where !wanted.contains(id) {
            await disconnect(serverID: id)
        }
        // Connect anything not already connected — concurrently, so one slow
        // or unreachable server doesn't stall the rest.
        await withTaskGroup(of: Void.self) { group in
            for config in enabled where clients[config.id] == nil && !connecting.contains(config.id) {
                group.addTask { await self.connect(config) }
            }
        }
    }

    func connect(_ config: MCPServerConfig) async {
        guard clients[config.id] == nil, !connecting.contains(config.id) else { return }
        let slug = Self.slug(for: config.name)
        guard !slugs.values.contains(slug) else {
            states[config.id] = .failed("'\(config.name)' has the same tool namespace as another connected server — rename one of them.")
            AppLogger.mcp.error("MCP connect '\(config.name, privacy: .public)' refused: namespace slug '\(slug, privacy: .public)' already in use")
            return
        }
        configs[config.id] = config
        connecting.insert(config.id)
        slugs[config.id] = slug
        defer { connecting.remove(config.id) }

        states[config.id] = .connecting
        let client = Client(name: "Chatter", version: "1.0.0")
        do {
            let transport = try makeTransport(for: config)
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
            // Roll back whatever got as far as starting: a stdio subprocess
            // launched in makeTransport, or a transport that connected before
            // listTools threw — both would otherwise leak.
            #if os(macOS)
            processes[config.id]?.terminate()
            processes[config.id] = nil
            #endif
            try? await Self.withHardTimeout(seconds: 5, label: "connect-cleanup") {
                await client.disconnect()
            }
            slugs[config.id] = nil
            states[config.id] = .failed(error.localizedDescription)
            AppLogger.mcp.error("MCP connect '\(config.name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tears down all live sessions and reconnects the enabled ones. Used on
    /// iOS when returning to the foreground and on macOS after system wake:
    /// suspension/sleep kills the sockets while the clients still report
    /// connected, so every tool call would hang until the app is restarted.
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
        slugs[serverID] = nil
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
        do {
            return try await performCall(
                client: client, originalName: entry.original,
                label: namespacedName, argumentsJSON: argumentsJSON
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            // A once-connected server whose call fails mid-session almost
            // always means the transport died silently (macOS sleep, network
            // change, crashed stdio subprocess) while the state still claims
            // "connected". Rebuild the session and retry the call once, so a
            // stale connection heals itself instead of hanging every turn
            // until the app is restarted. The state then tells the truth
            // again: .connected after a successful reconnect, else .failed.
            guard let config = configs[entry.serverID], config.enabled else { throw error }
            if let reconnect = reconnects[entry.serverID] {
                // Another failed call is already rebuilding this session.
                await reconnect.value
            } else {
                guard case .connected = states[entry.serverID] else { throw error }
                AppLogger.mcp.info("MCP call '\(namespacedName, privacy: .public)' failed — reconnecting '\(config.name, privacy: .public)' and retrying once")
                let reconnect = Task {
                    await self.disconnect(serverID: entry.serverID)
                    await self.connect(config)
                }
                reconnects[entry.serverID] = reconnect
                await reconnect.value
                reconnects[entry.serverID] = nil
            }
            guard let retry = registry[namespacedName], let retryClient = clients[retry.serverID] else {
                throw MCPError.toolUnavailable(namespacedName)
            }
            return try await performCall(
                client: retryClient, originalName: retry.original,
                label: namespacedName, argumentsJSON: argumentsJSON
            )
        }
    }

    /// Single tool invocation against a live client, bounded by the hard
    /// timeout; extracted so the reconnect path can retry without
    /// duplicating the timeout/result mapping.
    private func performCall(
        client: Client,
        originalName: String,
        label: String,
        argumentsJSON: String
    ) async throws -> String {
        let arguments = Self.mcpArguments(from: argumentsJSON)
        let (content, isError) = try await Self.withHardTimeout(
            seconds: Self.toolCallTimeout, label: label
        ) {
            try await client.callTool(name: originalName, arguments: arguments)
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
    /// macOS pendant to the iOS foreground refresh: sleep kills the sockets
    /// while the clients still report connected. Registered lazily on the
    /// first sync; lives on the manager (not a view) so it also fires with
    /// no window open, e.g. for handoff turns.
    private func startObservingWakeIfNeeded() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshConnections(configs: Array(self.configs.values))
            }
        }
    }

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

        // Unexpected exit (crash) leaves the connection green while every
        // call hangs — reconnect right away so the state tells the truth.
        // Guarded against our own terminate() in disconnect/rollback: both
        // clear processes[id] before this handler gets to run.
        let serverID = config.id
        let serverName = config.name
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self, self.processes[serverID] === proc,
                      case .connected = self.states[serverID] else { return }
                AppLogger.mcp.error("MCP stdio server '\(serverName, privacy: .public)' exited unexpectedly — reconnecting")
                await self.disconnect(serverID: serverID)
                if let config = self.configs[serverID], config.enabled {
                    await self.connect(config)
                }
            }
        }

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
    nonisolated static func namespaced(server: String, tool: String) -> String {
        "\(slug(for: server))__\(tool)"
    }

    /// The sanitized server slug used as the tool-name namespace. Servers
    /// whose names sanitize to the same slug collide in the registry and are
    /// refused on connect.
    nonisolated static func slug(for server: String) -> String {
        String(server.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .prefix(24))
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
