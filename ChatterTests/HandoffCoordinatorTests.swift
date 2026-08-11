import SwiftData
import XCTest
@testable import Chatter

/// Claim/eligibility rules for the CloudKit handoff (SERVER-HANDOFF.md).
final class HandoffCoordinatorTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        // Tests run hosted in the app process: an in-memory store must opt
        // out of CloudKit explicitly, otherwise the first save crashes with
        // "No eligible connection available".
        container = try ModelContainer(
            for: Schema([HandoffRequest.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    @MainActor
    private func makeRequest(age: TimeInterval = 90) -> HandoffRequest {
        let request = HandoffRequest(sessionID: UUID(), sessionTitle: "Test")
        request.createdAt = Date(timeIntervalSinceNow: -age)
        container.mainContext.insert(request)
        return request
    }

    // MARK: - isEligibleForClaim

    @MainActor
    func testFreshRequestIsInsideGracePeriod() {
        let request = makeRequest(age: HandoffCoordinator.claimGrace - 1)
        XCTAssertFalse(HandoffCoordinator.isEligibleForClaim(request))
    }

    @MainActor
    func testUnclaimedRequestPastGraceIsEligible() {
        let request = makeRequest(age: HandoffCoordinator.claimGrace + 1)
        XCTAssertTrue(HandoffCoordinator.isEligibleForClaim(request))
    }

    @MainActor
    func testCancelledRequestIsNotEligible() {
        let request = makeRequest()
        request.cancelledAt = .now
        XCTAssertFalse(HandoffCoordinator.isEligibleForClaim(request))
    }

    @MainActor
    func testCompletedRequestIsNotEligible() {
        let request = makeRequest()
        request.completedAt = .now
        XCTAssertFalse(HandoffCoordinator.isEligibleForClaim(request))
    }

    @MainActor
    func testLiveClaimBlocksOtherServers() {
        let request = makeRequest()
        request.claimedBy = "other-mac"
        request.claimedAt = Date(timeIntervalSinceNow: -60)
        XCTAssertFalse(HandoffCoordinator.isEligibleForClaim(request))
    }

    @MainActor
    func testStaleClaimCanBeTakenOver() {
        let request = makeRequest()
        request.claimedBy = "crashed-mac"
        request.claimedAt = Date(timeIntervalSinceNow: -(HandoffCoordinator.staleClaim + 1))
        XCTAssertTrue(HandoffCoordinator.isEligibleForClaim(request))
    }

    @MainActor
    func testRequestOlderThanMaxAgeIsDead() {
        let request = makeRequest(age: HandoffCoordinator.maxAge + 1)
        XCTAssertFalse(HandoffCoordinator.isEligibleForClaim(request))
    }

    // MARK: - Query helpers

    @MainActor
    func testCancelOpenRequestsOnlyTouchesOpenOnes() throws {
        let context = container.mainContext
        let open = makeRequest()
        let claimed = makeRequest()
        claimed.claimedBy = "some-mac"
        claimed.claimedAt = .now
        let done = makeRequest()
        done.completedAt = .now

        HandoffCoordinator.cancelOpenRequests(context: context)

        XCTAssertNotNil(open.cancelledAt)
        XCTAssertNotNil(claimed.cancelledAt, "claimed-but-unfinished is withdrawn too; the server still reports completion")
        XCTAssertNil(done.cancelledAt, "completed requests stay untouched")
    }

    @MainActor
    func testCancelOpenRequestsScopedToSession() throws {
        let context = container.mainContext
        let target = makeRequest()
        let other = makeRequest()

        HandoffCoordinator.cancelOpenRequests(sessionID: target.sessionID, context: context)

        XCTAssertNotNil(target.cancelledAt)
        XCTAssertNil(other.cancelledAt)
    }

    @MainActor
    func testCompletedUnnotifiedSkipsNotifiedAndOpen() throws {
        let context = container.mainContext
        let pending = makeRequest()
        _ = pending
        let notified = makeRequest()
        notified.completedAt = .now
        notified.notifiedAt = .now
        let fresh = makeRequest()
        fresh.completedAt = .now

        let results = HandoffCoordinator.completedUnnotified(context: context)
        XCTAssertEqual(results.map(\.id), [fresh.id])
    }

    @MainActor
    func testCancelOpenRequestsLeavesOtherDevicesUntouched() throws {
        let context = container.mainContext
        let own = makeRequest()
        let foreign = makeRequest()
        foreign.requestedBy = "another-device"

        HandoffCoordinator.cancelOpenRequests(context: context)

        XCTAssertNotNil(own.cancelledAt)
        XCTAssertNil(foreign.cancelledAt, "withdrawal only touches this device's own requests")
    }

    @MainActor
    func testRequestStampsRequestingDevice() {
        let request = makeRequest()
        XCTAssertEqual(request.requestedBy, AppSettings.deviceID)
    }

    @MainActor
    func testPruneDeletesOnlyExpiredRequests() throws {
        let context = container.mainContext
        let oldCompleted = makeRequest()
        oldCompleted.completedAt = Date(timeIntervalSinceNow: -(HandoffCoordinator.completedRetention + 1))
        let deadUnclaimed = makeRequest(age: HandoffCoordinator.maxAge + 1)
        let alive = makeRequest()
        let recentlyCompleted = makeRequest()
        recentlyCompleted.completedAt = .now

        HandoffCoordinator.prune(context: context)

        let remaining = try context.fetch(FetchDescriptor<HandoffRequest>()).map(\.id)
        XCTAssertEqual(Set(remaining), Set([alive.id, recentlyCompleted.id]))
    }
}
