import CloudKit
import XCTest
@testable import Chatter

/// Claim/eligibility rules for the CloudKit handoff (SERVER-HANDOFF.md).
/// The rules are pure filters over `HandoffRequest` values; all CloudKit
/// I/O lives in `HandoffChannel` and is not unit-tested.
final class HandoffCoordinatorTests: XCTestCase {
    private func makeRequest(age: TimeInterval = 90) -> HandoffRequest {
        var request = HandoffRequest(sessionID: UUID(), sessionTitle: "Test")
        request.createdAt = Date(timeIntervalSinceNow: -age)
        return request
    }

    // MARK: - isEligibleForClaim

    func testFreshRequestIsInsideGracePeriod() {
        let request = makeRequest(age: HandoffCoordinator.claimGrace - 1)
        XCTAssertFalse(HandoffCoordinator.isEligibleForClaim(request))
    }

    func testUnclaimedRequestPastGraceIsEligible() {
        let request = makeRequest(age: HandoffCoordinator.claimGrace + 1)
        XCTAssertTrue(HandoffCoordinator.isEligibleForClaim(request))
    }

    func testCancelledRequestIsNotEligible() {
        var request = makeRequest()
        request.cancelledAt = .now
        XCTAssertFalse(HandoffCoordinator.isEligibleForClaim(request))
    }

    func testCompletedRequestIsNotEligible() {
        var request = makeRequest()
        request.completedAt = .now
        XCTAssertFalse(HandoffCoordinator.isEligibleForClaim(request))
    }

    func testLiveClaimBlocksOtherServers() {
        var request = makeRequest()
        request.claimedBy = "other-mac"
        request.claimedAt = Date(timeIntervalSinceNow: -60)
        XCTAssertFalse(HandoffCoordinator.isEligibleForClaim(request))
    }

    func testStaleClaimCanBeTakenOver() {
        var request = makeRequest()
        request.claimedBy = "crashed-mac"
        request.claimedAt = Date(timeIntervalSinceNow: -(HandoffCoordinator.staleClaim + 1))
        XCTAssertTrue(HandoffCoordinator.isEligibleForClaim(request))
    }

    func testRequestOlderThanMaxAgeIsDead() {
        let request = makeRequest(age: HandoffCoordinator.maxAge + 1)
        XCTAssertFalse(HandoffCoordinator.isEligibleForClaim(request))
    }

    // MARK: - Filters

    func testCancellableRequestsOnlyTouchesOpenOnes() {
        let open = makeRequest()
        var claimed = makeRequest()
        claimed.claimedBy = "some-mac"
        claimed.claimedAt = .now
        var done = makeRequest()
        done.completedAt = .now

        let targets = HandoffCoordinator.cancellableRequests(
            in: [open, claimed, done], ownDevice: AppSettings.deviceID
        ).map(\.id)

        XCTAssertTrue(targets.contains(open.id))
        XCTAssertTrue(targets.contains(claimed.id), "claimed-but-unfinished is withdrawn too; the server still reports completion")
        XCTAssertFalse(targets.contains(done.id), "completed requests stay untouched")
    }

    func testCancellableRequestsScopedToSession() {
        let target = makeRequest()
        let other = makeRequest()

        let targets = HandoffCoordinator.cancellableRequests(
            in: [target, other], ownDevice: AppSettings.deviceID, sessionID: target.sessionID
        ).map(\.id)

        XCTAssertEqual(targets, [target.id])
    }

    func testCancellableRequestsLeavesOtherDevicesUntouched() {
        let own = makeRequest()
        var foreign = makeRequest()
        foreign.requestedBy = "another-device"

        let targets = HandoffCoordinator.cancellableRequests(
            in: [own, foreign], ownDevice: AppSettings.deviceID
        ).map(\.id)

        XCTAssertEqual(targets, [own.id], "withdrawal only touches this device's own requests")
    }

    func testCompletedUnnotifiedSkipsNotifiedAndOpen() {
        let pending = makeRequest()
        var notified = makeRequest()
        notified.completedAt = .now
        notified.notifiedAt = .now
        var fresh = makeRequest()
        fresh.completedAt = .now

        let results = HandoffCoordinator.completedUnnotified(in: [pending, notified, fresh])
        XCTAssertEqual(results.map(\.id), [fresh.id])
    }

    func testRequestStampsRequestingDevice() {
        let request = makeRequest()
        XCTAssertEqual(request.requestedBy, AppSettings.deviceID)
    }

