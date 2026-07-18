import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Image {
    /// Builds a SwiftUI `Image` from raw image data, cross-platform.
    init?(imageData: Data) {
        #if canImport(UIKit)
        guard let img = UIImage(data: imageData) else { return nil }
        self = Image(uiImage: img)
        #elseif canImport(AppKit)
        guard let img = NSImage(data: imageData) else { return nil }
        self = Image(nsImage: img)
        #else
        return nil
        #endif
    }
}

/// A small rounded preview of a Base64-encoded image attachment. With
/// `onRemove` set it shows a delete badge (composer); otherwise it's a static
/// thumbnail (message history).
struct AttachmentThumbnail: View {
    let base64: String
    var size: CGFloat = 56
    var onRemove: (() -> Void)? = nil

    /// Process-wide decode cache, keyed by the Base64 payload. The
    /// transcript's LazyVStack destroys and recreates rows while scrolling,
    /// so a per-view memoizer re-decoded the full JPEG on the main thread on
    /// every revisit of an image message.
    @MainActor
    private enum DecodedImageCache {
        final class Box {
            let image: Image?
            init(_ image: Image?) { self.image = image }
        }
        static let shared: NSCache<NSString, Box> = {
            let cache = NSCache<NSString, Box>()
            cache.countLimit = 64
            // Cost = Base64 length (~1.3x the JPEG, well under the bitmap).
            cache.totalCostLimit = 64 << 20
            return cache
        }()
    }

    private var image: Image? {
        let key = base64 as NSString
        if let hit = DecodedImageCache.shared.object(forKey: key) { return hit.image }
        let decoded = Data(base64Encoded: base64).flatMap { Image(imageData: $0) }
        DecodedImageCache.shared.setObject(.init(decoded), forKey: key, cost: base64.utf8.count)
        return decoded
    }

    var body: some View {
        if let image {
            image
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if let onRemove {
                        Button(action: onRemove) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, .black.opacity(0.55))
                                .padding(3)
                        }
                        .buttonStyle(.plain)
                    }
                }
        }
    }
}
