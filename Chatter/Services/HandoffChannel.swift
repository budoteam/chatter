import CloudKit
import Foundation

/// Direct CloudKit access for handoff requests (see SERVER-HANDOFF.md).
///
/// The request records deliberately live OUTSIDE the SwiftData-mirrored
/// schema: mirroring suspends its exports while an iOS app is backgrounded,
/// which is exactly when a request must reach the server. Reads and writes
/// here hit the server immediately. The single-record mutations (claim,
/// heartbeat, complete, markNotified) re-fetch the record (for the current
/// changeTag) and save compare-and-swap (`.ifServerRecordUnchanged`), so two
/// Macs racing a claim or a requester cancelling mid-heartbeat can never
/// corrupt state — the loser just gets a logged failure. Cancel and prune
/// are bulk best-effort patches without per-record CAS (their fields are
/// disjoint from the server's).
enum HandoffChannel {
    /// Plain record type — no `CD_` prefix, not part of the mirrored schema.
    static let recordType = "HandoffRequest"

    private enum Field {
        static let sessionID = "sessionID"
        static let sessionTitle = "sessionTitle"
        static let requestedBy = "requestedBy"
        static let createdAt = "createdAt"
        static let cancelledAt = "cancelledAt"
        static let claimedBy = "claimedBy"
        static let claimedAt = "claimedAt"
        static let completedAt = "completedAt"
        static let preview = "preview"
        static let notifiedAt = "notifiedAt"
    }

    private static let database = CKContainer(identifier: "iCloud.team.budo.chatter").privateCloudDatabase

    // MARK: - Reading

    /// All request records in the private database, across devices. Volume
    /// is tiny (requests are pruned), so a single unfiltered query suffices.
    /// Throws on network / account errors — callers skip their cycle rather
    /// than acting on an empty snapshot (e.g. creating a duplicate request).
    static func fetchAll() async throws -> [HandoffRequest] {
        try await fetchRecords().map(decode)
    }

