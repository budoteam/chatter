import SwiftUI
import SwiftData

/// watchOS entry point. Shares the SwiftData container (CloudKit), models,
/// and services with the iOS/macOS app — agents, MCP servers, and chat
/// history arrive via sync, so there is intentionally no settings UI here.
@main
struct ChatterWatchApp: App {
    let modelContainer: ModelContainer = Persistence.makeContainer()

    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(environment)
                .tint(Theme.accent)
        }
        .modelContainer(modelContainer)
    }
}
