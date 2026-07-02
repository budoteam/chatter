import SwiftUI

/// Renders one persisted message according to its role.
struct MessageRow: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(text: message.content)
        case .assistant:
            AssistantMessage(message: message)
        case .tool:
            ToolResultCard(message: message)
        case .system:
            EmptyView()
        }
    }
}

// MARK: - User

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
    }
}

// MARK: - Assistant

private struct AssistantMessage: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentBadge(symbol: "sparkles", color: Theme.accent, size: 28)
            VStack(alignment: .leading, spacing: 8) {
                if message.content.isEmpty && message.isStreaming {
                    TypingIndicator().padding(.top, 6)
                } else {
                    Text(Self.markdown(message.content))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(message.toolCalls) { call in
                    ToolCallCard(call: call)
                }
            }
            Spacer(minLength: 0)
        }
    }

    static func markdown(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }
}

// MARK: - Tool call (requested by the model)

struct ToolCallCard: View {
    let call: ToolCall

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.caption)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Called \(displayName)")
                    .font(.caption.weight(.medium))
                if !call.argumentsJSON.isEmpty && call.argumentsJSON != "{}" {
                    Text(call.argumentsJSON)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private var displayName: String {
        call.name.replacingOccurrences(of: "__", with: " › ")
    }
}

// MARK: - Tool result (returned to the model)

private struct ToolResultCard: View {
    let message: Message
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Result from \(displayName)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(message.content)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Theme.surfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private var displayName: String {
        (message.toolName ?? "tool").replacingOccurrences(of: "__", with: " › ")
    }
}
