import Foundation

/// One handoff request — a device running a turn asks any Mac of the same
/// iCloud account to take it over (see SERVER-HANDOFF.md).
///
/// Value-type mirror of the CloudKit record (`HandoffChannel.recordType`).
/// NOT a SwiftData model: the SwiftData/CloudKit mirroring suspends its
/// exports while an iOS app is backgrounded — exactly when the request must
/// reach the server — so the record lives outside the mirrored schema and
/// travels through direct CloudKit reads/writes (`HandoffChannel`).
///
/// Lifecycle: created by the requesting device when the app backgrounds with
/// a live turn → claimed by a Mac (`claimedBy`/`claimedAt`, refreshed as a
/// heartbeat while the turn runs) → `completedAt` + `preview` set when done.
/// The requesting device sets `cancelledAt` when the user returns (the local
/// turn continues) or when the turn finished locally. Old records are pruned
/// by `HandoffCoordinator.prunable`.
struct HandoffRequest: Equatable {
    /// UUID, doubles as the CloudKit record name.
    var id: UUID
    /// Session the turn belongs to, referenced by ID (same convention as
    /// `ReminderEntry.agentID` — no relationship, dangling refs harmless).
    var sessionID: UUID
    /// `AppSettings.deviceID` of the requesting device — withdrawal
    /// (`cancelledAt`) only ever touches the creator's own requests.
    var requestedBy: String
    /// Snapshot for the completion notification (session may be renamed).
    var sessionTitle: String
    var createdAt: Date
    /// Set by the requesting device: user returned, or turn finished locally.
    var cancelledAt: Date?
    /// Claiming server's `AppSettings.deviceID`; empty = unclaimed.
    var claimedBy: String
    /// Claim time, refreshed every minute while the server turn runs
    /// (heartbeat — a stale claim counts as a crashed server).
    var claimedAt: Date?
    /// Set when the server finished, successfully or not; `preview` carries
    /// the answer preview or the failure note.
    var completedAt: Date?
    var preview: String
    /// Set once a device posted the completion notification (dedup).
    var notifiedAt: Date?

    /// The user message this turn answers, carried in the record itself:
    /// the requesting phone's SwiftData export pauses in the background, so
    /// the server cannot rely on the message having synced — without these,
    /// a claimed turn would re-answer the last SYNCED user message instead.
    /// nil/empty on records from older clients (server falls back to
    /// `regenerate`). Prompts with image attachments never get a request —
    /// images cannot travel in the record.
    var promptMessageID: UUID?
    var promptText: String
    var promptOrderIndex: Int

    init(sessionID: UUID, sessionTitle: String) {
        id = UUID()
        self.sessionID = sessionID
        requestedBy = AppSettings.deviceID
        self.sessionTitle = sessionTitle
        createdAt = Date()
        cancelledAt = nil
        claimedBy = ""
        claimedAt = nil
        completedAt = nil
        preview = ""
        notifiedAt = nil
        promptMessageID = nil
        promptText = ""
        promptOrderIndex = 0
    }

    /// Memberwise init for `HandoffChannel`'s record decoder and tests.
    init(
        id: UUID, sessionID: UUID, requestedBy: String, sessionTitle: String,
        createdAt: Date, cancelledAt: Date? = nil, claimedBy: String = "",
        claimedAt: Date? = nil, completedAt: Date? = nil, preview: String = "",
        notifiedAt: Date? = nil, promptMessageID: UUID? = nil,
        promptText: String = "", promptOrderIndex: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.requestedBy = requestedBy
        self.sessionTitle = sessionTitle
        self.createdAt = createdAt
        self.cancelledAt = cancelledAt
        self.claimedBy = claimedBy
        self.claimedAt = claimedAt
        self.completedAt = completedAt
        self.preview = preview
        self.notifiedAt = notifiedAt
        self.promptMessageID = promptMessageID
        self.promptText = promptText
        self.promptOrderIndex = promptOrderIndex
    }
}

/// Shared handoff decision logic (see SERVER-HANDOFF.md): which request a
/// server may claim, and the small filters both sides apply to fetched
/// requests. Kept free of platform and persistence APIs so the rules are
/// unit-testable; all CloudKit I/O lives in `HandoffChannel`.
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
        guard isOpen(request) else { return false }
        let age = now.timeIntervalSince(request.createdAt)
        guard age >= claimGrace, age <= maxAge else { return false }
        // A live claim blocks other servers; a stale one is abandoned.
        if !request.claimedBy.isEmpty,
           now.timeIntervalSince(request.claimedAt ?? request.createdAt) <= staleClaim {
            return false
        }
        return true
    }

    /// Whether another request for the same session proves this one a stale
    /// duplicate: it was completed after `request` was created, or a live
    /// claim is already working the session. Duplicates arise when the
    /// requesting device loses its in-memory dedup (process kill between
    /// two backgroundings); the server skips them and lets them age out —
    /// claiming one would re-run an already-finished turn.
    static func isStaleDuplicate(
        _ request: HandoffRequest, in requests: [HandoffRequest], now: Date = .now
    ) -> Bool {
        requests.contains { other in
            guard other.id != request.id, other.sessionID == request.sessionID else { return false }
            if let completed = other.completedAt, completed >= request.createdAt { return true }
            if isOpen(other), !other.claimedBy.isEmpty,
               now.timeIntervalSince(other.claimedAt ?? other.createdAt) <= staleClaim { return true }
            return false
        }
    }

    /// Neither cancelled nor completed — a claimed one still counts as open.
    static func isOpen(_ request: HandoffRequest) -> Bool {
        request.cancelledAt == nil && request.completedAt == nil
    }

    /// The open request for a session, if any.
    static func openRequest(for sessionID: UUID, in requests: [HandoffRequest]) -> HandoffRequest? {
        requests.first { $0.sessionID == sessionID && isOpen($0) }
    }

    /// The session's open request if a server has claimed it (iOS uses this
    /// to stop its local copy of the turn).
    static func claimedRequest(for sessionID: UUID, in requests: [HandoffRequest]) -> HandoffRequest? {
        guard let open = openRequest(for: sessionID, in: requests),
              !open.claimedBy.isEmpty else { return nil }
        return open
    }

    /// Open requests **of this device** that a withdrawal would cancel — the
    /// user is back, or the turn finished locally. `sessionID` nil = all of
    /// this device's sessions. Claimed-but-unfinished requests are included;
    /// the running server is unaffected and still reports completion.
    /// Requests created by the account's other devices stay untouched.
    static func cancellableRequests(
        in requests: [HandoffRequest], ownDevice: String, sessionID: UUID? = nil
    ) -> [HandoffRequest] {
        requests.filter {
            isOpen($0) && $0.requestedBy == ownDevice
                && (sessionID == nil || $0.sessionID == sessionID)
        }
    }

    /// Completed requests no device has notified about yet.
    static func completedUnnotified(in requests: [HandoffRequest]) -> [HandoffRequest] {
        requests.filter { $0.completedAt != nil && $0.notifiedAt == nil }
    }

    /// Requests past their retention (completed) or max age (never claimed).
    static func prunable(in requests: [HandoffRequest], now: Date = .now) -> [HandoffRequest] {
        requests.filter { request in
            let completedLongAgo = request.completedAt
                .map { now.timeIntervalSince($0) > completedRetention } ?? false
            let neverPickedUp = request.completedAt == nil
                && now.timeIntervalSince(request.createdAt) > maxAge
            return completedLongAgo || neverPickedUp
        }
    }
}
