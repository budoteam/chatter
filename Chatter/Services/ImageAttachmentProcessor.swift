import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Turns picked image `Data` into a downscaled, JPEG-compressed Base64 string
/// ready for Ollama's `images` array.
///
/// Uses ImageIO (`CGImageSource`/`CGImageDestination`) so the same code runs on
/// iOS and macOS without any UIKit/AppKit branching. Downscaling keeps the
/// Base64 payload small enough to persist inline in SwiftData/CloudKit while
/// staying more than detailed enough for vision models.
enum ImageAttachmentProcessor {
    /// Downscales `data` to at most `maxEdge` points on its longest side and
    /// re-encodes it as JPEG at `quality`. Returns raw Base64 (no `data:`
    /// prefix, as Ollama expects), or `nil` if the image can't be decoded.
    static func makeBase64JPEG(
        from data: Data,
        maxEdge: CGFloat = 1568,
        quality: CGFloat = 0.7
    ) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honor EXIF orientation so portrait photos aren't sent sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        let destOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, thumbnail, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return (output as Data).base64EncodedString()
    }

    /// Loads image payloads from paste/drop providers as downscaled Base64
    /// JPEGs, skipping anything undecodable. In-memory image content
    /// (screenshots, copied images) and dragged/copied image files both
    /// conform to `UTType.image` and arrive as encoded data; providers that
    /// only carry a file URL are read security-scoped below.
    static func makeBase64JPEGs(from providers: [NSItemProvider]) async -> [String] {
        var result: [String] = []
        for provider in providers {
            if let base64 = await loadOne(provider) { result.append(base64) }
        }
        return result
    }

    private static func loadOne(_ provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadImageData(from: provider),
           let base64 = makeBase64JPEG(from: data) {
            return base64
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url: URL = await loadObject(from: provider), url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { return makeBase64JPEG(from: data) }
        }
        return nil
    }

    /// Pure-Foundation image read: the provider coerces its registered
    /// representation (PNG, TIFF, …) into data, no NSImage/UIImage bridging
    /// needed — `makeBase64JPEG` decodes via ImageIO on both platforms.
    private static func loadImageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// The async `loadObject` variant is not visible to Swift on every SDK; wrap
    /// the completion-handler form (Foundation overlay, verified in SDK 26.5).
    private static func loadObject<T>(
        from provider: NSItemProvider
    ) async -> T? where T: _ObjectiveCBridgeable, T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: T.self) { object, _ in
                continuation.resume(returning: object)
            }
        }
    }

#if os(macOS)
    /// Attachable image payloads on `pasteboard`, if any: in-memory images
    /// (screenshots, copied images — NSImage reading also resolves Finder
    /// file copies whose UTI Finder declares) and copied image FILES (by
    /// extension UTI). Returns nil when nothing attachable is present, so the
    /// caller lets the paste fall through to normal text handling.
    static func base64JPEGsFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [String]? {
        var base64s: [String] = []
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            for image in images {
                if let tiff = image.tiffRepresentation,
                   let base64 = makeBase64JPEG(from: tiff) { base64s.append(base64) }
            }
        }
        // Only when NSImage found nothing: Finder copies that declare no
        // image UTI on the pasteboard still expose a file URL; claim them by
        // extension. Skipping this when images exist prevents double-attach.
        if base64s.isEmpty {
            let urls = (pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]) ?? []
            for url in urls {
                guard url.isFileURL,
                      let type = UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .image) else { continue }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url),
                   let base64 = makeBase64JPEG(from: data) { base64s.append(base64) }
            }
        }
        return base64s.isEmpty ? nil : base64s
    }
#endif
}
