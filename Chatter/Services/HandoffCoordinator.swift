import Foundation
import SwiftData
#if os(iOS)
import CloudKit
#endif

/// Shared handoff decision logic (see SERVER-HANDOFF.md): which request a
/// server may claim, and the small query helpers both sides use. Kept free
/// of platform APIs so the rules are unit-testable; the iOS push
/// subscription is the only platform-specific piece.
enum HandoffCoordinator {
    /// The requesting device gets this head start — its own background task
    /// (`TurnRuntimeKeeper`) usually finishes the turn within this window.
    static let claimGrace: TimeInterval = 60
    /// Requests older than this are dead: the requesting device is long gone
    /// and the turn's context is stale.
    static let maxAge: TimeInterval = 2 * 60 * 60
    /// A claim without a heartbeat newer than this counts as a crashed
    /// server and may be taken over by another Mac.
    static let staleClaim: TimeInterval = 5 * 60
    /// Completed requests are kept this long for the notification sweep,
    /// then pruned.
    static let completedRetention: TimeInterval = 24 * 60 * 60

    /// Whether a server may claim this request right now.
    static func isEligibleForClaim(_ request: HandoffRequest, now: Date = .now) -> Bool {
        guard request.cancelledAt == nil, request.completedAt == nil else { return false }
        let age = now.timeIntervalSince(request.createdAt)
        guard age >= claimGrace, age <= maxAge else { return false }
        // A live claim blocks other servers; a stale one is abandoned.
        if !request.claimedBy.isEmpty,
           now.timeIntervalSince(request.claimedAt ?? request.createdAt) <= staleClaim {
            return false
        }
        return true
    }

    /// The open request (neither cancelled nor completed) for a session, if
    /// any — a claimed one still counts as open.
    static func openRequest(for sessionID: UUID, context: ModelContext) -> HandoffRequest? {
        var descriptor = FetchDescriptor<HandoffRequest>(
            predicate: #Predicate {
                $0.sessionID == sessionID && $0.cancelledAt == nil && $0.completedAt == nil
            }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The session's open request if a server has claimed it (iOS uses this
    /// to stop its local copy of the turn).
    static func claimedRequest(for sessionID: UUID, context: ModelContext) -> HandoffRequest? {
        guard let open = openRequest(for: sessionID, context: context),
              !open.claimedBy.isEmpty else { return nil }
        return open
    }

    /// Withdraws open requests **of this device** — the user is back, or the
    /// turn finished locally. `sessionID` nil = all of this device's
    /// sessions. Claimed-but-unfinished requests are cancelled too; the
    /// running server is unaffected and still reports completion. Requests
    /// created by the account's other devices stay untouched.
    static func cancelOpenRequests(sessionID: UUID? = nil, context: ModelContext) {
        let ownDevice = AppSettings.deviceID
        let requests = (try? context.fetch(FetchDescriptor<HandoffRequest>())) ?? []
        var changed = false
        for request in requests
        where request.cancelledAt == nil && request.completedAt == nil
            && request.requestedBy == ownDevice
            && (sessionID == nil || request.sessionID == sessionID) {
            request.cancelledAt = .now
            changed = true
        }
        if changed { context.saveOrLog() }
    }

    /// Completed requests no device has notified about yet.
    static func completedUnnotified(context: ModelContext) -> [HandoffRequest] {
        let descriptor = FetchDescriptor<HandoffRequest>(
            predicate: #Predicate { $0.completedAt != nil && $0.notifiedAt == nil }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Deletes requests past their retention (completed) or max age (never
    /// claimed). Called from the foreground/push reconciliations.
    static func prune(context: ModelContext, now: Date = .now) {
        let requests = (try? context.fetch(FetchDescriptor<HandoffRequest>())) ?? []
        var changed = false
        for request in requests {
            let completedLongAgo = request.completedAt
                .map { now.timeIntervalSince($0) > completedRetention } ?? false
            let neverPickedUp = request.completedAt == nil
                && now.timeIntervalSince(request.createdAt) > maxAge
            if completedLongAgo || neverPickedUp {
                context.delete(request)
                changed = true
            }
        }
        if changed { context.saveOrLog() }
    }

    #if os(iOS)
    /// One-time CloudKit subscription so a server finishing a handoff wakes
    /// this device with a silent push (the app then posts the local
    /// completion notification). SwiftData-mirrored record types carry the
    /// `CD_` prefix. Best-effort: without it, completions are picked up on
    /// the next foreground instead — the data itself syncs regardless.
    static func ensurePushSubscription() {
        let createdKey = "handoffPushSubscription.v1"
        guard !UserDefaults.standard.bool(forKey: createdKey) else { return }
        let subscription = CKQuerySubscription(
            recordType: "CD_HandoffRequest",
            predicate: NSPredicate(value: true),
            subscriptionID: "handoff-requests",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        CKContainer(identifier: "iCloud.team.budo.chatter").privateCloudDatabase
            .save(subscription) { _, error in
                if let error {
                    // Retry next launch (flag stays unset).
                    AppLogger.data.error("Handoff push subscription failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    UserDefaults.standard.set(true, forKey: createdKey)
                }
            }
    }
    #endif
}
