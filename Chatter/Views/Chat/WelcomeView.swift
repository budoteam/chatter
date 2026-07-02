import SwiftUI

/// Shown when no session is selected — Gemini-style centered greeting with
/// quick-start suggestion chips.
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
            VStack(spacing: Theme.Spacing.sm) {
                AgentBadge(symbol: "sparkles", color: Theme.accent, size: 64)
                    .shadow(color: Theme.accent.opacity(0.3), radius: 20, y: 8)
                GradientText(text: "Hello there")
                Text("How can I help you today?")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(suggestions, id: \.title) { suggestion in
                    Button { onSuggestion(suggestion.prompt) } label: {
                        HStack {
                            Image(systemName: suggestion.icon).foregroundStyle(Theme.accent)
                            Text(suggestion.title).font(.subheadline)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .stroke(Theme.separator, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 520)

            Button(action: onNewChat) {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Theme.brandGradient, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
