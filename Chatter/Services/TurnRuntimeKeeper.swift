import Foundation
import UserNotifications
#if os(iOS)
import UIKit
import BackgroundTasks
#elseif os(macOS)
import AppKit
#endif

/// Keeps an assistant turn alive when the user leaves the app, and notifies
/// about the finished reply.
///
/// iOS 26+: every turn is submitted as a `BGContinuedProcessingTask` — the
/// system shows a Live Activity (Dynamic Island / Lock Screen) with title,
/// subtitle and progress and lets the user cancel there. On older iOS the
/// classic `beginBackgroundTask` buys ~30 s. In both cases expiry maps to a
/// normal turn cancellation, so partial content stays persisted exactly like
/// a user-initiated stop. If the user kills the app from the app switcher,
/// iOS cancels the task silently — nothing can run then (see SERVER-HANDOFF.md).
///
/// macOS doesn't suspend backgrounded apps, so keeping alive is a no-op
/// there; the completion notification still fires when the app is inactive.
/// watchOS has no such API — the whole keeper compiles to a no-op.
@MainActor
enum TurnRuntimeKeeper {
    #if os(iOS)
    private struct Handle {
        /// `BGContinuedProcessingTask` on iOS 26+ (typed as AnyObject so the
        /// struct compiles regardless of deployment target).
        var continued: AnyObject?
        var legacy: UIBackgroundTaskIdentifier?
        var onExpire: () -> Void
        /// Title/subtitle for the Live Activity, kept so the continued task
        /// can be submitted later (on backgrounding) instead of at turn start.
        var title: String
        var subtitle: String
        /// True once the continued task was submitted — prevents re-submitting
        /// on every background transition.
        var submitted: Bool = false
    }

    private static var handles: [UUID: Handle] = [:]
    /// BGTaskScheduler handlers are registered per exact identifier; the
    /// Info.plist permits the `team.budo.chatter.turn.*` wildcard.
    private static var registeredIdentifiers: Set<String> = []
    #endif

    /// Sessions whose turn was cut short by the system (Live Activity cancel
    /// or background-time expiry) — consumed by the completion notification.
    private static var cutShort: Set<UUID> = []

