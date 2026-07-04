import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

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
}
