import XCTest
import SwiftData
@testable import Chatter

/// Tool definition, gating of arguments, attachment persistence and error
/// mapping of `ImageGenToolProvider`, backed by `MockURLProtocol` against an
/// in-memory store.
@MainActor
final class ImageGenToolProviderTests: XCTestCase {
    // ModelContext does not retain its container; a local would deallocate on
    // return and the first insert would trap inside SwiftData.
    private var container: ModelContainer?

    override func setUp() {
        TestDefaults.install()
        MockURLProtocol.reset()
        AppSettings.imageGenModel = "test/image-model"
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestDefaults.restore()
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Agent.self, ChatSession.self, Message.self, Artifact.self,
            // In the hosted test process the `.automatic` default would hook
            // the in-memory store into the app's CloudKit mirroring (crash on
            // save: "No eligible connection available").
            configurations: ModelConfiguration(
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        )
        self.container = container
        return container.mainContext
    }

    private func makeSession(in context: ModelContext) -> ChatSession {
        let session = ChatSession()
        context.insert(session)
        return session
    }

    private func makeProvider() -> ImageGenToolProvider {
        var service = OpenRouterImageService(session: MockURLProtocol.makeSession())
        service.apiKeyOverride = "test-key"
        return ImageGenToolProvider(service: service)
    }

