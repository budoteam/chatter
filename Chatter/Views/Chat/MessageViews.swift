import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Pasteboard

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Message actions (resend / copy / delete)

/// Subtle icon row shown under a message. `onResend` and `onSelectText` are
/// optional — pass nil to omit the action. Select-text is iOS-only in
/// practice: SwiftUI Text can't do range selection there, so ChatView opens
/// the message in a `SelectableTextSheet`; on macOS inline selection works.
struct MessageActionBar: View {
    var onResend: (() -> Void)?
    let onCopy: () -> Void
    var onSelectText: (() -> Void)?
    let onDelete: () -> Void

    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            if let onResend {
                actionButton("arrow.clockwise", help: "Resend") { onResend() }
            }
            actionButton(copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                onCopy()
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            if let onSelectText {
                actionButton("text.viewfinder", help: "Select Text") { onSelectText() }
            }
            actionButton("trash", help: "Delete") { onDelete() }
        }
        .foregroundStyle(.tertiary)
    }

    private func actionButton(
        _ systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - User

struct UserBubble: View {
    let message: Message

    private var attachments: [ImageAttachment] { message.imageAttachments }
    private var hasText: Bool { !message.content.isEmpty }

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    ForEach(attachments) { attachment in
                        AttachmentThumbnail(base64: attachment.base64, size: 160)
                    }
                }
                if hasText {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(
                            Theme.userBubble,
                            in: UnevenRoundedRectangle(
                                topLeadingRadius: 20, bottomLeadingRadius: 20,
                                bottomTrailingRadius: 6, topTrailingRadius: 20,
                                style: .continuous
                            )
                        )
                }
            }
        }
    }
}

// MARK: - Assistant (final answer)

struct AssistantMessage: View {
    let message: Message

    private var agent: Agent? { message.session?.agent }
    private var thinking: String { message.thinking ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentBadge(
                symbol: agent?.iconSymbol ?? "sparkles",
                color: agent?.color ?? Theme.accent,
                size: 26
            )
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                if !thinking.isEmpty {
                    ThoughtsDisclosure(
                        text: thinking,
                        isThinking: message.isStreaming && message.content.isEmpty
                    )
                }
                if message.content.isEmpty && message.isStreaming && thinking.isEmpty {
                    TypingIndicator().padding(.top, 6)
                } else if !message.content.isEmpty {
                    MarkdownText(text: message.content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Thoughts (reasoning trace, collapsed once done)

struct ThoughtsDisclosure: View {
    let text: String
    /// True while the model is still reasoning — keeps the trace visible live.
    var isThinking: Bool = false

    @State private var expanded = false

    private var isOpen: Bool { expanded || isThinking }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 10, weight: .medium))
                    Text(isThinking ? "Thinking…" : "Thoughts")
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                MarkdownText(text: text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.separator)
                            .frame(width: 3)
                    }
            }
        }
        // Matches scrollToBottom's curve so the auto-collapse (isThinking →
        // false) and the re-pin scroll compose instead of jumping.
        .animation(.easeOut(duration: 0.2), value: isOpen)
    }
}

// MARK: - Activity group (tool steps of one turn, collapsed once finished)

/// Wraps the intermediate steps of an agentic turn — assistant snippets, tool
/// calls, and tool results. Expanded while running; collapses to a one-line
/// summary as soon as the final answer arrives.
struct ActivityGroupView: View {
    let steps: [Message]
    let live: Bool

    @State private var expanded = false

    private var toolCallCount: Int {
        steps.filter { $0.role == .tool }.count
    }

    private var isOpen: Bool { expanded || live }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    if live {
                        ProgressView().controlSize(.small)
                        Text("Working — running tools…")
                    } else {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 10, weight: .medium))
                        Text(toolCallCount == 1 ? "Used 1 tool" : "Used \(toolCallCount) tools")
                    }
                    Spacer(minLength: 0)
                    if !live {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(steps) { StepView(message: $0) }
                }
                .padding(.top, 12)
            }
        }
        .padding(12)
        .background(
            Theme.surfaceRaised.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .padding(.leading, 36)  // aligns with the assistant text column
        // Matches scrollToBottom's curve so the auto-collapse (live → false)
        // and the re-pin scroll compose instead of jumping.
        .animation(.easeOut(duration: 0.2), value: isOpen)
    }
}

/// One intermediate step inside an activity group.
private struct StepView: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let thinking = message.thinking, !thinking.isEmpty {
                    ThoughtsDisclosure(
                        text: thinking,
                        isThinking: message.isStreaming && message.content.isEmpty
                    )
                }
                if !message.content.isEmpty {
                    MarkdownText(text: message.content)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(message.toolCalls) { call in
                    ToolCallCard(call: call)
                }
            }
        case .tool:
            ToolResultCard(message: message)
        default:
            EmptyView()
        }
    }
}

// MARK: - Tool call (requested by the model)

struct ToolCallCard: View {
    let call: ToolCall

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.caption2)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.caption.weight(.medium))
                if !call.argumentsJSON.isEmpty && call.argumentsJSON != "{}" {
                    Text(call.argumentsJSON)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var displayName: String {
        call.name.replacingOccurrences(of: "__", with: " › ")
    }
}

// MARK: - Tool result (returned to the model)

struct ToolResultCard: View {
    let message: Message
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(message.content)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(10)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var displayName: String {
        "Result: " + (message.toolName ?? "tool").replacingOccurrences(of: "__", with: " › ")
    }
}
