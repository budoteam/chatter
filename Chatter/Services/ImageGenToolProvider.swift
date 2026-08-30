import Foundation
import SwiftData

/// Built-in image generation tool: the model asks for an image, the tool
/// generates it via OpenRouter and attaches it to a dedicated assistant
/// message so it renders prominently in the timeline (tool results render
/// collapsed inside the activity group).
@MainActor
final class ImageGenToolProvider {
    static let generateToolName = "imagegen__generate"

    /// Hard cap per call: each image is stored inline in the message record,
    /// which must stay well under CloudKit's ~1 MB record limit (see
    /// `ImageAttachment.maxBase64BytesPerMessage`).
    static let maxImagesPerCall = 2

    /// How many of the newest user-attached images are forwarded as editing
    /// input (image-to-image).
    private static let maxInputImages = 3

    /// Recompression target for generated images. OpenRouter image models
    /// return full-size PNGs (often >1 MB Base64) — far over the per-message
    /// record budget — so every image is re-encoded as a downscaled JPEG
    /// before persisting.
    private static let storedMaxEdge: CGFloat = 1024

    private let service: OpenRouterImageService

    init(service: OpenRouterImageService = OpenRouterImageService()) {
        self.service = service
    }

    enum ToolError: LocalizedError {
        case unknownTool(String)
        case missingArgument(String)
        /// Recompression failed for every returned image (undecodable data).
        case noUsableImages

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): return "Unknown image tool “\(name)”."
            case .missingArgument(let name): return "Missing required argument “\(name)”."
            case .noUsableImages: return "The image model returned data that could not be decoded as an image."
            }
        }
    }

    // MARK: - System prompt

    static let systemPromptSection = """
        You can generate images with the \(generateToolName) tool. Use it whenever \
        the user asks for an image, picture, drawing or photo. Write the prompt as \
        a precise visual description (subject, style, composition, colors) — do not \
        ask the user first unless the request is genuinely ambiguous. When the user \
        attached image(s) and asks to change, edit or restyle them, call the tool \
        with the edit instruction: the newest attached image(s) are automatically \
        sent to the image model as editing input. The resulting image appears in \
        the chat automatically; you cannot see its contents, so answer with a \
        one-line confirmation instead of describing the result.
        """

    // MARK: - Tool definitions

    func tools() -> [OllamaTool] {
        [OllamaTool(function: .init(
            name: Self.generateToolName,
            description: "Generate an image from a text prompt, or edit/restyle the user's attached image(s) — those are automatically included as input when present. The image is shown to the user in the chat automatically. Use this whenever the user asks for an image, picture, drawing or photo.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("A precise visual description of the image: subject, style, composition, colors."),
                    ]),
                    "count": .object([
                        "type": .string("integer"),
                        "description": .string("How many variants to generate (1 or 2). Defaults to 1."),
                    ]),
                ]),
                "required": .array([.string("prompt")]),
            ])
        ))]
    }

    // MARK: - Dispatch

    /// Generates the requested image(s) and inserts them as an assistant
    /// message with attachments (the visible artifact), then returns the
    /// confirmation string that becomes the tool result.
    func call(
        name: String,
        argumentsJSON: String,
        session: ChatSession,
        context: ModelContext
    ) async throws -> String {
        guard name == Self.generateToolName else { throw ToolError.unknownTool(name) }
        let parsed = JSONValue.parse(argumentsJSON)
        guard let prompt = parsed.stringArguments["prompt"], !prompt.isEmpty else {
            throw ToolError.missingArgument("prompt")
        }
        // `stringArguments` drops non-string values, so count is read from
        // the parsed object directly (same pattern as artifact's `replace`).
        var count = 1
        if case .object(let object) = parsed, case .number(let n) = object["count"] {
            count = Int(n)
        }
        count = min(max(count, 1), Self.maxImagesPerCall)

        // Image-to-image: forward the newest attached image(s) as editing
        // input — the intuitive flow is «attach a photo, ask for the edit»,
        // and after a generation «now make it darker» iterates on the just-
        // generated image (assistant attachments only ever come from this
        // tool, so role doesn't matter here).
        let inputImages = Array(
            (session.orderedMessages.last {
                !$0.imageAttachments.isEmpty
            }?.imageAttachments.map(\.base64) ?? []).suffix(Self.maxInputImages)
        )

        var base64s: [String] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            base64s.append(contentsOf: try await service.generateImages(prompt: prompt, images: inputImages))
            if base64s.count >= Self.maxImagesPerCall { break }
        }
        base64s = Array(base64s.prefix(Self.maxImagesPerCall))

        // Recompress: the raw payloads would blow the per-message CloudKit
        // record budget; undecodable payloads are dropped.
        let attachments = base64s.compactMap { base64 -> ImageAttachment? in
            guard let data = Data(base64Encoded: base64),
                  let jpeg = ImageAttachmentProcessor.makeBase64JPEG(
                      from: data, maxEdge: Self.storedMaxEdge
                  ) else { return nil }
            return ImageAttachment(base64: jpeg)
        }
        guard !attachments.isEmpty else { throw ToolError.noUsableImages }
        let stored = Self.fitToBudget(attachments)

        let message = Message(
            role: .assistant, content: "", orderIndex: session.nextOrderIndex
        )
        message.imageAttachments = stored
        message.session = session
        context.insert(message)
        session.updatedAt = .now
        context.saveOrLog()

        let noun = stored.count == 1 ? "image" : "images"
        return "Generated \(stored.count) \(noun) — already visible in the chat. You cannot see the image contents yourself; confirm briefly instead of describing it."
    }

    /// Keeps the stored payloads within `ImageAttachment.maxBase64BytesPer`
    /// `Message` — two detailed 1024 px JPEGs can exceed it together, and an
    /// oversized message record would stall CloudKit sync of the whole chat.
    /// Over-budget images are re-encoded smaller; anything that still doesn't
    /// fit is dropped (the first image is always kept, even shrunk hard).
    private static func fitToBudget(_ attachments: [ImageAttachment]) -> [ImageAttachment] {
        let budget = ImageAttachment.maxBase64BytesPerMessage
        var stored: [ImageAttachment] = []
        var used = 0
        for attachment in attachments {
            var base64 = attachment.base64
            if used + base64.utf8.count > budget,
               let data = Data(base64Encoded: base64),
               let smaller = ImageAttachmentProcessor.makeBase64JPEG(
                   from: data, maxEdge: 512, quality: 0.5
               ) {
                base64 = smaller
            }
            if used + base64.utf8.count > budget, !stored.isEmpty { break }
            used += base64.utf8.count
            stored.append(ImageAttachment(base64: base64))
        }
        return stored
    }
}
