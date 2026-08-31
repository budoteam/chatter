import XCTest
@testable import Chatter

/// Response parsing, model-list filtering, error mapping and the 401 retry of
/// `OpenRouterImageService`, driven by `MockURLProtocol` (no network/keychain —
/// the service reads its key from `apiKeyOverride`).
final class OpenRouterImageServiceTests: XCTestCase {
    override func setUp() {
        TestDefaults.install()
        MockURLProtocol.reset()
        AppSettings.imageGenModel = "test/image-model"
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestDefaults.restore()
    }

    private func makeService() -> OpenRouterImageService {
        var service = OpenRouterImageService(session: MockURLProtocol.makeSession())
        service.apiKeyOverride = "test-key"
        return service
    }

    private func chatResponse(images: [String]) -> Data {
        let entries = images
            .map { #"{"type":"image_url","image_url":{"url":"\#($0)"}}"# }
            .joined(separator: ",")
        return Data(#"{"choices":[{"message":{"role":"assistant","images":[\#(entries)]}}]}"#.utf8)
    }

    // MARK: - generateImages

    func testGenerateImagesParsesDataURLsAndRawPayloads() async throws {
        MockURLProtocol.handler = { _ in
            (200, self.chatResponse(images: [
                "data:image/png;base64,\(TestImages.tinyPNGBase64)",
                TestImages.tinyPNGBase64,
            ]))
        }

        let images = try await makeService().generateImages(prompt: "a cat")

        XCTAssertEqual(images, [TestImages.tinyPNGBase64, TestImages.tinyPNGBase64])

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testGenerateImagesSendsExpectedBody() async throws {
        MockURLProtocol.handler = { _ in (200, self.chatResponse(images: [TestImages.tinyPNGBase64])) }

        _ = try await makeService().generateImages(prompt: "a red panda")

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let body = try XCTUnwrap(MockURLProtocol.body(of: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "test/image-model")
        XCTAssertEqual(json["modalities"] as? [String], ["image", "text"])
        XCTAssertEqual(json["stream"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1, "text-only request has one part")
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        XCTAssertEqual(parts.first?["text"] as? String, "a red panda")
    }

    func testGenerateImagesWithInputImagesSendsImageParts() async throws {
        MockURLProtocol.handler = { _ in (200, self.chatResponse(images: [TestImages.tinyPNGBase64])) }

        _ = try await makeService().generateImages(prompt: "make it B/W", images: ["AAAA", "BBBB"])

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let body = try XCTUnwrap(MockURLProtocol.body(of: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 3, "text part + one image part per input image")
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        for (index, payload) in ["AAAA", "BBBB"].enumerated() {
            let part = parts[index + 1]
            XCTAssertEqual(part["type"] as? String, "image_url")
            let imageURL = part["image_url"] as? [String: Any]
            XCTAssertEqual(imageURL?["url"] as? String, "data:image/jpeg;base64,\(payload)")
        }
    }

    func testGenerateImagesThrowsOnInBandError() async throws {
        MockURLProtocol.handler = { _ in
            (200, Data(#"{"error":{"message":"rate limited"}}"#.utf8))
        }

        do {
            _ = try await makeService().generateImages(prompt: "x")
            XCTFail("expected throw")
        } catch let error as OpenRouterImageService.ServiceError {
            guard case .server(let message) = error else {
                return XCTFail("expected .server, got \(error)")
            }
            XCTAssertEqual(message, "rate limited")
        }
    }

    func testGenerateImagesThrowsWhenNoImages() async throws {
        MockURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"no can do"}}]}"#.utf8))
        }

        do {
            _ = try await makeService().generateImages(prompt: "x")
            XCTFail("expected throw")
        } catch let error as OpenRouterImageService.ServiceError {
            guard case .noImages = error else {
                return XCTFail("expected .noImages, got \(error)")
            }
        }
    }

    func testGenerateImagesThrowsWithoutConfiguredModel() async {
        AppSettings.imageGenModel = ""

        do {
            _ = try await makeService().generateImages(prompt: "x")
            XCTFail("expected throw")
        } catch let error as OpenRouterImageService.ServiceError {
            guard case .noModelConfigured = error else {
                return XCTFail("expected .noModelConfigured, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        // No request may have been fired.
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testGenerateImagesSurfacesHTTPError() async {
        MockURLProtocol.handler = { _ in (500, Data("upstream exploded".utf8)) }

        do {
            _ = try await makeService().generateImages(prompt: "x")
            XCTFail("expected throw")
        } catch let error as OpenRouterImageService.ServiceError {
            guard case .http(let code, let body) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(code, 500)
            XCTAssertTrue(body.contains("upstream exploded"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testGenerateImagesRetriesOnceOn401() async throws {
        var attempts = 0
        MockURLProtocol.handler = { _ in
            attempts += 1
            return attempts == 1
                ? (401, Data("unauthorized".utf8))
                : (200, self.chatResponse(images: [TestImages.tinyPNGBase64]))
        }

        let images = try await makeService().generateImages(prompt: "x")

        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(MockURLProtocol.requests.count, 2, "one retry after 401")
    }

    // MARK: - listImageModels

    func testListImageModelsFiltersByOutputModalityAndSorts() async throws {
        MockURLProtocol.handler = { _ in
            let json = """
            {"data":[
              {"id":"z/text","name":"Zeta Text","architecture":{"output_modalities":["text"]}},
              {"id":"b/img","name":"Beta Image","architecture":{"output_modalities":["text","image"]}},
              {"id":"a/img","name":"Alpha Image","architecture":{"output_modalities":["image"]}},
              {"id":"c/noarch","name":"No Architecture"}
            ]}
            """
            return (200, Data(json.utf8))
        }

        let models = try await makeService().listImageModels()

        XCTAssertEqual(models.map(\.id), ["a/img", "b/img"], "image-capable only, sorted by name")
        XCTAssertEqual(models.map(\.name), ["Alpha Image", "Beta Image"])

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
    }
}
