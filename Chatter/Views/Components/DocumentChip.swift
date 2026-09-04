import SwiftUI

/// A compact capsule representing an attached PDF: document icon, file name,
/// page count (plus OCR / truncated hints). With `onRemove` set it shows a
/// delete badge (composer); otherwise it's static (message history).
struct DocumentChip: View {
    let document: DocumentAttachment
    var onRemove: (() -> Void)? = nil

    private var subtitle: String {
        var parts = ["\(document.pageCount) " + (document.pageCount == 1 ? "page" : "pages")]
        if document.usedOCR { parts.append("OCR") }
        if document.truncated { parts.append("truncated") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.fileName)
                    .font(Theme.Typography.font(.caption).weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.secondary)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove \(document.fileName)"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
    }
}
