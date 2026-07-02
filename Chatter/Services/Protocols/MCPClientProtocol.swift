import Foundation

/// A tool discovered on an MCP server, with a client-unique namespaced name so
/// tools from different servers never collide when handed to the model.
struct ResolvedTool: Identifiable, Hashable {
    var id: String { namespacedName }
    let namespacedName: String
    let originalName: String
    let toolDescription: String
    let parameters: JSONValue
    let serverID: UUID
    let serverName: String
}

enum MCPConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(toolCount: Int)
    case failed(String)

    var isConnected: Bool { if case .connected = self { return true }; return false }
}

/// Manages live MCP client sessions and dispatches tool calls.
@MainActor
protocol MCPClientProtocol {
    var states: [UUID: MCPConnectionState] { get }

    /// Connect enabled servers and drop ones no longer present/enabled.
    func syncConnections(configs: [MCPServerConfig]) async

    func connect(_ config: MCPServerConfig) async
    func disconnect(serverID: UUID) async

    /// Tools exposed by the given servers (the agent's allowed set).
    func tools(forServerIDs ids: [UUID]) -> [ResolvedTool]

    /// Run a tool by its namespaced name; returns the textual result.
    func callTool(namespacedName: String, argumentsJSON: String) async throws -> String
}
