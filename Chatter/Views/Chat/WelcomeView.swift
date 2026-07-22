import SwiftUI

/// Shown when no session is selected — Gemini-style centered greeting with
/// quick-start suggestion cards.
struct WelcomeView: View {
    var onNewChat: () -> Void
    /// Called with a starter prompt when a suggestion chip is tapped.
    var onSuggestion: (String) -> Void

    private let suggestions: [(title: String, icon: String, prompt: String)] = [
        ("Brainstorm ideas", "lightbulb", "Brainstorm ideas for "),
        ("Explain a concept", "book", "Explain the following concept simply: "),
        ("Write some code", "chevron.left.forwardslash.chevron.right", "Write code that "),
        ("Summarize text", "text.alignleft", "Summarize the following text:\n\n"),
    ]

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            VStack(spacing: 10) {
                GradientText(text: "Hello there", font: .system(size: 40, weight: .semibold))
                Text("How can I help you today?")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(suggestions, id: \.title) { suggestion in
                    Button { onSuggestion(suggestion.prompt) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: suggestion.icon)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.accent)
                            Text(suggestion.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Theme.separator, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 440)

            Button(action: onNewChat) {
                Label("New Chat", systemImage: "plus.bubble.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(Theme.accentFill, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()
            Spacer()
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
