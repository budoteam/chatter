import Foundation
import SwiftData

/// Builds the app's SwiftData `ModelContainer`.
///
/// Tries a CloudKit-synced container first so agents, MCP configs, and chat
/// history follow the user across iPhone / iPad / Mac. If the iCloud capability
/// isn't provisioned (e.g. building without a signing team), it transparently
/// falls back to a local-only store so the app still runs.
enum Persistence {
    static let schema = Schema([
        Agent.self,
        ChatSession.self,
        Message.self,
        MCPServerConfig.self,
        KnowledgeBundle.self,
        KnowledgeConcept.self,
        MemoryEntry.self,
        Skill.self,
    ])

    static func makeContainer() -> ModelContainer {
        // Preferred: automatic CloudKit sync.
        let cloudConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        if let container = try? ModelContainer(for: schema, configurations: cloudConfig) {
            AppLogger.data.info("SwiftData container ready (CloudKit .automatic)")
            return container
        }

        // Fallback: local-only store.
        let localConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        if let container = try? ModelContainer(for: schema, configurations: localConfig) {
            AppLogger.data.warning("SwiftData container ready (local only — CloudKit unavailable)")
            return container
        }

        // Last resort: in-memory so the app never crashes on launch.
        let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        let container = try! ModelContainer(for: schema, configurations: memoryConfig)
        AppLogger.data.error("SwiftData falling back to in-memory store")
        return container
    }
}
