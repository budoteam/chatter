#if os(iOS)
import SwiftUI
import UIKit

/// "Select Text" sheet: shows a message's raw markdown in a `UITextView`, the
/// UIKit escape hatch for real range selection (handles, loupe, partial
/// copy) — SwiftUI's `Text` on iOS only offers whole-block copy via
/// long-press, no matter what `.textSelection` says. macOS doesn't need this;
/// there the same modifier gives full mouse selection inline.
struct SelectableTextSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Read-only, selectable `UITextView` filling the sheet. No self-sizing
/// needed — the text view owns the full area and scrolls itself.
private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        view.alwaysBounceVertical = true
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
#endif
