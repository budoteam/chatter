#if os(iOS)
import Foundation

/// Attachments handed over from the share extension via the app group
/// container; processed into composer drafts on the next app activation.
struct SharedAttachmentPayload {
    /// Base64 JPEGs, ready for `ChatViewModel.addBase64Images`.
    var images: [String] = []
    var documents: [DocumentDraft] = []
    /// True when at least one shared item could not be processed.
    var failed = false

    var isEmpty: Bool { images.isEmpty && documents.isEmpty && !failed }
}

/// Drain point for the share extension's app-group inbox: the extension
/// writes one subdirectory per share session (raw payload files plus a
/// `manifest.json`, written last), the main app reads and removes batches
/// here. Processing (PDF extraction/OCR, image re-encoding) happens in the
/// main app so the extension stays a thin copy-only binary.
enum SharedInbox {
    static let appGroupID = "group.team.budo.chatter"

    /// Kept in sync with the extension's `ManifestEntry`.
    private struct Entry: Codable {
        let file: String
        let name: String
        let isImage: Bool
    }

    private static var inboxDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("ShareInbox", isDirectory: true)
    }

    /// Reads and removes all pending batches. Returns nil when the inbox is
    /// empty. PDF extraction/OCR is CPU-bound — call from a Task.
    static func drain() async -> SharedAttachmentPayload? {
        guard let inbox = inboxDirectory,
              let batches = try? FileManager.default.contentsOfDirectory(atPath: inbox.path),
              !batches.isEmpty else { return nil }

        var payload = SharedAttachmentPayload()
        for batch in batches {
            let dir = inbox.appendingPathComponent(batch, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let manifestData = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let entries = try? JSONDecoder().decode([Entry].self, from: manifestData)
            else { continue }
            for entry in entries {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(entry.file)) else {
                    payload.failed = true
                    continue
                }
                if entry.isImage {
                    if let base64 = ImageAttachmentProcessor.makeBase64JPEG(from: data) {
                        payload.images.append(base64)
                    } else {
                        payload.failed = true
                    }
                } else {
                    let name = entry.name
                    if let draft = await Task.detached(operation: {
                        PDFAttachmentProcessor.makeDraft(from: data, fileName: name)
                    }).value {
                        payload.documents.append(draft)
                    } else {
                        payload.failed = true
                    }
                }
            }
        }
        return payload
    }
}
#endif
