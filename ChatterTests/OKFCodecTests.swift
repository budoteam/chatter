import XCTest
@testable import Chatter

/// Round-trip tests for the OKF frontmatter codec. Canonical files (known
/// keys in canonical order, LF endings) must round-trip byte-identically;
/// everything else must round-trip without information loss.
final class OKFCodecTests: XCTestCase {

    // MARK: - Canonical round trips

    func testCanonicalConceptRoundTripsByteIdentically() {
        let file = """
        ---
        type: table
        title: Users
        description: All registered users
        resource: bigquery://project/dataset/users
        tags: [core, pii]
        timestamp: 2026-06-12T09:30:00Z
        ---

        # Schema

        | column | type |
        |--------|------|
        | id     | INT  |

        """
        let doc = OKFCodec.parse(path: "tables/users.md", contents: file)
        XCTAssertEqual(doc.kind, .concept)
        XCTAssertEqual(doc.frontmatter?.type, "table")
        XCTAssertEqual(doc.frontmatter?.title, "Users")
        XCTAssertEqual(doc.frontmatter?.summary, "All registered users")
        XCTAssertEqual(doc.frontmatter?.resource, "bigquery://project/dataset/users")
        XCTAssertEqual(doc.frontmatter?.tags, ["core", "pii"])
        XCTAssertEqual(doc.frontmatter?.timestampRaw, "2026-06-12T09:30:00Z")
        XCTAssertTrue(doc.warnings.isEmpty)
        XCTAssertEqual(OKFCodec.serialize(doc), file)
    }

    func testMinimalConceptRoundTripsByteIdentically() {
        let file = "---\ntype: note\n---\n"
        let doc = OKFCodec.parse(path: "a.md", contents: file)
        XCTAssertEqual(doc.frontmatter?.type, "note")
        XCTAssertEqual(doc.body, "")
        XCTAssertEqual(OKFCodec.serialize(doc), file)
    }

    // MARK: - Unknown keys

    func testUnknownKeysArePreservedVerbatim() {
        let file = """
        ---
        type: api
        owner: data-platform
        x-review:
          approved_by: alice
          date: 2026-01-01
        ---

        Body.

        """
        let doc = OKFCodec.parse(path: "a.md", contents: file)
        let extras = doc.frontmatter?.extraFields ?? []
        XCTAssertEqual(extras.map(\.key), ["owner", "x-review"])
        XCTAssertEqual(extras[1].rawBlock, "x-review:\n  approved_by: alice\n  date: 2026-01-01")
        XCTAssertEqual(OKFCodec.serialize(doc), file)
    }

    func testKnownKeyWithBlockScalarIsPreservedVerbatim() {
        let file = """
        ---
        type: note
        description: |
          Line one
          Line two
        ---
        """
        let doc = OKFCodec.parse(path: "a.md", contents: file + "\n")
        XCTAssertNil(doc.frontmatter?.summary)
        XCTAssertEqual(
            doc.frontmatter?.extraFields.first?.rawBlock,
            "description: |\n  Line one\n  Line two"
        )
        XCTAssertEqual(OKFCodec.serialize(doc), file + "\n")
    }

    func testDuplicateKnownKeyKeepsSecondOccurrenceVerbatim() {
        let file = "---\ntype: note\ntitle: First\ntitle: Second\n---\n"
        let doc = OKFCodec.parse(path: "a.md", contents: file)
        XCTAssertEqual(doc.frontmatter?.title, "First")
        XCTAssertEqual(doc.frontmatter?.extraFields.first?.rawBlock, "title: Second")
        XCTAssertFalse(doc.warnings.isEmpty)
        XCTAssertEqual(OKFCodec.serialize(doc), file)
    }

    // MARK: - Quoting

    func testQuotedScalarRoundTrips() {
        let file = "---\ntype: note\ntitle: \"Hello: World\"\n---\n"
        let doc = OKFCodec.parse(path: "a.md", contents: file)
        XCTAssertEqual(doc.frontmatter?.title, "Hello: World")
        XCTAssertEqual(OKFCodec.serialize(doc), file)
    }

