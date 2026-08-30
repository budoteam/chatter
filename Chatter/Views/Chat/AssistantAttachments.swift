import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Images attached to an assistant message (produced by the imagegen tool):
/// shown aspect-preserving in the transcript; a tap opens the full-screen
/// viewer with share/save.
struct AssistantAttachments: View {
    let attachments: [ImageAttachment]

    @State private var fullScreen: ImageAttachment?

    var body: some View {
        ForEach(attachments) { attachment in
            if let image = DecodedImageCache.image(for: attachment.base64) {
                Button { fullScreen = attachment } label: {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 320, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.separator, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Generated image. Activate to view full screen."))
            }
        }
        .sheet(item: $fullScreen) { attachment in
            FullScreenImageSheet(attachment: attachment)
        }
    }
}

/// Full-screen view of one generated image, with share and (iOS) save to
/// the photo library.
private struct FullScreenImageSheet: View {
    let attachment: ImageAttachment

    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    private var image: Image? { DecodedImageCache.image(for: attachment.base64) }

    var body: some View {
        EditorSheet(
            title: "Generated Image",
            minWidth: 480, minHeight: 480,
            trailing: {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        ) {
            VStack(spacing: 16) {
                if let image {
                    image
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal)
                    HStack(spacing: 20) {
                        ShareLink(
                            item: image,
                            preview: SharePreview("Generated image", image: image)
                        ) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        #if canImport(UIKit)
                        Button { saveToPhotos() } label: {
                            Label(
                                saved ? "Saved" : "Save Image",
                                systemImage: saved ? "checkmark" : "square.and.arrow.down"
                            )
                        }
                        .disabled(saved)
                        #endif
                    }
                    .padding(.bottom)
                } else {
                    Text("The image data could not be decoded.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    #if canImport(UIKit)
    private func saveToPhotos() {
        guard let data = Data(base64Encoded: attachment.base64),
              let uiImage = UIImage(data: data) else { return }
        UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
        saved = true
    }
    #endif
}