    func testPrunableKeepsOnlyExpiredRequests() {
        var oldCompleted = makeRequest()
        oldCompleted.completedAt = Date(timeIntervalSinceNow: -(HandoffCoordinator.completedRetention + 1))
        let deadUnclaimed = makeRequest(age: HandoffCoordinator.maxAge + 1)
        let alive = makeRequest()
        var recentlyCompleted = makeRequest()
        recentlyCompleted.completedAt = .now

        let prunable = HandoffCoordinator.prunable(
            in: [oldCompleted, deadUnclaimed, alive, recentlyCompleted]
        ).map(\.id)

        XCTAssertEqual(Set(prunable), Set([oldCompleted.id, deadUnclaimed.id]))
    }

    func testClaimedRequestRequiresOpenRequestWithClaim() {
        var claimed = makeRequest()
        claimed.claimedBy = "some-mac"
        var cancelledClaim = makeRequest()
        cancelledClaim.claimedBy = "some-mac"
        cancelledClaim.cancelledAt = .now
        let unclaimed = makeRequest()

        XCTAssertEqual(
            HandoffCoordinator.claimedRequest(for: claimed.sessionID, in: [claimed, cancelledClaim, unclaimed])?.id,
            claimed.id
        )
        XCTAssertNil(HandoffCoordinator.claimedRequest(for: cancelledClaim.sessionID, in: [claimed, cancelledClaim, unclaimed]))
        XCTAssertNil(HandoffCoordinator.claimedRequest(for: unclaimed.sessionID, in: [claimed, cancelledClaim, unclaimed]))
    }

    // MARK: - isStaleDuplicate

    private func makeDuplicate(of request: HandoffRequest, age: TimeInterval = 90) -> HandoffRequest {
        var duplicate = makeRequest(age: age)
        duplicate.sessionID = request.sessionID
        return duplicate
    }

    func testRequestCompletedAfterCreationMarksDuplicate() {
        let original = makeRequest()
        var completed = makeDuplicate(of: original)
        completed.completedAt = .now
        XCTAssertTrue(HandoffCoordinator.isStaleDuplicate(original, in: [original, completed]))
    }

    func testRequestCompletedBeforeCreationIsNoDuplicate() {
        // A follow-up turn in the same session is legitimate: the previous
        // request completed BEFORE this one was created.
        var completed = makeRequest(age: 300)
        completed.completedAt = Date(timeIntervalSinceNow: -200)
        let followUp = makeDuplicate(of: completed)
        XCTAssertFalse(HandoffCoordinator.isStaleDuplicate(followUp, in: [completed, followUp]))
    }

    func testLiveClaimOnSiblingMarksDuplicate() {
        let original = makeRequest()
        var claimedSibling = makeDuplicate(of: original)
        claimedSibling.claimedBy = "some-mac"
        claimedSibling.claimedAt = .now
        XCTAssertTrue(HandoffCoordinator.isStaleDuplicate(original, in: [original, claimedSibling]))
    }

    func testStaleClaimOnSiblingAllowsTakeover() {
        let original = makeRequest()
        var crashedSibling = makeDuplicate(of: original)
        crashedSibling.claimedBy = "crashed-mac"
        crashedSibling.claimedAt = Date(timeIntervalSinceNow: -(HandoffCoordinator.staleClaim + 1))
        XCTAssertFalse(HandoffCoordinator.isStaleDuplicate(original, in: [original, crashedSibling]))
    }

    func testOtherSessionsAreIgnored() {
        let original = makeRequest()
        var unrelated = makeRequest()
        unrelated.completedAt = .now
        XCTAssertFalse(HandoffCoordinator.isStaleDuplicate(original, in: [original, unrelated]))
    }

    // MARK: - Record mapping

    func testDecodeReadsPromptFields() {
        let promptID = UUID()
        let record = CKRecord(
            recordType: HandoffChannel.recordType,
            recordID: CKRecord.ID(recordName: UUID().uuidString)
        )
        record["sessionID"] = UUID().uuidString
        record["promptMessageID"] = promptID.uuidString
        record["promptText"] = "hello"
        record["promptOrderIndex"] = 7 as NSNumber

        let request = HandoffChannel.decode(record)

        XCTAssertEqual(request.promptMessageID, promptID)
        XCTAssertEqual(request.promptText, "hello")
        XCTAssertEqual(request.promptOrderIndex, 7)
    }

    func testDecodeDefaultsPromptFieldsForLegacyRecords() {
        let record = CKRecord(
            recordType: HandoffChannel.recordType,
            recordID: CKRecord.ID(recordName: UUID().uuidString)
        )
        record["sessionID"] = UUID().uuidString

        let request = HandoffChannel.decode(record)

        XCTAssertNil(request.promptMessageID, "records from older clients carry no prompt")
        XCTAssertEqual(request.promptText, "")
        XCTAssertEqual(request.promptOrderIndex, 0)
    }
}
