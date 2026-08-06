import CloudKit
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
                errorDescription: Self.describe(event.error)
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

    /// CloudKit batch failures surface as `CKError.partialFailure`, whose
    /// `localizedDescription` ("CKErrorDomain error 2.") hides the real
    /// per-record errors. Unwrap them so Settings/logs show *why* sync
    /// actually failed — e.g. a record type missing from the Production
    /// schema shows up as the nested `unknownItem` / `serverRejectedRequest`
    /// codes instead of the opaque generic message.
    private static func describe(_ error: Error?) -> String? {
        guard let error else { return nil }
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain,
              nsError.code == CKError.Code.partialFailure.rawValue,
              let partials = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any],
              !partials.isEmpty
        else { return error.localizedDescription }

        // Group by (domain, code) with counts — a stalled export can carry
        // one nested error per record, all identical.
        let counts = partials.values.reduce(into: [String: Int]()) { counts, item in
            let nested = item as? NSError
            let key = nested.map { "\($0.domain) error \($0.code)" } ?? "unknown"
            counts[key, default: 0] += 1
        }
        let summary = counts
            .sorted { $0.key < $1.key }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
        return "partial failure: \(summary)"
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
