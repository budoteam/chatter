import Foundation
import os

enum AppLogger {
    private static let subsystem = "team.budo.chatter"

    static let api = Logger(subsystem: subsystem, category: "API")
    static let mcp = Logger(subsystem: subsystem, category: "MCP")
    static let chat = Logger(subsystem: subsystem, category: "Chat")
    static let data = Logger(subsystem: subsystem, category: "Data")
    static let ui = Logger(subsystem: subsystem, category: "UI")
}
