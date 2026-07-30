import SwiftUI
import UniformTypeIdentifiers

/// Export-only document holding raw image bytes (no re-encode, so format and
/// metadata survive the round trip).
struct DataFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// One standalone Markdown image (`![alt](url)`). Remote URLs load via
/// AsyncImage; `data:image/…;base64,` URLs are decoded locally with a MIME
/// check and a payload cap. The save button exports the original bytes —
/// decoded immediately for data URLs, fetched on demand for remote ones.
struct InlineImageView: View {
    let alt: String
    let urlString: String

    /// Base64 chars, ≈9 MB decoded. Keeps a hostile payload from blocking
    /// the main thread on decode.
    private static let maxDataURLBase64Length = 12 << 20

    @State private var showExporter = false
    @State private var exportDocument: DataFileDocument?
    @State private var exportFilename = "image"
    @State private var exportType: UTType = .png
    @State private var isFetching = false

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                saveButton
                    .padding(8)
            }
            .fileExporter(
                isPresented: $showExporter,
                document: exportDocument,
                contentType: exportType,
                defaultFilename: exportFilename
            ) { _ in }
    }

    @ViewBuilder
    private var content: some View {
        if let payload = dataPayload {
            framed(Image(imageData: payload.data))
        } else if let url = URL(string: urlString),
                  url.scheme == "https" || url.scheme == "http" {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    framed(image)
                case .failure:
                    fallback
                default:
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.surfaceRaised)
                        .frame(maxWidth: .infinity)
                        .frame(height: 160)
                        .overlay { ProgressView() }
                }
            }
        } else {
            fallback
        }
    }

    private func framed(_ image: Image?) -> some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
    }

    private var fallback: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text(alt.isEmpty ? urlString : alt)
                .font(Theme.Typography.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var saveButton: some View {
        if isFetching {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .background(.regularMaterial, in: Circle())
        } else {
            Button(action: save) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .padding(8)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Save image")
            .accessibilityLabel(Text("Save image"))
        }
    }

    private func save() {
        if let payload = dataPayload {
            present(data: payload.data, type: payload.type)
        } else if let url = URL(string: urlString) {
            isFetching = true
            Task {
                defer { isFetching = false }
                guard let (data, response) = try? await URLSession.shared.data(from: url) else { return }
                let mime = response.mimeType ?? ""
                let type = UTType(mimeType: mime)
                    ?? UTType(filenameExtension: url.pathExtension)
                    ?? .png
                present(data: data, type: type)
            }
        }
    }

    @MainActor
    private func present(data: Data, type: UTType) {
        exportDocument = DataFileDocument(data: data)
        exportType = type
        exportFilename = defaultFilename
        showExporter = true
    }

    private var defaultFilename: String {
        let stamp = Date.now.formatted(
            .verbatim(
                "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)",
                timeZone: .current, calendar: .current
            )
        )
        return "image-\(stamp)"
    }

    // MARK: - data: URLs

    private struct DataPayload {
        let data: Data
        let type: UTType
    }

    /// Process-wide decode cache, same rationale as AttachmentThumbnail's:
    /// LazyVStack recreates rows on scroll, and the decode must not repeat.
    @MainActor
    private enum DecodedPayloadCache {
        final class Box {
            let payload: DataPayload?
            init(_ payload: DataPayload?) { self.payload = payload }
        }
        static let shared: NSCache<NSString, Box> = {
            let cache = NSCache<NSString, Box>()
            cache.countLimit = 32
            cache.totalCostLimit = 64 << 20
            return cache
        }()
    }

    private var dataPayload: DataPayload? {
        let key = urlString as NSString
        if let hit = DecodedPayloadCache.shared.object(forKey: key) { return hit.payload }
        let payload = Self.decodeDataURL(urlString)
        DecodedPayloadCache.shared.setObject(.init(payload), forKey: key, cost: urlString.utf8.count)
        return payload
    }

    private static func decodeDataURL(_ string: String) -> DataPayload? {
        guard string.lowercased().hasPrefix("data:image/") else { return nil }
        guard let comma = string.firstIndex(of: ",") else { return nil }
        let meta = string[string.index(string.startIndex, offsetBy: 5)..<comma]
        let parts = meta.split(separator: ";")
        guard parts.count == 2, parts[1] == "base64" else { return nil }
        let base64 = string[string.index(after: comma)...]
        guard base64.count <= maxDataURLBase64Length,
              let data = Data(base64Encoded: String(base64)) else { return nil }
        let type = UTType(mimeType: String(parts[0])) ?? .png
        return DataPayload(data: data, type: type)
    }
}
