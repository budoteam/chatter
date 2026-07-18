import SwiftUI

/// Icon-only copy button with a transient checkmark confirmation. Shared by
/// the message action bar and code blocks. Rapid re-taps cancel the pending
/// reset so the checkmark never flips back early, and the button carries a
/// real accessibility label — icon-only buttons otherwise read the SF Symbol
/// name to VoiceOver.
struct CopyButton: View {
    let help: String
    let action: () -> Void

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            action()
            copied = true
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
