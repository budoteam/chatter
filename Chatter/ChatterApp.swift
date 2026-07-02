import SwiftUI
import SwiftData

@main
struct ChatterApp: App {
    /// Shared SwiftData container (CloudKit-backed when the iCloud capability is
    /// available, local-only otherwise). Created once for the app lifetime.
    let modelContainer: ModelContainer = Persistence.makeContainer()

    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .tint(Theme.accent)
        }
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { environment.requestNewSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(environment)
                .modelContainer(modelContainer)
                .frame(width: 620, height: 520)
        }
        #endif
    }
}