    private static func fetchRecords() async throws -> [CKRecord] {
        // Predicate on a custom field, not NSPredicate(value: true): the
        // latter needs a queryable index on the system field recordName,
        // which JIT schema creation never sets — custom fields are marked
        // queryable automatically.
        let query = CKQuery(
            recordType: recordType,
            predicate: NSPredicate(format: "createdAt > %@", Date.distantPast as NSDate)
        )
        var records: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        while true {
            let (batch, next): ([(CKRecord.ID, Result<CKRecord, Error>)], CKQueryOperation.Cursor?)
            if let cursor {
                (batch, next) = try await database.records(continuingMatchFrom: cursor)
            } else {
                (batch, next) = try await database.records(matching: query)
            }
            for (_, result) in batch {
                switch result {
                case .success(let record):
                    records.append(record)
                case .failure(let error):
                    AppLogger.data.error("Handoff record fetch failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let next else { return records }
            cursor = next
        }
    }

    // MARK: - Requesting device (iOS)

    /// Publishes a new request.
    static func create(_ request: HandoffRequest) async {
        let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: request.id.uuidString))
        record[Field.sessionID] = request.sessionID.uuidString
        record[Field.sessionTitle] = request.sessionTitle
        record[Field.requestedBy] = request.requestedBy
        record[Field.createdAt] = request.createdAt
        let saved = await save([record], policy: .ifServerRecordUnchanged, atomically: true)
        if !saved.isEmpty {
            AppLogger.data.info("Handoff requested for session \(request.sessionID.uuidString, privacy: .public)")
        }
    }

    /// Withdraws open requests **of this device** (`sessionID` nil = all of
    /// its sessions): the user is back, or the turn finished locally. A
    /// running server turn is unaffected and still reports completion.
    static func cancelOpenRequests(sessionID: UUID? = nil, ownDevice: String = AppSettings.deviceID) async {
        // One retry: a swallowed fetch failure would leave a finished local
        // turn's request open — claimable, i.e. the turn re-runs on a Mac.
        var records: [CKRecord]?
        for _ in 0..<2 {
            if let fetched = try? await fetchRecords() { records = fetched; break }
        }
        guard let records else {
            AppLogger.data.error("Handoff cancel failed: no snapshot")
            return
        }
        let requests = records.map(decode)
        let targets = Set(HandoffCoordinator.cancellableRequests(
            in: requests, ownDevice: ownDevice, sessionID: sessionID
        ).map(\.id))
        guard !targets.isEmpty else { return }
        let now = Date()
        let dirty = zip(records, requests).compactMap { record, request -> CKRecord? in
            guard targets.contains(request.id) else { return nil }
            record[Field.cancelledAt] = now
            return record
        }
        _ = await save(dirty, policy: .changedKeys, atomically: false)
    }

    /// Stamps a completed request after its notification was posted (dedup).
    static func markNotified(_ request: HandoffRequest, at date: Date = .now) async {
        await mutateFresh(request.id) { $0[Field.notifiedAt] = date }
    }

    /// Deletes requests past their retention (completed) or max age (never
    /// claimed). Called from the foreground/push reconciliations.
    static func prune(now: Date = .now) async {
        guard let records = try? await fetchRecords() else { return }
        let requests = records.map(decode)
        let dead = Set(HandoffCoordinator.prunable(in: requests, now: now).map(\.id))
        let ids = zip(records, requests).compactMap { record, request -> CKRecord.ID? in
            dead.contains(request.id) ? record.recordID : nil
        }
        guard !ids.isEmpty else { return }
        do {
            _ = try await database.modifyRecords(saving: [], deleting: ids)
        } catch {
            AppLogger.data.error("Handoff prune failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Server (macOS)

    /// Compare-and-swap claim: re-fetches the record, re-checks it against
    /// the just-fetched state (the poll snapshot may be stale), and saves
    /// only if nobody touched it in between. Returns the updated request,
    /// or nil when the race was lost or the request vanished.
    static func claim(_ request: HandoffRequest, by device: String, at date: Date = .now) async -> HandoffRequest? {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: request.id.uuidString))
            let fresh = decode(record)
            guard HandoffCoordinator.isOpen(fresh),
                  fresh.claimedBy.isEmpty
                    || date.timeIntervalSince(fresh.claimedAt ?? fresh.createdAt) > HandoffCoordinator.staleClaim
            else { return nil }
            record[Field.claimedBy] = device
            record[Field.claimedAt] = date
            guard let saved = await save([record], policy: .ifServerRecordUnchanged, atomically: true).first
            else { return nil }
            AppLogger.data.info("Handoff claimed for session \(request.sessionID.uuidString, privacy: .public)")
            return decode(saved)
        } catch {
            AppLogger.data.error("Handoff claim failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Heartbeat against stale-claim takeovers while the server turn runs.
    static func refreshClaim(_ request: HandoffRequest, at date: Date = .now) async -> HandoffRequest {
        await mutateFresh(request.id) { $0[Field.claimedAt] = date } ?? request
    }

    /// Reports the finished server turn — successfully or not; `preview`
    /// carries the answer preview or the failure note. One retry: the only
    /// expected conflict is the requester's concurrent cancel, and the
    /// completion must still land so the notification sweep can fire.
    static func complete(_ request: HandoffRequest, preview: String, at date: Date = .now) async {
        for _ in 0..<2 {
            let updated = await mutateFresh(request.id) { record in
                record[Field.completedAt] = date
                record[Field.preview] = preview
            }
            if updated != nil { return }
        }
    }

    // MARK: - Push subscription (iOS)

    #if os(iOS)
    /// One-time CloudKit subscription so a server claiming/finishing a
    /// handoff wakes this device with a silent push (the app then stops its
    /// local turn or posts the completion notification). Best-effort:
    /// without it, everything is picked up on the next foreground instead.
    static func ensurePushSubscription() {
        let createdKey = "handoffPushSubscription.v2"
        guard !UserDefaults.standard.bool(forKey: createdKey) else { return }
        Task {
            // v1 watched the removed SwiftData-mirrored record type.
            try? await database.deleteSubscription(withID: "handoff-requests")
            let subscription = CKQuerySubscription(
                recordType: recordType,
                predicate: NSPredicate(value: true),
                subscriptionID: "handoff-requests-v2",
                options: [.firesOnRecordCreation, .firesOnRecordUpdate]
            )
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            do {
                _ = try await database.save(subscription)
                UserDefaults.standard.set(true, forKey: createdKey)
            } catch {
                // Retry next launch (flag stays unset).
                AppLogger.data.error("Handoff push subscription failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    #endif

    // MARK: - Mapping

    static func decode(_ record: CKRecord) -> HandoffRequest {
        HandoffRequest(
            id: UUID(uuidString: record.recordID.recordName) ?? UUID(),
            sessionID: UUID(uuidString: record[Field.sessionID] as? String ?? "") ?? UUID(),
            requestedBy: record[Field.requestedBy] as? String ?? "",
            sessionTitle: record[Field.sessionTitle] as? String ?? "",
            createdAt: record[Field.createdAt] as? Date ?? record.creationDate ?? .distantPast,
            cancelledAt: record[Field.cancelledAt] as? Date,
            claimedBy: record[Field.claimedBy] as? String ?? "",
            claimedAt: record[Field.claimedAt] as? Date,
            completedAt: record[Field.completedAt] as? Date,
            preview: record[Field.preview] as? String ?? "",
            notifiedAt: record[Field.notifiedAt] as? Date
        )
    }

    /// Re-fetches a record (for the current changeTag), applies `mutate`,
    /// saves compare-and-swap and returns the updated request — nil when
    /// the record is gone or the save lost a race.
    @discardableResult
    private static func mutateFresh(
        _ id: UUID, _ mutate: (CKRecord) -> Void
    ) async -> HandoffRequest? {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: id.uuidString))
            mutate(record)
            guard let saved = await save([record], policy: .ifServerRecordUnchanged, atomically: true).first
            else { return nil }
            return decode(saved)
        } catch let error as CKError where error.code == .unknownItem {
            return nil // pruned meanwhile
        } catch {
            AppLogger.data.error("Handoff update failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Batch save returning the server records; per-record failures (e.g. a
    /// lost compare-and-swap) are logged and dropped from the result.
    private static func save(
        _ records: [CKRecord],
        policy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async -> [CKRecord] {
        guard !records.isEmpty else { return [] }
        do {
            let (results, _) = try await database.modifyRecords(
                saving: records, deleting: [], savePolicy: policy, atomically: atomically
            )
            var saved: [CKRecord] = []
            for (recordID, result) in results {
                switch result {
                case .success(let record):
                    saved.append(record)
                case .failure(let error):
                    AppLogger.data.error("Handoff save failed for \(recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            return saved
        } catch {
            AppLogger.data.error("Handoff save failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
