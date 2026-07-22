import SwiftUI
import SwiftData
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

    var body: some View {
        HStack(spacing: 4) {
            if let onResend {
                actionButton("arrow.clockwise", help: "Resend") { onResend() }
            }
            CopyButton(help: "Copy") { onCopy() }
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
        // Icon-only button: .help is no VoiceOver label (it would read the
        // SF Symbol name out loud).
        .accessibilityLabel(Text(help))
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
                        .font(Theme.Typography.font(.body))
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
                .font(Theme.Typography.font(.caption).weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Group {
                    if isThinking {
                        LiveThinkingTrace(text: text)
                    } else {
                        // Capped even when deliberately opened: huge traces
                        // must not shove the whole chat around either.
                        ScrollView {
                            MarkdownText(text: text)
                                .font(Theme.Typography.font(.callout))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 400)
                    }
                }
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
        .animation(Theme.Motion.Easing.standard, value: isOpen)
    }
}

/// The live reasoning trace while the model thinks: a fixed-height window
/// that auto-follows the tail of the trace. The growing text scrolls by
/// inside the box instead of pushing the whole chat viewport down on every
/// streaming flush; the box itself stays scrollable by hand.
private struct LiveThinkingTrace: View {
    let text: String
    var height: CGFloat = 140

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    MarkdownText(text: text)
                        .font(Theme.Typography.font(.callout))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("tail")
                }
            }
            .onAppear { pinToTail(proxy) }
            .onChange(of: text.count) { pinToTail(proxy) }
        }
        .frame(height: height)
    }

    private func pinToTail(_ proxy: ScrollViewProxy) {
        // disablesAnimations, not just "no withAnimation" — same reason as
        // ChatView.scrollToBottom: the scroll must not inherit a transaction
        // that is already in flight (e.g. the disclosure's own collapse).
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo("tail", anchor: .bottom) }
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

    /// ToolCall ids of `artifact__create` calls across all steps — their
    /// pills stay visible even after the group collapses, so the generated
    /// file remains one tap away.
    private var artifactCallIDs: [String] {
        steps.flatMap { $0.toolCalls }
            .filter { $0.name == ArtifactToolProvider.createToolName }
            .map(\.id)
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
                .font(Theme.Typography.font(.caption).weight(.medium))
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

            if !artifactCallIDs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(artifactCallIDs, id: \.self) { callID in
                        ArtifactPillLoader(sourceToolCallID: callID)
                    }
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
        .animation(Theme.Motion.Easing.standard, value: isOpen)
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
                        .font(Theme.Typography.font(.callout))
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

// MARK: - Artifact pill (opens the side panel / sheet)

/// Clickable file chip shown for every `artifact__create` call; tapping it
/// opens the artifact in the inspector (macOS) or a sheet (iOS).
struct ArtifactPill: View {
    let artifact: Artifact
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: artifact.kind.iconName)
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(Theme.accent)
                Text(artifact.name)
                    .font(Theme.Typography.font(.caption).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizeString)
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.square")
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sizeString: String {
        String(format: "%.1f KB", Double(artifact.content.utf8.count) / 1000)
    }
}

/// Resolves the artifact belonging to one `artifact__create` ToolCall and
/// renders its pill. A loader (rather than passing the artifact down) keeps
/// the pill live across CloudKit merges and replace-updates.
private struct ArtifactPillLoader: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var artifacts: [Artifact]

    init(sourceToolCallID: String) {
        _artifacts = Query(
            filter: #Predicate<Artifact> { $0.sourceToolCallID == sourceToolCallID },
            sort: \.createdAt
        )
    }

    var body: some View {
        ForEach(artifacts) { artifact in
            ArtifactPill(artifact: artifact) {
                env.openArtifactID = artifact.persistentModelID
            }
        }
    }
}

// MARK: - Tool call (requested by the model)

struct ToolCallCard: View {
    let call: ToolCall

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(Theme.Typography.font(.caption))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(Theme.Typography.font(.caption).weight(.medium))
                if !call.argumentsJSON.isEmpty && call.argumentsJSON != "{}" {
                    Text(call.argumentsJSON)
                        .font(Theme.Typography.font(.monoSmall))
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

    /// `artifact__create` results are just a confirmation line — the file
    /// itself is shown via the pill and panel, so the raw result box (and
    /// its expand toggle) would only duplicate it.
    private var isArtifactResult: Bool {
        message.toolName == ArtifactToolProvider.createToolName
    }

    var body: some View {
        if isArtifactResult {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.green)
                Text(message.content)
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            regularBody
        }
    }

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(Theme.Motion.Easing.standard) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(Theme.Typography.font(.caption))
                        .foregroundStyle(.secondary)
                    Text(displayName)
                        .font(Theme.Typography.font(.caption).weight(.medium))
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
                        .font(Theme.Typography.font(.monoSmall))
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
