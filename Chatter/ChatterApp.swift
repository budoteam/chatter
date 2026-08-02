import SwiftUI
import SwiftData

#if os(macOS)
/// WindowGroup identifier for the single main window; reopening it after close
/// (Window menu item, dock click) goes through `openWindow(id:)`.
private let mainWindowID = "main"

/// macOS keeps the app running without windows. `openWindow` is only reachable
/// from the SwiftUI environment, so the reopen paths (Window menu, dock click)
/// go through this box. `window` is the live main window, captured by
/// `WindowCapture`: reopening brings it to the front instead of calling
/// `openWindow(id:)`, which on a WindowGroup would stack a duplicate window.
@MainActor
private enum MainWindowReopen {
    static weak var window: NSWindow?
    static var open: () -> Void = {}

    static func reopen() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open()
        }
    }
}

/// Grabs the NSWindow of the main scene so `MainWindowReopen` can find it
/// again to bring it to the front. Closed windows are released, so the weak
/// reference clears itself and the next reopen creates a fresh window.
private struct WindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { MainWindowReopen.window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        MainWindowReopen.window = nsView.window
    }
}

/// SwiftUI WindowGroups don't reopen on dock click by themselves.
private final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Task { @MainActor in MainWindowReopen.reopen() }
            // We reopen the window ourselves; returning true would let
            // AppKit's default reopen create a second one.
            return false
        }
        return true
    }
}
#endif

@main
struct ChatterApp: App {
    /// Shared SwiftData container (CloudKit-backed when the iCloud capability is
    /// available, local-only otherwise). Created once for the app lifetime.
    let modelContainer: ModelContainer = Persistence.makeContainer()

    @State private var environment = AppEnvironment()

    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup(id: mainWindowID) {
            RootView()
                .environment(environment)
                .tint(Theme.accent)
                .background(WindowCapture())
                .onAppear { MainWindowReopen.open = { openWindow(id: mainWindowID) } }
        }
        .modelContainer(modelContainer)
        .commands { appCommands }

        Settings {
            SettingsView()
                .environment(environment)
                .modelContainer(modelContainer)
                .frame(width: 620, height: 520)
        }
        #else
        WindowGroup {
            RootView()
                .environment(environment)
                .tint(Theme.accent)
        }
        .modelContainer(modelContainer)
        .commands { appCommands }
        #endif
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                #if os(macOS)
                // With the main window closed the request would otherwise be
                // invisible: reopen first; the fresh RootView consumes the
                // pending request from its .task.
                MainWindowReopen.reopen()
                #endif
                environment.requestNewSession()
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        #if os(macOS)
        // App Review guideline 4: the main window must be reopenable after
        // it was closed. Lives in the standard Window menu.
        CommandGroup(before: .windowArrangement) {
            Button("Chatter") { MainWindowReopen.reopen() }
                .keyboardShortcut("0", modifiers: .command)
        }
        #endif
    }
}
