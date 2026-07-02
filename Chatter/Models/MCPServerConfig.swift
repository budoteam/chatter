import Foundation
import SwiftData

enum MCPTransportKind: String, Codable, CaseIterable, Identifiable {
    case http   // Streamable HTTP (request/response, optional SSE off)
    case sse    // Streamable HTTP with Server-Sent Events streaming
    case stdio  // Local subprocess (macOS only)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .http: return "HTTP"
        case .sse: return "SSE"
        case .stdio: return "stdio (local)"
        }
    }

    var isRemote: Bool { self == .http || self == .sse }
}

/// User-configured MCP server. Remote servers use `url` + an optional static
/// auth header; stdio servers (macOS) launch `command` with `args`.
@Model
final class MCPServerConfig {
    var id: UUID = UUID()
    var name: String = "New Server"
    var transportRaw: String = MCPTransportKind.sse.rawValue
    var url: String = ""
    /// Optional static header, e.g. key "Authorization", value "Bearer …".
    var headerKey: String = ""
    var headerValue: String = ""
    /// stdio: executable path and arguments (JSON-encoded array).
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

    var args: [String] {
        get {
            guard let data = argsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                argsJSON = json
            }
        }
    }
}