    private func respond(images: [String]) {
        MockURLProtocol.handler = { _ in
            let entries = images
                .map { #"{"type":"image_url","image_url":{"url":"data:image/png;base64,\#($0)"}}"# }
                .joined(separator: ",")
            return (200, Data(#"{"choices":[{"message":{"role":"assistant","images":[\#(entries)]}}]}"#.utf8))
        }
    }

    /// Each request gets the next payload (the last one repeats) — for
    /// multi-round calls where every generation returns a different image.
    /// `MockURLProtocol.requests` is appended in `startLoading()` before the
    /// handler runs, so `requests.count` is the 1-based request number here.
    private func respondSequentially(images: [String]) {
        MockURLProtocol.handler = { _ in
            let index = min(MockURLProtocol.requests.count - 1, images.count - 1)
            let entry = #"{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(images[index])"}}"#
            return (200, Data(#"{"choices":[{"message":{"role":"assistant","images":[\#(entry)]}}]}"#.utf8))
        }
    }

    // MARK: - Definition & argument validation

    func testToolDefinition() {
        let tools = makeProvider().tools()
        XCTAssertEqual(tools.map(\.function.name), [ImageGenToolProvider.generateToolName])
        guard case .object(let properties) = tools[0].function.parameters,
              case .object(let schema) = properties["properties"],
              case .object(let prompt) = schema["prompt"],
              case .array(let required) = properties["required"] else {
            return XCTFail("unexpected parameter schema")
        }
        XCTAssertEqual(prompt["type"], .string("string"))
        XCTAssertEqual(required, [.string("prompt")])
    }

    func testUnknownToolThrows() async {
        let context = try! makeContext()
        let session = makeSession(in: context)
        do {
            _ = try await makeProvider().call(
                name: "imagegen__bogus", argumentsJSON: "{}",
                session: session, context: context
            )
            XCTFail("expected throw")
        } catch let error as ImageGenToolProvider.ToolError {
            guard case .unknownTool = error else {
                return XCTFail("expected .unknownTool, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMissingPromptThrows() async {
        let context = try! makeContext()
        let session = makeSession(in: context)
        do {
            _ = try await makeProvider().call(
                name: ImageGenToolProvider.generateToolName, argumentsJSON: #"{"count":1}"#,
                session: session, context: context
            )
            XCTFail("expected throw")
        } catch let error as ImageGenToolProvider.ToolError {
            guard case .missingArgument(let name) = error else {
                return XCTFail("expected .missingArgument, got \(error)")
            }
            XCTAssertEqual(name, "prompt")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Success path

    func testCallInsertsAssistantMessageWithRecompressedAttachment() async throws {
        respond(images: [TestImages.tinyPNGBase64])
        let context = try makeContext()
        let session = makeSession(in: context)
        // An existing user message: the image message must take the next slot.
        let user = Message(role: .user, content: "draw a cat", orderIndex: 0)
        user.session = session
        context.insert(user)

        let result = try await makeProvider().call(
            name: ImageGenToolProvider.generateToolName,
            argumentsJSON: #"{"prompt":"a cat"}"#,
            session: session, context: context
        )

        XCTAssertTrue(result.contains("1 image"))

        let imageMessage = try XCTUnwrap(
            session.orderedMessages.first { !$0.imageAttachments.isEmpty }
        )
        XCTAssertEqual(imageMessage.role, .assistant)
        XCTAssertTrue(imageMessage.content.isEmpty, "the image is the payload")
        XCTAssertEqual(imageMessage.orderIndex, 1)
        XCTAssertEqual(imageMessage.imageAttachments.count, 1)

        // The raw PNG payload must have been re-encoded as JPEG (CloudKit
        // record budget) — different bytes, still decodable.
        let attachment = imageMessage.imageAttachments[0]
        XCTAssertNotEqual(attachment.base64, TestImages.tinyPNGBase64)
        let data = try XCTUnwrap(Data(base64Encoded: attachment.base64))
        XCTAssertNotNil(ImageAttachmentProcessor.makeBase64JPEG(from: data))
    }

    func testCountIsClampedToTwo() async throws {
        // Distinct payloads per round: identical ones would be deduplicated.
        respondSequentially(images: [TestImages.tinyPNGBase64, TestImages.tinyPNG2Base64])
        let context = try makeContext()
        let session = makeSession(in: context)

        let result = try await makeProvider().call(
            name: ImageGenToolProvider.generateToolName,
            argumentsJSON: #"{"prompt":"a cat","count":5}"#,
            session: session, context: context
        )

        XCTAssertEqual(MockURLProtocol.requests.count, 2, "count caps at 2 generation rounds")
        XCTAssertTrue(result.contains("2 image"))
        let imageMessage = try XCTUnwrap(
            session.orderedMessages.first { !$0.imageAttachments.isEmpty }
        )
        XCTAssertEqual(imageMessage.imageAttachments.count, 2)
        XCTAssertNotEqual(
            imageMessage.imageAttachments[0].base64,
            imageMessage.imageAttachments[1].base64,
            "variants must be distinct images"
        )
    }

    /// The reported bug: some image models return the same image multiple
    /// times in a single response — the duplicates must collapse to the
    /// requested count (default 1), not land as identical attachments.
    func testDuplicateImagesInOneResponseCollapseToOne() async throws {
        respond(images: [TestImages.tinyPNGBase64, TestImages.tinyPNGBase64])
        let context = try makeContext()
        let session = makeSession(in: context)

        let result = try await makeProvider().call(
            name: ImageGenToolProvider.generateToolName,
            argumentsJSON: #"{"prompt":"a cat"}"#,
            session: session, context: context
        )

        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertTrue(result.contains("Generated 1 image"))
        let imageMessage = try XCTUnwrap(
            session.orderedMessages.first { !$0.imageAttachments.isEmpty }
        )
        XCTAssertEqual(imageMessage.imageAttachments.count, 1)
    }

    /// Even distinct extra images must not exceed the requested count.
    func testExtraImagesInOneResponseAreCappedToRequestedCount() async throws {
        respond(images: [TestImages.tinyPNGBase64, TestImages.tinyPNG2Base64])
        let context = try makeContext()
        let session = makeSession(in: context)

        _ = try await makeProvider().call(
            name: ImageGenToolProvider.generateToolName,
            argumentsJSON: #"{"prompt":"a cat"}"#,
            session: session, context: context
        )

        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        let imageMessage = try XCTUnwrap(
            session.orderedMessages.first { !$0.imageAttachments.isEmpty }
        )
        XCTAssertEqual(imageMessage.imageAttachments.count, 1, "only the first image is kept")
    }

    /// A repeat generation with the identical prompt can return the same
    /// image — the second round must ask for a distinct variant.
    func testCountTwoSendsVariantPromptOnSecondRequest() async throws {
        respondSequentially(images: [TestImages.tinyPNGBase64, TestImages.tinyPNG2Base64])
        let context = try makeContext()
        let session = makeSession(in: context)

        _ = try await makeProvider().call(
            name: ImageGenToolProvider.generateToolName,
            argumentsJSON: #"{"prompt":"a cat","count":2}"#,
            session: session, context: context
        )

        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        let firstBody = String(decoding: try XCTUnwrap(MockURLProtocol.body(of: MockURLProtocol.requests[0])), as: UTF8.self)
        let secondBody = String(decoding: try XCTUnwrap(MockURLProtocol.body(of: MockURLProtocol.requests[1])), as: UTF8.self)
        XCTAssertFalse(firstBody.contains("variant"))
        XCTAssertTrue(secondBody.contains("variant 2 of 2"))

        let imageMessage = try XCTUnwrap(
            session.orderedMessages.first { !$0.imageAttachments.isEmpty }
        )
        XCTAssertEqual(imageMessage.imageAttachments.count, 2)
    }

    /// Image-to-image on explicit request: with `edit_latest_image` the
    /// newest message's images ride along as input.
    func testForwardsNewestUserAttachmentsAsEditingInput() async throws {
        respond(images: [TestImages.tinyPNGBase64])
        let context = try makeContext()
        let session = makeSession(in: context)

        // Older image message — must NOT be picked once a newer one exists.
        let oldUser = Message(role: .user, content: "old", orderIndex: 0)
        oldUser.imageAttachments = [ImageAttachment(base64: "T0xE")]
        oldUser.session = session
        context.insert(oldUser)
        let newUser = Message(role: .user, content: "make this B/W", orderIndex: 1)
        newUser.imageAttachments = [ImageAttachment(base64: "UFJDQQ=="), ImageAttachment(base64: "UFJDQg==")]
        newUser.session = session
        context.insert(newUser)

        _ = try await makeProvider().call(
            name: ImageGenToolProvider.generateToolName,
            argumentsJSON: #"{"prompt":"make it black and white","edit_latest_image":true}"#,
            session: session, context: context
        )

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let body = try XCTUnwrap(MockURLProtocol.body(of: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let imageParts = parts.filter { $0["type"] as? String == "image_url" }
        XCTAssertEqual(imageParts.count, 2, "both attachments of the newest image message")
        let urls = imageParts.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
        XCTAssertTrue(urls.allSatisfy { $0.hasPrefix("data:image/jpeg;base64,") })
        XCTAssertFalse(urls.contains { $0.contains("T0xE") }, "the older message's image must not be forwarded")
    }

    /// Default (no flag): a fresh generation sends NO editing input, even
    /// though an image message exists — otherwise «2 better versions» would
    /// return near-copies of the previous generation.
    func testFreshGenerationOmitsEditingInputByDefault() async throws {
        respond(images: [TestImages.tinyPNGBase64])
        let context = try makeContext()
        let session = makeSession(in: context)

        let previous = Message(role: .assistant, content: "", orderIndex: 0)
        previous.imageAttachments = [ImageAttachment(base64: "UFJFVg==")]
        previous.session = session
        context.insert(previous)

        _ = try await makeProvider().call(
            name: ImageGenToolProvider.generateToolName,
            argumentsJSON: #"{"prompt":"a better version","count":2}"#,
            session: session, context: context
        )

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let body = try XCTUnwrap(MockURLProtocol.body(of: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        // `content` is always a parts array (OpenRouterChatRequest.Message).
        let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1, "only the text prompt — no editing input")
        XCTAssertEqual(parts.first?["type"] as? String, "text")
    }

    // MARK: - Failure paths

    func testServiceErrorPropagatesAndLeavesNoMessage() async throws {
        MockURLProtocol.handler = { _ in
            (200, Data(#"{"error":{"message":"rate limited"}}"#.utf8))
        }
        let context = try makeContext()
        let session = makeSession(in: context)

        do {
            _ = try await makeProvider().call(
                name: ImageGenToolProvider.generateToolName,
                argumentsJSON: #"{"prompt":"a cat"}"#,
                session: session, context: context
            )
            XCTFail("expected throw")
        } catch let error as OpenRouterImageService.ServiceError {
            guard case .server = error else {
                return XCTFail("expected .server, got \(error)")
            }
        }
        XCTAssertTrue(session.orderedMessages.isEmpty, "no partial image message on failure")
    }

    func testUndecodableImageThrows() async throws {
        respond(images: [TestImages.notAnImageBase64])
        let context = try makeContext()
        let session = makeSession(in: context)

        do {
            _ = try await makeProvider().call(
                name: ImageGenToolProvider.generateToolName,
                argumentsJSON: #"{"prompt":"a cat"}"#,
                session: session, context: context
            )
            XCTFail("expected throw")
        } catch let error as ImageGenToolProvider.ToolError {
            guard case .noUsableImages = error else {
                return XCTFail("expected .noUsableImages, got \(error)")
            }
        }
        XCTAssertTrue(session.orderedMessages.isEmpty)
    }
}
