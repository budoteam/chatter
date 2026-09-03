import XCTest
@testable import Chatter

/// Decoding of `/api/usage` responses plus the `UsageMonitor` state machine
/// against a stubbed `OllamaServiceProtocol`.
@MainActor
final class UsageMonitorTests: XCTestCase {

    // MARK: - Decoding

    func testDecodesFullResponse() throws {
        let json = """
        {
          "activity": {
            "cost": "12.34",
            "models": [
              { "name": "gpt-oss:120b", "request_count": 10, "cost": "2.50" }
            ]
          },
          "limits": {
            "monthly": {
              "usage": 0.42,
              "models": [ { "name": "gpt-oss:120b", "request_count": 30 } ]
            },
            "weekly": { "usage": 0.1, "models": [] },
            "session": { "usage": 0.02 }
          }
        }
        """
        let decoded = try JSONDecoder().decode(
            OllamaUsageResponse.self, from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.activity?.cost, "12.34")
        XCTAssertEqual(decoded.activity?.models?.first?.name, "gpt-oss:120b")
        XCTAssertEqual(decoded.activity?.models?.first?.requestCount, 10)
        XCTAssertEqual(decoded.activity?.models?.first?.cost, "2.50")
        XCTAssertEqual(decoded.limits?.monthly?.usage, 0.42)
        XCTAssertEqual(decoded.limits?.monthly?.models?.first?.requestCount, 30)
        XCTAssertEqual(decoded.limits?.weekly?.usage, 0.1)
        XCTAssertEqual(decoded.limits?.session?.usage, 0.02)
    }

    func testDecodesEmptyResponse() throws {
        let decoded = try JSONDecoder().decode(OllamaUsageResponse.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.activity)
        XCTAssertNil(decoded.limits)
    }

    // MARK: - Monitor

    func testRefreshStoresResponse() async {
        let monitor = UsageMonitor()
        let response = OllamaUsageResponse(
            limits: .init(monthly: OllamaUsageLimit(usage: 0.5, models: nil))
        )
        await monitor.refresh(using: StubOllamaService(result: .success(response)))
        XCTAssertEqual(monitor.response?.limits?.monthly?.usage, 0.5)
        XCTAssertNil(monitor.errorMessage)
        XCTAssertNotNil(monitor.lastUpdated)
        XCTAssertFalse(monitor.isLoading)
    }

    func testRefreshFailureKeepsPreviousResponse() async {
        let monitor = UsageMonitor()
        let response = OllamaUsageResponse(
            limits: .init(monthly: OllamaUsageLimit(usage: 0.5, models: nil))
        )
        await monitor.refresh(using: StubOllamaService(result: .success(response)))
        await monitor.refresh(using: StubOllamaService(result: .failure(StubError())))
        XCTAssertEqual(monitor.response?.limits?.monthly?.usage, 0.5)
        XCTAssertNotNil(monitor.errorMessage)
    }

    // MARK: - Helpers

    private struct StubError: Error {}

    private struct StubOllamaService: OllamaServiceProtocol {
        var result: Result<OllamaUsageResponse, Error>

        func listModels() async throws -> [OllamaModel] { [] }

        func usage() async throws -> OllamaUsageResponse {
            try result.get()
        }

        func streamChat(
            model: String,
            messages: [OllamaChatMessage],
            tools: [OllamaTool],
            temperature: Double,
            think: OllamaThinkValue?
        ) -> AsyncThrowingStream<OllamaChatChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
}
