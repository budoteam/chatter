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

    // MARK: - choices fences (quick-reply buttons)

    func testChoicesFenceBecomesChoicesBlock() {
        let blocks = MarkdownParser.parse("Pick one:\n\n```choices\nYes\nNo\nMaybe so\n```")
        guard blocks.count == 2, case .paragraph = blocks[0],
              case .choices(let options) = blocks[1] else {
            return XCTFail("expected paragraph + choices, got \(blocks)")
        }
        XCTAssertEqual(options, ["Yes", "No", "Maybe so"])
    }

    func testChoicesFenceIsCaseInsensitiveAndTrims() {
        let blocks = MarkdownParser.parse("```Choices\n  A  \n\nB\n```")
        guard blocks.count == 1, case .choices(let options) = blocks[0] else {
            return XCTFail("expected choices, got \(blocks)")
        }
        XCTAssertEqual(options, ["A", "B"])
    }

    func testChoicesFenceCapsAtSixOptions() {
        let blocks = MarkdownParser.parse("```choices\nA\nB\nC\nD\nE\nF\nG\nH\n```")
        guard blocks.count == 1, case .choices(let options) = blocks[0] else {
            return XCTFail("expected choices, got \(blocks)")
        }
        XCTAssertEqual(options, ["A", "B", "C", "D", "E", "F"])
    }

    func testEmptyChoicesFenceRendersNothing() {
        XCTAssertTrue(MarkdownParser.parse("```choices\n\n```").isEmpty)
        XCTAssertTrue(MarkdownParser.parse("```choices\n```").isEmpty)
    }
}
