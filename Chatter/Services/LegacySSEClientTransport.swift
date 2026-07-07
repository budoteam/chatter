import Foundation
import Logging
import MCP

/// Client transport for the legacy MCP "HTTP + SSE" protocol (2024-11-05),
/// still used by bridges like supergateway and mcp-proxy that expose a `/sse`
/// endpoint.
///
/// Flow: GET the SSE URL; the server first sends an `endpoint` event carrying
/// the session-specific POST URL. JSON-RPC requests go to that URL via POST;
/// responses and notifications arrive as `message` events on the SSE stream.
/// (The official SDK's `HTTPClientTransport` speaks the newer Streamable HTTP
/// protocol, which such servers answer with 405.)
actor LegacySSEClientTransport: Transport {
    nonisolated let logger: Logger

    private let sseURL: URL
    private let requestModifier: (URLRequest) -> URLRequest

    /// One shared session for all legacy SSE transports. Never invalidated:
    /// tearing down a URLSession while an AsyncBytes stream is live triggers
    /// a CFNetwork crash (`-[OS_dispatch_mach_msg _setContext:]`). Streams are
    /// ended by cancelling the reading task instead.
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        // The SSE stream idles between events; don't let URLSession kill it.
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: config)
    }()

    private var session: URLSession { Self.sharedSession }

    private var postURL: URL?
    private var readTask: Task<Void, Never>?
    private var endpointContinuation: CheckedContinuation<URL, Swift.Error>?

    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    init(
        endpoint: URL,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        self.sseURL = endpoint
        self.requestModifier = requestModifier
        self.logger = logger ?? Logger(label: "chatter.mcp.sse-legacy")
        (self.stream, self.continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    // MARK: - Transport

    func connect() async throws {
        var request = URLRequest(url: sseURL)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request = requestModifier(request)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.internalError("SSE connect: no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw MCPError.internalError("SSE connect failed (HTTP \(http.statusCode))")
        }

        readTask = Task { await self.readLoop(bytes) }

        // The server must announce its message endpoint before we can talk.
        do {
            postURL = try await withCheckedThrowingContinuation { cont in
                self.endpointContinuation = cont
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    self.failEndpointWait()
                }
            }
        } catch {
            // Don't leave the stream running after a failed handshake.
            readTask?.cancel()
            readTask = nil
            throw error
        }
    }

    func disconnect() async {
        // Cancelling the reading task cancels the underlying URLSession task;
        // the shared session itself is intentionally left alone (see above).
        readTask?.cancel()
        readTask = nil
        endpointContinuation?.resume(throwing: MCPError.internalError("Disconnected"))
        endpointContinuation = nil
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        guard let postURL else {
            throw MCPError.internalError("SSE transport not connected")
        }
        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request = requestModifier(request)
        request.httpBody = data

        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.internalError("SSE POST failed (HTTP \(http.statusCode))")
        }
        // Most legacy servers answer 202 and reply over the SSE stream, but a
        // few return the JSON-RPC response directly in the POST body.
        if let contentType = http.value(forHTTPHeaderField: "Content-Type"),
           contentType.contains("application/json"),
           !body.isEmpty {
            continuation.yield(body)
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream
    }

    // MARK: - SSE parsing

    /// Reads the byte stream and dispatches SSE events. Parsed manually
    /// (not via `bytes.lines`) because empty lines delimit events and
    /// `AsyncLineSequence` swallows them.
    private func readLoop(_ bytes: URLSession.AsyncBytes) async {
        var lineBuffer = [UInt8]()
        var eventName = ""
        var dataLines: [String] = []

        func dispatchEvent() {
            defer {
                eventName = ""
                dataLines = []
            }
            guard !dataLines.isEmpty else { return }
            handleEvent(name: eventName.isEmpty ? "message" : eventName,
                        data: dataLines.joined(separator: "\n"))
        }

        do {
            for try await byte in bytes {
                guard byte == UInt8(ascii: "\n") else {
                    lineBuffer.append(byte)
                    continue
                }
                var line = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                if line.hasSuffix("\r") { line.removeLast() }

                if line.isEmpty {
                    dispatchEvent()
                } else if line.hasPrefix(":") {
                    continue  // keep-alive comment
                } else if let colon = line.firstIndex(of: ":") {
                    let field = String(line[..<colon])
                    var value = String(line[line.index(after: colon)...])
                    if value.hasPrefix(" ") { value.removeFirst() }
                    switch field {
                    case "event": eventName = value
                    case "data": dataLines.append(value)
                    default: break  // id / retry are irrelevant here
                    }
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func handleEvent(name: String, data: String) {
        switch name {
        case "endpoint":
            guard let url = URL(string: data, relativeTo: sseURL)?.absoluteURL else {
                endpointContinuation?.resume(
                    throwing: MCPError.internalError("Invalid SSE endpoint: \(data)")
                )
                endpointContinuation = nil
                return
            }
            postURL = url
            endpointContinuation?.resume(returning: url)
            endpointContinuation = nil

        case "message":
            continuation.yield(Data(data.utf8))

        default:
            break  // other event types are irrelevant to this transport
        }
    }

    private func failEndpointWait() {
        endpointContinuation?.resume(
            throwing: MCPError.internalError("Timed out waiting for SSE endpoint event")
        )
        endpointContinuation = nil
    }
}
