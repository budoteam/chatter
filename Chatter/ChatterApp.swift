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

import UserNotifications
#if os(iOS)
import UIKit

/// Registers for remote notifications and routes CloudKit silent pushes
/// (server-side handoff progress, via the `HandoffRequest` subscription)
/// to the app's reconciliation. `onSilentPush` is static because the
/// delegate instance is created by the system through the adaptor, after
/// `ChatterApp.init` has already wired things up.
private final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    static var onSilentPush: () async -> Void = {}

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Silent pushes need registration but no user permission.
        application.registerForRemoteNotifications()
        HandoffChannel.ensurePushSubscription()
        return true
    }

    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await Self.onSilentPush()
        return .newData
    }
}
#endif

/// Notification delegate for reminders: banners also show while the app is in
/// the foreground, and tapping a notification (like a plain launch, see
/// `RootView.task`) runs pending reminder actions.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onResponse: ((UNNotificationResponse) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        onResponse?(response)
    }
}

@main
struct ChatterApp: App {
    /// Shared SwiftData container (CloudKit-backed when the iCloud capability is
    /// available, local-only otherwise). Created once for the app lifetime.
    let modelContainer: ModelContainer

    /// Retained here because `UNUserNotificationCenter.delegate` is weak.
    private let notificationDelegate = NotificationDelegate()

    @State private var environment: AppEnvironment

    #if os(iOS)
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var iosDelegate
    @Environment(\.scenePhase) private var scenePhase
    #endif
    #if os(macOS)
    /// Takes over handoff requests from the user's other devices (always on).
    private let handoffServer: HandoffServer
    #endif

    init() {
        let container = Persistence.makeContainer()
        self.modelContainer = container
        let environment = AppEnvironment()
        self._environment = State(initialValue: environment)
        #if os(macOS)
        self.handoffServer = HandoffServer(environment: environment, context: container.mainContext)
        #endif
        #if os(iOS)
        IOSAppDelegate.onSilentPush = {
            await environment.handleHandoffPush(context: container.mainContext)
        }
        // Missed pushes / requests from a previous run.
        Task { @MainActor in
            await environment.reconcileHandoffsOnActive(context: container.mainContext)
        }
        #endif
        notificationDelegate.onResponse = { response in
            Task { @MainActor in
                // Turn-completion notifications carry the session to open.
                if let raw = response.notification.request.content.userInfo["sessionID"] as? String,
                   let sessionID = UUID(uuidString: raw) {
                    var descriptor = FetchDescriptor<ChatSession>(
                        predicate: #Predicate { $0.id == sessionID }
                    )
                    descriptor.fetchLimit = 1
                    if let session = try? container.mainContext.fetch(descriptor).first {
                        environment.openChat(session)
                    }
                }
                await ReminderScheduler.reconcile(context: container.mainContext)
                environment.runDueReminderActions(context: container.mainContext)
            }
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

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
                #if os(iOS)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        Task { await environment.requestHandoffsForActiveTurns(context: modelContainer.mainContext) }
                        // Arm the continued-processing Live Activity only now
                        // that the app is actually leaving the foreground.
                        TurnRuntimeKeeper.submitContinuedTasksForActiveTurns()
                    case .active:
                        Task { await environment.reconcileHandoffsOnActive(context: modelContainer.mainContext) }
                    default:
                        break
                    }
                }
                #endif
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
