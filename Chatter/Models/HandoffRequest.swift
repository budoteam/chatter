import Foundation
import SwiftData

/// One handoff request — a device running a turn asks any Mac of the same
/// iCloud account to take it over (see SERVER-HANDOFF.md). Synced via
/// CloudKit like the other models; the sync itself is the control channel,
/// so no server pairing or network endpoint exists.
///
/// Lifecycle: created by the requesting device when the app backgrounds with
/// a live turn → claimed by a Mac (`claimedBy`/`claimedAt`, refreshed as a
/// heartbeat while the turn runs) → `completedAt` + `preview` set when done.
/// The requesting device sets `cancelledAt` when the user returns (the local
/// turn continues) or when the turn finished locally. Old records are pruned
/// by `HandoffCoordinator.prune`.
@Model
final class HandoffRequest {
    var id: UUID = UUID()
    /// Session the turn belongs to, referenced by ID (same convention as
    /// `ReminderEntry.agentID` — no relationship, dangling refs harmless).
    var sessionID: UUID = UUID()
    /// `AppSettings.deviceID` of the requesting device — withdrawal
    /// (`cancelledAt`) only ever touches the creator's own requests.
    var requestedBy: String = ""
    /// Snapshot for the completion notification (session may be renamed).
    var sessionTitle: String = ""
    var createdAt: Date = Date()
    /// Set by the requesting device: user returned, or turn finished locally.
    var cancelledAt: Date? = nil
    /// Claiming server's `AppSettings.deviceID`; empty = unclaimed.
    var claimedBy: String = ""
    /// Claim time, refreshed every minute while the server turn runs
    /// (heartbeat — a stale claim counts as a crashed server).
    var claimedAt: Date? = nil
    /// Set when the server finished, successfully or not; `preview` carries
    /// the answer preview or the failure note.
    var completedAt: Date? = nil
    var preview: String = ""
    /// Set once a device posted the completion notification (dedup).
    var notifiedAt: Date? = nil

    init(sessionID: UUID, sessionTitle: String) {
        self.id = UUID()
        self.sessionID = sessionID
        self.requestedBy = AppSettings.deviceID
        self.sessionTitle = sessionTitle
        self.createdAt = Date()
    }
}
