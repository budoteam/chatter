import XCTest
@testable import Chatter

/// Decode/encode round-trips for `JSONValue` and the `parse` fallback.
/// (`init(any:)` / `anyValue` are intentionally not covered — they are being
/// removed in parallel work.)
final class JSONValueTests: XCTestCase {
    private func roundTrip(_ value: JSONValue) -> JSONValue {
        JSONValue.parse(value.jsonString)
    }

    func testScalarRoundTrips() {
        XCTAssertEqual(roundTrip(.string("hello")), .string("hello"))
        XCTAssertEqual(roundTrip(.number(42.5)), .number(42.5))
        XCTAssertEqual(roundTrip(.number(-7)), .number(-7))
        XCTAssertEqual(roundTrip(.bool(true)), .bool(true))
        XCTAssertEqual(roundTrip(.bool(false)), .bool(false))
        XCTAssertEqual(roundTrip(.null), .null)
    }

    func testArrayRoundTrip() {
        let value: JSONValue = .array([.number(1), .string("x"), .bool(true), .null])
        XCTAssertEqual(roundTrip(value), value)
    }

    func testObjectRoundTrip() {
        let value: JSONValue = .object([
            "name": .string("report"),
            "count": .number(3),
            "enabled": .bool(false),
            "tags": .array([.string("a"), .string("b")]),
            "nested": .object(["inner": .null]),
        ])
        XCTAssertEqual(roundTrip(value), value)
    }

    func testDecodeFromRawJSON() {
        let value = JSONValue.parse(#"{"a": [1, "x", true, null], "b": {"c": 2.5}}"#)
        XCTAssertEqual(value, .object([
            "a": .array([.number(1), .string("x"), .bool(true), .null]),
            "b": .object(["c": .number(2.5)]),
        ]))
    }

    func testParseGarbageFallsBackToEmptyObject() {
        XCTAssertEqual(JSONValue.parse("not json"), .object([:]))
        XCTAssertEqual(JSONValue.parse(""), .object([:]))
        XCTAssertEqual(JSONValue.parse("{"), .object([:]))
        XCTAssertEqual(JSONValue.parse("[1, 2"), .object([:]))
    }
}
