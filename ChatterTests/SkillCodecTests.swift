import XCTest
@testable import Chatter

/// Round trips and tolerant parsing of the single-skill markdown format.
final class SkillCodecTests: XCTestCase {
    func testSerializeParseRoundTrip() {
        let text = SkillCodec.serialize(
            name: "weekly-report",
            summary: "Compile the weekly report",
            content: "1. Gather numbers.\n2. Write it up.\n"
        )
        XCTAssertEqual(text, """
        ---
        name: weekly-report
        description: Compile the weekly report
        ---

        1. Gather numbers.
        2. Write it up.

        """)

        let parsed = SkillCodec.parse(fileName: "weekly-report.md", contents: text)
        XCTAssertEqual(parsed.name, "weekly-report")
        XCTAssertEqual(parsed.summary, "Compile the weekly report")
        XCTAssertEqual(parsed.content, "1. Gather numbers.\n2. Write it up.\n")
        XCTAssertTrue(parsed.warnings.isEmpty)
    }

    func testSummaryNeedingQuotesRoundTrips() {
        let summary = "use when: numbers #matter"
        let text = SkillCodec.serialize(name: "s", summary: summary, content: "body")
        XCTAssertTrue(text.contains("description: \"use when: numbers #matter\""))

        let parsed = SkillCodec.parse(fileName: "s.md", contents: text)
        XCTAssertEqual(parsed.summary, summary)
        XCTAssertEqual(parsed.content, "body")
    }

    func testEmptySummaryOmitsDescriptionLine() {
        let text = SkillCodec.serialize(name: "s", summary: "", content: "body")
        XCTAssertFalse(text.contains("description:"))

        let parsed = SkillCodec.parse(fileName: "s.md", contents: text)
        XCTAssertEqual(parsed.summary, "")
        XCTAssertEqual(parsed.content, "body")
    }

    func testEmptyContentRoundTrips() {
        let text = SkillCodec.serialize(name: "s", summary: "sum", content: "")
        XCTAssertEqual(text, "---\nname: s\ndescription: sum\n---\n")

        let parsed = SkillCodec.parse(fileName: "s.md", contents: text)
        XCTAssertEqual(parsed.content, "")
    }

    func testParseToleratesCRLFAndBOM() {
        let text = "\u{FEFF}---\r\nname: s\r\ndescription: sum\r\n---\r\n\r\nbody\r\n"
        let parsed = SkillCodec.parse(fileName: "s.md", contents: text)
        XCTAssertEqual(parsed.name, "s")
        XCTAssertEqual(parsed.summary, "sum")
        XCTAssertEqual(parsed.content, "body\n")
    }

    func testMissingFrontmatterFallsBackToFileName() {
        let parsed = SkillCodec.parse(fileName: "notes.md", contents: "just some text")
        XCTAssertNil(parsed.name)
        XCTAssertEqual(parsed.content, "just some text")
        XCTAssertEqual(parsed.warnings.count, 1)
    }

    func testUnterminatedFrontmatterIsTreatedAsBody() {
        let text = "---\nname: s\nno closing fence"
        let parsed = SkillCodec.parse(fileName: "s.md", contents: text)
        XCTAssertNil(parsed.name)
        XCTAssertEqual(parsed.content, text)
        XCTAssertEqual(parsed.warnings.count, 1)
    }

    func testSummaryKeyAcceptedAsAlias() {
        let text = "---\nname: s\nsummary: from alias\n---\n\nbody"
        let parsed = SkillCodec.parse(fileName: "s.md", contents: text)
        XCTAssertEqual(parsed.summary, "from alias")
    }

    func testUnknownKeysAreIgnored() {
        let text = "---\nname: s\nauthor: someone\n---\n\nbody"
        let parsed = SkillCodec.parse(fileName: "s.md", contents: text)
        XCTAssertEqual(parsed.name, "s")
        XCTAssertEqual(parsed.content, "body")
        XCTAssertTrue(parsed.warnings.isEmpty)
    }

    func testFrontmatterWithoutNameWarns() {
        let text = "---\ndescription: sum\n---\n\nbody"
        let parsed = SkillCodec.parse(fileName: "s.md", contents: text)
        XCTAssertNil(parsed.name)
        XCTAssertEqual(parsed.summary, "sum")
        XCTAssertEqual(parsed.warnings.count, 1)
    }
}