    func testSingleQuotedScalarIsUnquoted() {
        let doc = OKFCodec.parse(path: "a.md", contents: "---\ntype: note\ntitle: 'It''s here'\n---\n")
        XCTAssertEqual(doc.frontmatter?.title, "It's here")
    }

    func testBoolAndNumberLikeScalarsGetQuotedOnSerialize() {
        let doc = OKFDocument(
            relativePath: "a.md", kind: .concept,
            frontmatter: OKFFrontmatter(type: "note", title: "true", tags: ["42"]),
            body: ""
        )
        XCTAssertEqual(OKFCodec.serialize(doc), "---\ntype: note\ntitle: \"true\"\ntags: [\"42\"]\n---\n")
    }

    // MARK: - Tags

    func testBlockStyleTagsParseAndNormalizeToFlow() {
        let file = "---\ntype: note\ntags:\n  - alpha\n  - beta\n---\n"
        let doc = OKFCodec.parse(path: "a.md", contents: file)
        XCTAssertEqual(doc.frontmatter?.tags, ["alpha", "beta"])
        XCTAssertEqual(OKFCodec.serialize(doc), "---\ntype: note\ntags: [alpha, beta]\n---\n")
    }

    func testFlowTagsWithQuotedCommaRoundTrip() {
        let file = "---\ntype: note\ntags: [\"a, b\", c]\n---\n"
        let doc = OKFCodec.parse(path: "a.md", contents: file)
        XCTAssertEqual(doc.frontmatter?.tags, ["a, b", "c"])
        XCTAssertEqual(OKFCodec.serialize(doc), file)
    }

    // MARK: - Reserved files

    func testIndexAndLogPassThroughVerbatim() {
        let index = "# Section\n\n* [A](/a.md) - thing\n"
        let indexDoc = OKFCodec.parse(path: "guides/index.md", contents: index)
        XCTAssertEqual(indexDoc.kind, .index)
        XCTAssertNil(indexDoc.frontmatter)
        XCTAssertEqual(OKFCodec.serialize(indexDoc), index)

        let log = "# Log\n\n## 2026-05-22\n* **Update**: something\n"
        let logDoc = OKFCodec.parse(path: "log.md", contents: log)
        XCTAssertEqual(logDoc.kind, .log)
        XCTAssertEqual(OKFCodec.serialize(logDoc), log)
    }

    // MARK: - Tolerance

    func testMissingTypeYieldsWarningAndUnknown() {
        let doc = OKFCodec.parse(path: "a.md", contents: "---\ntitle: No type\n---\n")
        XCTAssertEqual(doc.frontmatter?.type, "unknown")
        XCTAssertFalse(doc.warnings.isEmpty)
    }

    func testMissingFrontmatterIsToleratedWithWarning() {
        let doc = OKFCodec.parse(path: "a.md", contents: "Just some text.\n")
        XCTAssertEqual(doc.kind, .concept)
        XCTAssertEqual(doc.frontmatter?.type, "unknown")
        XCTAssertEqual(doc.body, "Just some text.\n")
        XCTAssertFalse(doc.warnings.isEmpty)
    }

    func testUnterminatedFrontmatterIsToleratedWithWarning() {
        let doc = OKFCodec.parse(path: "a.md", contents: "---\ntype: note\nno closing fence\n")
        XCTAssertEqual(doc.frontmatter?.type, "unknown")
        XCTAssertFalse(doc.warnings.isEmpty)
    }

    func testCRLFIsNormalized() {
        let doc = OKFCodec.parse(path: "a.md", contents: "---\r\ntype: note\r\n---\r\n\r\nBody\r\n")
        XCTAssertEqual(doc.frontmatter?.type, "note")
        XCTAssertEqual(doc.body, "Body\n")
    }

    func testBodyWithoutLeadingBlankLineSurvives() {
        let doc = OKFCodec.parse(path: "a.md", contents: "---\ntype: note\n---\nBody right away\n")
        XCTAssertEqual(doc.body, "Body right away\n")
        // Serialization normalizes to one blank line before the body.
        XCTAssertEqual(OKFCodec.serialize(doc), "---\ntype: note\n---\n\nBody right away\n")
    }
}
