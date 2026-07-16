import XCTest
import UniformTypeIdentifiers
@testable import Chatter

/// Language-tag → export extension/UTType mapping for code-block saving.
final class CodeFileTypeTests: XCTestCase {
    func testDataFormatsMapToTheirTypes() {
        XCTAssertEqual(CodeFileType.fileExtension(for: "csv"), "csv")
        XCTAssertEqual(CodeFileType.utType(for: "csv"), .commaSeparatedText)
        XCTAssertEqual(CodeFileType.fileExtension(for: "json"), "json")
        XCTAssertEqual(CodeFileType.utType(for: "json"), .json)
        XCTAssertEqual(CodeFileType.fileExtension(for: "yml"), "yaml")
        XCTAssertEqual(CodeFileType.fileExtension(for: "markdown"), "md")
    }

    func testLanguageTagIsCaseInsensitive() {
        XCTAssertEqual(CodeFileType.fileExtension(for: "CSV"), "csv")
        XCTAssertEqual(CodeFileType.fileExtension(for: "Swift"), "swift")
    }

    func testUnknownAndMissingLanguagesFallBackToPlainText() {
        XCTAssertEqual(CodeFileType.fileExtension(for: "brainfuck"), "txt")
        XCTAssertEqual(CodeFileType.fileExtension(for: nil), "txt")
        XCTAssertEqual(CodeFileType.fileExtension(for: ""), "txt")
        XCTAssertEqual(CodeFileType.utType(for: nil), .plainText)
    }
}
