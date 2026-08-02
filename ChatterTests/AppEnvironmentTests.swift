import XCTest
@testable import Chatter

@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testPendingNewSessionSurvivesUntilConsumed() {
        let env = AppEnvironment()
        XCTAssertFalse(env.takePendingNewSession(), "fresh env has nothing pending")
        env.requestNewSession()
        XCTAssertTrue(env.takePendingNewSession(), "request while no view exists stays pending")
        XCTAssertFalse(env.takePendingNewSession(), "consumed exactly once")
        env.requestNewSession()
        _ = env.takePendingNewSession()
        env.requestNewSession()
        XCTAssertTrue(env.takePendingNewSession(), "a later request re-arms the flag")
    }
}
