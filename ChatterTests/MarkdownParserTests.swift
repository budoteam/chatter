import XCTest
@testable import Chatter

/// Block-level parsing for standalone image lines and SVG code fences.
final class MarkdownParserTests: XCTestCase {
    func testStandaloneImageLineBecomesImageBlock() {
        let blocks = MarkdownParser.parse("![diagram](https://example.com/a.png)")
        guard blocks.count == 1, case .image(let alt, let url) = blocks[0] else {
            return XCTFail("expected one image block, got \(blocks)")
        }
        XCTAssertEqual(alt, "diagram")
        XCTAssertEqual(url, "https://example.com/a.png")
    }

    func testDataImageLineBecomesImageBlock() {
        let blocks = MarkdownParser.parse("![](data:image/png;base64,iVBORw0KGgo=)")
        guard blocks.count == 1, case .image(let alt, let url) = blocks[0] else {
            return XCTFail("expected one image block, got \(blocks)")
        }
        XCTAssertEqual(alt, "")
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
    }

    func testImageInsideParagraphStaysInline() {
        let blocks = MarkdownParser.parse("see ![diagram](https://example.com/a.png) here")
        guard blocks.count == 1, case .paragraph = blocks[0] else {
            return XCTFail("expected paragraph, got \(blocks)")
        }
    }

    func testPartialImageSyntaxStaysParagraph() {
        // Streaming flushes can cut the URL mid-token; must not render.
        for partial in ["![diagram](https://example.com/di", "![diagram]",
                        "![diagram]()", "![diagram](ftp://example.com/a.png)"] {
            let blocks = MarkdownParser.parse(partial)
            guard blocks.count == 1, case .paragraph = blocks[0] else {
                return XCTFail("expected paragraph for \(partial), got \(blocks)")
            }
        }
    }

    func testSVGFenceParsesAsCodeWithLanguage() {
        let text = "```svg\n<svg viewBox=\"0 0 10 10\"></svg>\n```"
        let blocks = MarkdownParser.parse(text)
        guard blocks.count == 1, case .code(let language, let content) = blocks[0] else {
            return XCTFail("expected code block, got \(blocks)")
        }
        XCTAssertEqual(language, "svg")
        XCTAssertTrue(content.contains("<svg"))
    }

    func testExclamationInTableCellIsNotAnImage() {
        let text = "| col |\n| --- |\n| ![a](https://example.com/a.png) |"
        let blocks = MarkdownParser.parse(text)
        guard blocks.count == 1, case .table = blocks[0] else {
            return XCTFail("expected table, got \(blocks)")
        }
    }

    func testSVGAspectRatioParsing() {
        XCTAssertEqual(SVGView.aspectRatio(of: #"<svg viewBox="0 0 200 100"></svg>"#), 2.0)
        XCTAssertEqual(SVGView.aspectRatio(of: #"<svg viewBox="0 0 100 100"></svg>"#), 1.0)
        XCTAssertEqual(SVGView.aspectRatio(of: #"<svg width="320" height="160"></svg>"#), 2.0)
        XCTAssertNil(SVGView.aspectRatio(of: "<svg></svg>"))
    }
}
