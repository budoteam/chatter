import Foundation
import SwiftData

/// Builds the app's SwiftData `ModelContainer`.
///
/// Tries a CloudKit-synced container first so agents, MCP configs, and chat
/// history follow the user across iPhone / iPad / Mac. If the iCloud capability
/// isn't provisioned (e.g. building without a signing team), it transparently
/// falls back to a local-only store so the app still runs.
enum Persistence {
    /// How `makeContainer()` ended up backing the store. Read by
    /// `CloudSyncMonitor` / Settings so a silent fallback to a non-syncing
    /// store is visible in the UI instead of only in the logs.
    enum StoreMode {
        case cloudKit
        case localOnly
        case inMemory
    }

    /// Set by `makeContainer()`; `.inMemory` until it ran.
    private(set) static var storeMode: StoreMode = .inMemory

    static let schema = Schema([
        Agent.self,
        ChatSession.self,
        Message.self,
        Artifact.self,
        MCPServerConfig.self,
        KnowledgeBundle.self,
        KnowledgeConcept.self,
        MemoryEntry.self,
        ReminderEntry.self,
        Skill.self,
        HandoffRequest.self,
    ])

    static func makeContainer() -> ModelContainer {
        #if DEBUG
        // Screenshot/demo runs: seeded in-memory store, never touching the
        // user's data. Settings should still present the production-looking
        // CloudKit state in the captures.
        if ScreenshotDemo.isActive {
            let container = ScreenshotDemo.makeContainer()
            storeMode = .cloudKit
            return container
        }
        #endif

        // Preferred: automatic CloudKit sync.
        let cloudConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        do {
            let container = try ModelContainer(for: schema, configurations: cloudConfig)
            storeMode = .cloudKit
            AppLogger.data.info("SwiftData container ready (CloudKit .automatic)")
            return container
        } catch {
            AppLogger.data.error("CloudKit container failed, falling back to local-only: \(error, privacy: .public)")
        }

        // Fallback: local-only store.
        let localConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: schema, configurations: localConfig)
            storeMode = .localOnly
            AppLogger.data.warning("SwiftData container ready (local only — CloudKit unavailable)")
            return container
        } catch {
            AppLogger.data.error("Local container failed, falling back to in-memory: \(error, privacy: .public)")
        }

        // Last resort: in-memory so the app never crashes on launch.
        let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            let container = try ModelContainer(for: schema, configurations: memoryConfig)
            AppLogger.data.error("SwiftData falling back to in-memory store")
            return container
        } catch {
            // Even the in-memory container failed — the schema itself is
            // broken. Crash with a diagnosable message instead of a bare trap.
            AppLogger.data.fault("In-memory SwiftData container failed: \(error, privacy: .public)")
            preconditionFailure("SwiftData schema cannot be instantiated even in-memory: \(error.localizedDescription)")
        }
    }
}

extension ModelContext {
    /// Best-effort save that logs failures instead of swallowing them
    /// silently (`try? context.save()`): a failed save (validation, CloudKit
    /// quota) used to vanish without a trace, leaving the UI showing state
    /// that was never persisted.
    func saveOrLog() {
        do {
            try save()
        } catch {
            AppLogger.data.error("SwiftData save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
