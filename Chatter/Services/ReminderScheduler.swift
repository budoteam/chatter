import Foundation
import SwiftData
import UserNotifications

/// Schedules local system notifications for `ReminderEntry`s via
/// UNUserNotificationCenter (available on iOS / macOS / watchOS).
///
/// Scheduling is per device: the entry itself syncs via CloudKit, and
/// `reconcile(context:)` — called at app launch — makes each device schedule
/// its own notification for every open future reminder, so a reminder created
/// on the iPhone also fires on the Mac and Watch. Identifiers are
/// deterministic (`reminder-<uuid>`), which keeps repeated reconciliation
/// idempotent.
///
/// Deliberately thin and free of business logic so the testable parts live in
/// `ReminderToolProvider` / the action runner (UNUserNotificationCenter is not
/// meaningfully testable in the hosted test runner).
@MainActor
enum ReminderScheduler {
    private static let identifierPrefix = "reminder-"

    private static var center: UNUserNotificationCenter { .current() }

    static func identifier(for entryID: UUID) -> String {
        identifierPrefix + entryID.uuidString
    }

    /// Schedules the notification for an entry, requesting authorization first
    /// if needed. A denied or failed schedule only means no notification — the
    /// reminder still exists and shows up in the system prompt.
    static func schedule(_ entry: ReminderEntry) async {
        guard await ensureAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Chatter Reminder"
        content.body = entry.content
        content.sound = .default
        content.userInfo = ["reminderID": entry.id.uuidString]

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: entry.dueDate
            ),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: identifier(for: entry.id),
            content: content,
            trigger: trigger
        )
        do {
            // Adding with an existing identifier replaces the pending request,
            // so re-scheduling after edits or on other devices is safe.
            try await center.add(request)
        } catch {
            AppLogger.data.error("Reminder notification schedule failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func cancel(_ entryID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier(for: entryID)])
    }

    /// Reconciles scheduled notifications with the store: drops pending
    /// requests whose reminder is gone or done, and schedules every open
    /// future reminder (e.g. one that arrived via CloudKit on this device).
    static func reconcile(context: ModelContext) async {
        let now = Date()
        let descriptor = FetchDescriptor<ReminderEntry>(
            predicate: #Predicate { !$0.isCompleted && $0.dueDate > now }
        )
        let open = (try? context.fetch(descriptor)) ?? []

        let requests = await center.pendingNotificationRequests()
        let openIDs = Set(open.map { identifier(for: $0.id) })
        let stale = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) && !openIDs.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        let scheduled = Set(requests.map(\.identifier))
        for entry in open where !scheduled.contains(identifier(for: entry.id)) {
            await schedule(entry)
        }
    }

    /// Asks for notification permission on first use; returns whether
    /// scheduling is allowed (authorized or provisional).
    @discardableResult
    static func ensureAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                AppLogger.data.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
