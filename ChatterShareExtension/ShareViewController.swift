import UIKit
import UniformTypeIdentifiers

/// Minimal, UI-less share extension: copies shared PDFs and images into the
/// app group's `ShareInbox` and opens the main app (best effort), which
/// turns each batch into a new chat draft on activation. All processing
/// (PDF text extraction/OCR, image re-encoding) lives in the main app.
final class ShareViewController: UIViewController {
    private static let appGroupID = "group.team.budo.chatter"

    /// Kept in sync with `SharedInbox.Entry` in the main app — the extension
    /// is a separate binary and cannot share code.
    private struct ManifestEntry: Codable {
        let file: String
        let name: String
        let isImage: Bool
    }

    private struct Payload {
        let data: Data
        let ext: String
        let name: String
        let isImage: Bool
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handleShare() }
    }

    private func handleShare() async {
        guard let extensionContext else { return }
        defer { extensionContext.completeRequest(returningItems: nil) }
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else { return }

        var payloads: [Payload] = []
        for item in extensionContext.inputItems as? [NSExtensionItem] ?? [] {
            for provider in item.attachments ?? [] {
                if let payload = await Self.loadPayload(from: provider) {
                    payloads.append(payload)
                }
            }
        }
        guard !payloads.isEmpty else { return }

        // One subdirectory per share session: the main app drains batches
        // atomically, so a half-written batch can never be picked up (the
        // manifest is written last and is the drain's entry point).
        let batch = container.appendingPathComponent("ShareInbox/\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
            var manifest: [ManifestEntry] = []
            for payload in payloads {
                let file = "\(UUID().uuidString).\(payload.ext)"
                try payload.data.write(to: batch.appendingPathComponent(file))
                manifest.append(ManifestEntry(file: file, name: payload.name, isImage: payload.isImage))
            }
            try JSONEncoder().encode(manifest).write(to: batch.appendingPathComponent("manifest.json"))
        } catch {
            return
        }

        // Best effort: NSExtensionContext.open is only documented for Today
        // extensions, but works from share extensions on current iOS. If the
        // system refuses, the inbox is drained on the next activation anyway.
        if let url = URL(string: "chatter://share") {
            _ = await extensionContext.open(url)
        }
    }

    /// Loads the first PDF or image representation a provider offers.
    /// Payloads arrive as raw data, file URLs, or (images only) `UIImage`.
    private static func loadPayload(from provider: NSItemProvider) async -> Payload? {
        guard let typeID = provider.registeredTypeIdentifiers.first(where: { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: .pdf) || type.conforms(to: .image)
        }), let type = UTType(typeID) else { return nil }

        let isImage = type.conforms(to: .image)
        let fallbackName = isImage ? "Shared Image" : "Shared PDF"
        guard let raw = try? await provider.loadItem(forTypeIdentifier: typeID) else { return nil }

        switch raw {
        case let data as Data:
            return Payload(
                data: data,
                ext: type.preferredFilenameExtension ?? "bin",
                name: provider.suggestedName ?? fallbackName,
                isImage: isImage
            )
        case let url as URL:
            guard let data = try? Data(contentsOf: url) else { return nil }
            let ext = url.pathExtension.isEmpty
                ? (type.preferredFilenameExtension ?? "bin")
                : url.pathExtension
            return Payload(data: data, ext: ext, name: url.lastPathComponent, isImage: isImage)
        case let image as UIImage:
            guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
            return Payload(
                data: data,
                ext: "jpg",
                name: provider.suggestedName ?? fallbackName,
                isImage: true
            )
        default:
            return nil
        }
    }
}
