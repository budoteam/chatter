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

    private var image: Image? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return Image(imageData: data)
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