    /// Arms background keeping for a turn. `onExpire` must cancel the turn;
    /// it fires when the user cancels via the Live Activity or the system
    /// revokes background time.
    ///
    /// The continued-processing task is NOT submitted here: submitting it at
    /// turn start shows the Live Activity banner even while the app is in the
    /// foreground (iPad). It is submitted lazily by
    /// `submitContinuedTasksForActiveTurns` when the app actually backgrounds.
    static func begin(sessionID: UUID, subtitle: String, onExpire: @escaping @MainActor () -> Void) {
        #if os(iOS)
        guard handles[sessionID] == nil else { return }
        let title = "Generating reply"
        handles[sessionID] = Handle(
            continued: nil, legacy: nil, onExpire: onExpire,
            title: title, subtitle: subtitle
        )
        if #available(iOS 26.0, *) {
            // Deferred — see submitContinuedTasksForActiveTurns.
            return
        }
        beginLegacyTask(sessionID: sessionID, name: title)
        #endif
    }

    /// Submits the continued-processing task for every active turn that has
    /// not been submitted yet. Called when the app transitions to the
    /// background, so the Live Activity only appears once the user has
    /// actually left the app — never while it is in the foreground.
    static func submitContinuedTasksForActiveTurns() {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { return }
        for (sessionID, handle) in handles where !handle.submitted {
            if submitContinuedTask(sessionID: sessionID, title: handle.title, subtitle: handle.subtitle) {
                handles[sessionID]?.submitted = true
            } else {
                // Without a fallback the turn would die on suspension: arm
                // the legacy background task instead (same as pre-iOS 26).
                beginLegacyTask(sessionID: sessionID, name: handle.title)
                handles[sessionID]?.submitted = true
            }
        }
        #endif
    }

    /// Feeds the Live Activity: tool rounds are the only meaningful progress
    /// signal a turn has (token counts have no known total).
    static func updateProgress(sessionID: UUID, toolRound: Int, maxRounds: Int) {
        #if os(iOS)
        guard #available(iOS 26.0, *),
              let task = handles[sessionID]?.continued as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = Int64(maxRounds + 1)
        task.progress.completedUnitCount = Int64(min(toolRound, maxRounds))
        task.updateTitle(task.title, subtitle: "Tool round \(toolRound)")
        #endif
    }

    /// Releases the background assertion; safe to call after an expiry.
    static func end(sessionID: UUID) {
        #if os(iOS)
        guard let handle = handles.removeValue(forKey: sessionID) else { return }
        if #available(iOS 26.0, *), let task = handle.continued as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
        }
        if let legacy = handle.legacy, legacy != .invalid {
            UIApplication.shared.endBackgroundTask(legacy)
        }
        #endif
    }

    /// Posts a local notification when a turn finished while the app wasn't
    /// active. Reuses the reminder notification permission; a denied
    /// permission only means no notification. Tap handling (open the chat)
    /// lives in `ChatterApp`'s notification delegate via the `sessionID`
    /// userInfo key.
    static func notifyCompletionIfNeeded(sessionID: UUID, title: String, preview: String) async {
        #if os(iOS)
        // Only a truly backgrounded app warrants a banner. `!= .active` is
        // too eager on iPadOS windowing: a visible but unfocused window is
        // foregroundInactive, so `applicationState` reads .inactive while
        // the user is looking right at the app — banner + sound on screen.
        let inBackground = UIApplication.shared.applicationState == .background
        #elseif os(macOS)
        let inBackground = !NSApplication.shared.isActive
        #else
        let inBackground = false
        #endif
        let wasCutShort = cutShort.remove(sessionID) != nil
        guard inBackground else { return }
        guard await ReminderScheduler.ensureAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = wasCutShort
            ? "Background time ran out — the reply is incomplete."
            : preview
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        // Replacing identifier: only the latest completion per session lingers.
        let request = UNNotificationRequest(
            identifier: "turn-\(sessionID.uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            AppLogger.data.error("Turn completion notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if os(iOS)
    /// Submits the continued-processing task; the launch handler only
    /// *adopts* the task — the turn itself keeps running in the
    /// `AppEnvironment.runTurn` task where it started.
    @available(iOS 26.0, *)
    private static func submitContinuedTask(sessionID: UUID, title: String, subtitle: String) -> Bool {
        let identifier = "team.budo.chatter.turn.\(sessionID.uuidString)"
        if !registeredIdentifiers.contains(identifier) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                Task { @MainActor in
                    TurnRuntimeKeeper.adopt(task: task, sessionID: sessionID)
                }
            }
            registeredIdentifiers.insert(identifier)
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        // Queue rather than fail: a chat reply may wait a moment for resources.
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            AppLogger.data.error("Continued processing submit failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @available(iOS 26.0, *)
    private static func adopt(task: BGTask, sessionID: UUID) {
        guard let task = task as? BGContinuedProcessingTask, var handle = handles[sessionID] else {
            task.setTaskCompleted(success: false)
            return
        }
        handle.continued = task
        handles[sessionID] = handle
        task.expirationHandler = {
            Task { @MainActor in TurnRuntimeKeeper.expire(sessionID: sessionID) }
        }
    }

    private static func beginLegacyTask(sessionID: UUID, name: String) {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in TurnRuntimeKeeper.expire(sessionID: sessionID) }
        }
        guard identifier != .invalid else { return }
        handles[sessionID]?.legacy = identifier
    }

    /// System-imposed end (user cancel in the Live Activity, or time ran
    /// out): report failure, release everything, then cancel the turn.
    private static func expire(sessionID: UUID) {
        guard let handle = handles.removeValue(forKey: sessionID) else { return }
        cutShort.insert(sessionID)
        if #available(iOS 26.0, *), let task = handle.continued as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: false)
        }
        if let legacy = handle.legacy, legacy != .invalid {
            UIApplication.shared.endBackgroundTask(legacy)
        }
        handle.onExpire()
    }
    #endif
}
