import XCTest
@testable import Chatter

/// Intercepts URLSession requests and answers them from a scripted handler —
/// lets HTTP service tests run without network or keychain.
///
/// The handler and captured requests are static: tests in this target run
/// serially, and each test resets the state in setUp/tearDown.
final class MockURLProtocol: URLProtocol {
    /// Request → (HTTP status, response body). Set per test.
    static var handler: ((URLRequest) throws -> (Int, Data))?

    /// Every request that passed through, for assertions on path/method/
    /// headers/body (counting them doubles as a call counter).
    static private(set) var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://localhost")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// The request's body data (URLSession often moves `httpBody` into a
    /// stream before the protocol sees it).
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

/// Decodable image payloads for tests.
enum TestImages {
    /// 1×1 transparent PNG — valid for ImageIO, so recompression paths run.
    static let tinyPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

    /// Valid Base64, but not an image ("hello") — decode must fail.
    static let notAnImageBase64 = "aGVsbG8="
}
