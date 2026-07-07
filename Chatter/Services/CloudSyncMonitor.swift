import CoreData
import Foundation

/// Observes CloudKit mirroring activity and keeps the latest state per event
/// type (setup / import / export) so Settings can show whether sync actually
/// works. SwiftData's CloudKit backing posts the same
/// `NSPersistentCloudKitContainer.eventChangedNotification` as Core Data, so
/// a stalled export (e.g. record type missing in the Production schema) is
/// visible in the UI instead of silently losing data.
@MainActor
@Observable
final class CloudSyncMonitor {
    struct EventStatus {
        var startDate: Date?
        var endDate: Date?
        var succeeded = false
        var errorDescription: String?

        /// Started but not finished yet.
        var isRunning: Bool { startDate != nil && endDate == nil }
        /// Whether any event of this type was observed this launch.
        var hasActivity: Bool { startDate != nil }
    }

    private(set) var setup = EventStatus()
    private(set) var imports = EventStatus()
    private(set) var exports = EventStatus()

    /// How the store was created (CloudKit, local fallback, in-memory).
    var storeMode: Persistence.StoreMode { Persistence.storeMode }

    /// `@ObservationIgnored` keeps the `@Observable` macro from wrapping this
    /// in tracked accessors (on which isolation attributes have no effect).
    /// `nonisolated(unsafe)`: written once in `init`, read in nonisolated
    /// `deinit` — no concurrent access.
    @ObservationIgnored nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            // Unpack outside the hop — Event is not Sendable.
            let status = EventStatus(
                startDate: event.startDate,
                endDate: event.endDate,
                succeeded: event.succeeded,
                errorDescription: event.error?.localizedDescription
            )
            let type = event.type
            Task { @MainActor [weak self] in
                self?.apply(type: type, status: status)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func apply(type: NSPersistentCloudKitContainer.EventType, status: EventStatus) {
        let label: String
        switch type {
        case .setup: setup = status; label = "setup"
        case .import: imports = status; label = "import"
        case .export: exports = status; label = "export"
        @unknown default: return
        }
        if let error = status.errorDescription {
            AppLogger.data.error("CloudKit \(label, privacy: .public) failed: \(error, privacy: .public)")
        } else if status.endDate != nil {
            AppLogger.data.debug("CloudKit \(label, privacy: .public) finished")
        }
    }
}
