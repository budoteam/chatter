import XCTest
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
@testable import Chatter

@MainActor
final class ChatViewModelImageTests: XCTestCase {
    /// 1×1 transparent PNG.
    private let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    func testAddBase64ImagesAppendsWithinBudgetAndClearsFlag() {
        let vm = ChatViewModel()
        vm.addBase64Images(["a", "b"])
        XCTAssertEqual(vm.pendingImages.count, 2)
        XCTAssertFalse(vm.imageLimitHit)
    }

    func testAddBase64ImagesSkipsOverBudgetAndSetsFlag() {
        let vm = ChatViewModel()
        let big = String(repeating: "A", count: ImageAttachment.maxBase64BytesPerMessage)
        vm.addBase64Images([big, big])
        XCTAssertEqual(vm.pendingImages.count, 1, "second image exceeds the 700 KB budget")
        XCTAssertTrue(vm.imageLimitHit)
        vm.pendingImages = []
        vm.addBase64Images(["small"])
        XCTAssertFalse(vm.imageLimitHit, "a clean run clears the hint again")
    }

    func testMakeBase64JPEGsLoadsImageDataProvider() async {
        let provider = NSItemProvider(item: pngData as NSData, typeIdentifier: UTType.png.identifier)
        let result = await ImageAttachmentProcessor.makeBase64JPEGs(from: [provider])
        XCTAssertEqual(result.count, 1, "in-memory image content must load")
    }

#if os(macOS)
    /// Named throwaway pasteboard — NEVER `.general` (user clipboard!).
    private func testPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("ChatterTests.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func testPasteboardWithImageObjectReturnsBase64() {
        let pb = testPasteboard()
        XCTAssertTrue(pb.writeObjects([NSImage(data: pngData)!]))
        XCTAssertEqual(ImageAttachmentProcessor.base64JPEGsFromPasteboard(pb)?.count, 1)
    }

    func testPasteboardWithImageFileURLReturnsBase64() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try pngData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let pb = testPasteboard()
        XCTAssertTrue(pb.writeObjects([url as NSURL]))
        XCTAssertEqual(ImageAttachmentProcessor.base64JPEGsFromPasteboard(pb)?.count, 1,
                       "exactly one of the NSImage / file-URL branches must attach the file")
    }

    func testPasteboardWithPlainTextReturnsNil() {
        let pb = testPasteboard()
        XCTAssertTrue(pb.writeObjects(["hello" as NSString]))
        XCTAssertNil(ImageAttachmentProcessor.base64JPEGsFromPasteboard(pb))
    }
#endif
}
