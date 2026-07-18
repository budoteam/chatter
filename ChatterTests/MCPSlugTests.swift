import XCTest
@testable import Chatter

/// The server-slug sanitizer behind MCP tool namespacing.
final class MCPSlugTests: XCTestCase {
    func testNamespacedFormat() {
        XCTAssertEqual(
            MCPConnectionManager.namespaced(server: "My API", tool: "search"),
            "my_api__search"
        )
    }

    func testSlugLowercasesAndReplacesNonAlnum() {
        XCTAssertEqual(MCPConnectionManager.slug(for: "My API"), "my_api")
        XCTAssertEqual(MCPConnectionManager.slug(for: "ABC"), "abc")
        XCTAssertEqual(MCPConnectionManager.slug(for: "Search API!"), "search_api_")
        XCTAssertEqual(MCPConnectionManager.slug(for: "a.b/c d"), "a_b_c_d")
    }

    func testSlugCapsAt24Characters() {
        let slug = MCPConnectionManager.slug(for: "abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertEqual(slug, "abcdefghijklmnopqrstuvwx")
        XCTAssertEqual(slug.count, 24)
    }

    /// Documents the collision `connect()` refuses: names that differ only in
    /// case/punctuation sanitize to the same slug and would namespace their
    /// tools identically.
    func testSimilarServerNamesCollide() {
        XCTAssertEqual(
            MCPConnectionManager.slug(for: "My API"),
            MCPConnectionManager.slug(for: "my-api")
        )
        XCTAssertEqual(
            MCPConnectionManager.namespaced(server: "My API", tool: "get"),
            MCPConnectionManager.namespaced(server: "my-api", tool: "get")
        )
    }
}
