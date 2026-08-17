import Foundation
import SwiftData

enum MCPTransportKind: String, Codable, CaseIterable, Identifiable {
    case http   // Streamable HTTP (modern MCP transport)
    case sse    // Legacy HTTP+SSE ("/sse" endpoints, supergateway/mcp-proxy)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .http: return "Streamable HTTP"
        case .sse: return "SSE (legacy)"
        }
    }
}

/// User-configured MCP server with `url` + an optional static auth header.
@Model
final class MCPServerConfig {
    var id: UUID = UUID()
    var name: String = "New Server"
    var transportRaw: String = MCPTransportKind.sse.rawValue
    var url: String = ""
    /// Optional static header, e.g. key "Authorization", value "Bearer …".
    var headerKey: String = ""
    var headerValue: String = ""
    /// Legacy fields of the removed stdio transport (local subprocesses,
    /// dropped when distribution moved to App-Store-only sandboxed builds).
    /// Kept so the persisted CloudKit schema stays unchanged; configs synced
    /// from an old build with transportRaw "stdio" decode as `.sse`.
    var command: String = ""
    var argsJSON: String = "[]"
    var enabled: Bool = true
    var createdAt: Date = Date()

    init(
        name: String = "New Server",
        transport: MCPTransportKind = .sse,
        url: String = "",
        enabled: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.transportRaw = transport.rawValue
        self.url = url
        self.enabled = enabled
        self.createdAt = Date()
    }

    var transport: MCPTransportKind {
        get { MCPTransportKind(rawValue: transportRaw) ?? .sse }
        set { transportRaw = newValue.rawValue }
    }
}
