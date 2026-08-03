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
    /// False when the message's thinking stayed in the preceding activity
    /// group (final answer of a tool loop) — rendering the trace here too
    /// would duplicate it.
    var showsThinking: Bool = true

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
                if showsThinking && !thinking.isEmpty {
                    ThinkingTraceView(
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

// MARK: - Thoughts (reasoning trace, always visible in a fixed-height box)

/// The reasoning trace: permanently visible in a fixed-height box that
/// follows the tail while the model thinks. The expand button opens a sheet
/// with the full text — no collapse/expand animation in the transcript.
struct ThinkingTraceView: View {
    let text: String
    /// True while the model is still reasoning (streams, no content yet) —
    /// the box follows the tail; afterwards it stays where it is.
    var isThinking: Bool = false
    var height: CGFloat = 140

    @State private var showingFull = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 10, weight: .medium))
                Text(isThinking ? "Thinking…" : "Thoughts")
                Spacer(minLength: 0)
                Button { showingFull = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show full trace")
                .accessibilityLabel(Text("Show full trace"))
            }
            .font(Theme.Typography.font(.caption).weight(.medium))
            .foregroundStyle(.secondary)

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
                .onAppear { if isThinking { pinToTail(proxy) } }
                .onChange(of: text.count) { if isThinking { pinToTail(proxy) } }
            }
            .frame(height: height)
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.separator)
                .frame(width: 3)
        }
        .sheet(isPresented: $showingFull) {
            EditorSheet(
                title: "Thoughts",
                minWidth: 520, minHeight: 480,
                trailing: {
                    Button("Done") { showingFull = false }
                        .keyboardShortcut(.defaultAction)
                }
            ) {
                ScrollView {
                    MarkdownText(text: text)
                        .font(Theme.Typography.font(.body))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
    }

    private func pinToTail(_ proxy: ScrollViewProxy) {
        // disablesAnimations — same reason as ChatView.scrollToBottom: the
        // scroll must not inherit a transaction already in flight.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo("tail", anchor: .bottom) }
    }
}

// MARK: - Activity group (tool steps of one turn, permanently visible)

/// Wraps the intermediate steps of an agentic turn — assistant snippets, tool
/// calls, and tool results. The step stream stays visible in a box with a
/// fixed max height (no collapse, no transcript re-layout per round); the
/// expand button opens a sheet with the full activity.
struct ActivityGroupView: View {
    let steps: [Message]
    /// Thinking of the final answer round — it lived in this stream while
    /// the turn ran, so it stays here (dimmed, at the end) instead of
    /// popping out into a second box under the group.
    var trailingThinking: String? = nil
    let live: Bool
    var accent: Color = Theme.accent

    @State private var showingFull = false

    private var toolCallCount: Int {
        steps.filter { $0.role == .tool }.count
    }

    /// ToolCall ids of `artifact__create` calls across all steps — their
    /// pills stay visible below the box, so the generated file remains one
    /// tap away.
    private var artifactCallIDs: [String] {
        steps.flatMap { $0.toolCalls }
            .filter { $0.name == ArtifactToolProvider.createToolName }
            .map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
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
                    Button { showingFull = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show full activity")
                    .accessibilityLabel(Text("Show full activity"))
                }
                .font(Theme.Typography.font(.caption).weight(.medium))
                .foregroundStyle(.secondary)

                ActivityStepsScroll(steps: steps, trailingThinking: trailingThinking, followTail: live)
                    .frame(maxHeight: 320)
                    .padding(.top, 12)
            }
            .padding(12)
            .background(
                Theme.surfaceRaised.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

            if !artifactCallIDs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(artifactCallIDs, id: \.self) { callID in
                        ArtifactPillLoader(sourceToolCallID: callID, accent: accent)
                    }
                }
            }
        }
        .padding(.leading, 36)  // aligns with the assistant text column
        .sheet(isPresented: $showingFull) {
            EditorSheet(
                title: "Turn activity",
                minWidth: 520, minHeight: 480,
                trailing: {
                    Button("Done") { showingFull = false }
                        .keyboardShortcut(.defaultAction)
                }
            ) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(steps) { StepView(message: $0) }
                        if let trailingThinking {
                            MarkdownText(text: trailingThinking)
                                .font(Theme.Typography.font(.callout))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

/// The always-visible step stream of an activity group: fixed max height so
/// growth no longer pushes the transcript around; follows the tail while the
/// turn runs. The full content is one tap away via the group's sheet.
private struct ActivityStepsScroll: View {
    let steps: [Message]
    var trailingThinking: String? = nil
    let followTail: Bool

    /// Growth of the trailing step (streaming content/thinking, persisted
    /// tool calls) plus step count — drives the tail re-pin.
    private var fingerprint: String {
        let last = steps.last
        return "\(steps.count)|\(last?.content.count ?? 0)|\(last?.thinking?.count ?? 0)|\(last?.toolCallsJSON?.count ?? 0)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(steps) { StepView(message: $0) }
                    if let trailingThinking {
                        MarkdownText(text: trailingThinking)
                            .font(Theme.Typography.font(.callout))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
            }
            .onAppear { if followTail { pinToTail(proxy) } }
            .onChange(of: fingerprint) { if followTail { pinToTail(proxy) } }
        }
    }

    private func pinToTail(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo("tail", anchor: .bottom) }
    }
}

/// One intermediate step inside an activity group.
private struct StepView: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                // Thinking runs inline, dimmed, in the step stream (omp
                // style) — no nested scroll box inside the 320pt group box.
                if let thinking = message.thinking, !thinking.isEmpty {
                    MarkdownText(text: thinking)
                        .font(Theme.Typography.font(.callout))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
    var accent: Color = Theme.accent
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: artifact.kind.iconName)
                    .font(Theme.Typography.font(.callout))
                    .foregroundStyle(accent)
                Text(artifact.name)
                    .font(Theme.Typography.font(.callout).weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizeString)
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.square")
                    .font(Theme.Typography.font(.callout))
                    .foregroundStyle(accent)
            }
            .padding(10)
            .background(
                accent.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(0.35), lineWidth: 1)
            )
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

    let accent: Color

    init(sourceToolCallID: String, accent: Color) {
        self.accent = accent
        _artifacts = Query(
            filter: #Predicate<Artifact> { $0.sourceToolCallID == sourceToolCallID },
            sort: \.createdAt
        )
    }

    var body: some View {
        ForEach(artifacts) { artifact in
            ArtifactPill(artifact: artifact, accent: accent) {
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

// MARK: - Turn phase status (e.g. vision describe before the first token)

/// Status row for engine phases that produce no assistant message yet —
/// without it a long vision describe looks like the app hung.
struct TurnPhaseRow: View {
    let phase: ChatEngine.TurnPhase

    var body: some View {
        switch phase {
        case .describingImages(let model, let current, let total):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(total > 1
                    ? "Describing attached images with \(model) (\(current)/\(total))…"
                    : "Describing attached images with \(model)…")
            }
            .font(Theme.Typography.font(.caption).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 36)  // assistant column, same as ActivityGroupView
        }
    }
}
