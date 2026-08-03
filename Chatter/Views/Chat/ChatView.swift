import SwiftUI
import SwiftData

struct ChatView: View {
    let session: ChatSession

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var viewModel = ChatViewModel()
    /// Pending deferred scroll — cancelled and replaced on every trigger so
    /// scrolls coalesce instead of stacking overlapping animated transactions.
    @State private var scrollTask: Task<Void, Never>?
    /// True while an image drag hovers the chat — reveals the top-most drop
    /// veil, which re-hit-tests above the composer so AppKit's field editor
    /// can't swallow the drop as a file-link text insertion.
    @State private var dropTargeted = false
    #if os(iOS)
    /// Message shown in the select-text sheet — SwiftUI Text can't do range
    /// selection on iOS, so this opens the raw text in a UITextView.
    @State private var selectingMessage: Message?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            transcript
            ComposerView(viewModel: viewModel, session: session, onSend: send)
        }
        .onDrop(of: [.image], isTargeted: $dropTargeted) { handleImageDrop($0) }
        .overlay {
            if dropTargeted && viewModel.canAttachImages {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    }
                    .overlay {
                        Label("Drop images to attach", systemImage: "photo.badge.plus")
                            .font(Theme.Typography.font(.title2))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(6)
                    .onDrop(of: [.image], isTargeted: nil) { handleImageDrop($0) }
            }
        }
        .navigationTitle(session.title.isEmpty ? "New Chat" : session.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let agent = session.agent {
                    HStack(spacing: 7) {
                        AgentBadge(symbol: agent.iconSymbol, color: agent.color, size: 20)
                        Text(agent.name).font(Theme.Typography.font(.title2))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear {
            if let prompt = env.pendingPrompt {
                viewModel.inputText = prompt
                env.pendingPrompt = nil
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        #if os(iOS)
        .sheet(item: $selectingMessage) { message in
            SelectableTextSheet(text: message.content)
        }
        .sheet(isPresented: artifactPresented) {
            NavigationStack { artifactPane }
                .presentationDetents([.large])
        }
        #else
        .inspector(isPresented: artifactPresented) {
            artifactPane
                .inspectorColumnWidth(min: 360, ideal: 420, max: 600)
        }
        #endif
    }

    /// Driven by `env.openArtifactID` (set by artifact pills in the chat);
    /// closing the panel/sheet clears it again.
    private var artifactPresented: Binding<Bool> {
        Binding(
            get: { env.openArtifactID != nil },
            set: { if !$0 { env.openArtifactID = nil } }
        )
    }

    @ViewBuilder
    private var artifactPane: some View {
        if let id = env.openArtifactID, let artifact = context.model(for: id) as? Artifact {
            ArtifactPaneView(artifact: artifact)
        } else {
            ContentUnavailableView(
                "Artifact Unavailable",
                systemImage: "doc.questionmark",
                description: Text("The artifact was deleted.")
            )
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if session.orderedMessages.isEmpty {
            // Fresh chat — greet instead of showing an empty scroll area.
            VStack(spacing: 8) {
                GradientText(text: "Hello", font: Theme.Typography.font(.display))
                Text("Ask \(session.agent?.name ?? "Chatter") anything")
                    .font(Theme.Typography.font(.callout))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        ForEach(transcriptItems) { item in
                            transcriptItemView(item)
                                .id(item.id)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                // Per-flush re-pin must be unanimated: an animated scrollTo at
                // ~12 Hz keeps an animation transaction open in which every
                // LazyVStack row (de)realization plays an insertion transition
                // — rows visibly "fly in" over and over, and together with the
                // collapse animations the layout loop can stop converging
                // entirely (100s+ main-thread hang, see reports 2026-07-16).
                .onChange(of: lastMessageFingerprint) { scrollToBottom(proxy, animated: false) }
                // Unanimated like the flush re-pin above: these fire during
                // tool loops (one insert per tool message), and an animated
                // scroll here makes every simultaneous row insertion play a
                // transition — the tool cards flash, flicker, and overlap.
                .onChange(of: (session.messages ?? []).count) { scrollToBottom(proxy, animated: false) }
                .onChange(of: env.isSending(session)) { scrollToBottom(proxy, animated: false) }
                .onAppear { scrollToBottom(proxy, animated: false) }
            }
        }
    }

    /// Streamed content + thinking of the newest message — drives auto-scroll.
    /// Includes isStreaming so the scroll also fires when streaming ends and
    /// the thoughts disclosure auto-collapses without a content change.
    private var lastMessageFingerprint: String {
        // Evaluated per streamed flush (~12 Hz) — find the newest message
        // with a linear max instead of sorting the whole session.
        guard let last = (session.messages ?? []).max(by: { $0.orderIndex < $1.orderIndex })
        else { return "" }
        return "\(last.isStreaming)|\(last.content.count)|\(last.thinking?.count ?? 0)"
    }

    // MARK: - Transcript grouping

    /// One renderable unit of the transcript: user turns and final answers
    /// stay standalone; the intermediate steps of an agentic turn (tool calls,
    /// tool results, interstitial assistant text) are grouped into a single
    /// collapsible activity item.
    private enum TranscriptItem: Identifiable {
        case user(Message)
        case activity([Message], live: Bool)
        case answer(Message)

        var id: String {
            switch self {
            case .user(let m): return "user-\(m.id.uuidString)"
            case .activity(let steps, _): return "activity-\(steps.first?.id.uuidString ?? "0")"
            case .answer(let m): return "answer-\(m.id.uuidString)"
            }
        }
    }

    /// Plain box, deliberately not observed (same trick as the sidebar's
    /// GroupCache): memoizes the grouping so a streaming flush (~12 Hz)
    /// doesn't re-sort and re-group the whole transcript per body evaluation.
    private final class TranscriptCache {
        var key = 0
        var items: [TranscriptItem] = []
    }
    @State private var transcriptCache = TranscriptCache()

    private var transcriptItems: [TranscriptItem] {
        let messages = session.orderedMessages
        // Grouping depends on message identity and count, the live flag, and
        // the newest message's growth (streaming content, tool calls being
        // persisted). Completed messages are immutable, so this key is stable.
        var hasher = Hasher()
        hasher.combine(messages.count)
        hasher.combine(env.isSending(session))
        for message in messages { hasher.combine(message.id) }
        if let last = messages.last {
            hasher.combine(last.isStreaming)
            hasher.combine(last.content.count)
            hasher.combine(last.thinking?.count ?? 0)
            hasher.combine(last.toolCallsJSON != nil)
        }
        let key = hasher.finalize()
        if key != transcriptCache.key || transcriptCache.items.isEmpty {
            transcriptCache.items = Self.groupTranscript(
                messages: messages, live: env.isSending(session)
            )
            transcriptCache.key = key
        }
        return transcriptCache.items
    }

    private static func groupTranscript(messages: [Message], live: Bool) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var steps: [Message] = []

        func flushSteps(live: Bool = false) {
            guard !steps.isEmpty else { return }
            items.append(.activity(steps, live: live))
            steps = []
        }

        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                flushSteps()
                items.append(.user(message))
            case .tool:
                steps.append(message)
            case .assistant:
                // Cheap nil check instead of decoding the tool-call JSON on
                // every render (this runs per streamed UI update).
                if message.toolCallsJSON == nil {
                    // No tool calls → this is (or is becoming) the final answer.
                    flushSteps()
                    items.append(.answer(message))
                } else {
                    steps.append(message)
                }
            }
        }
        flushSteps(live: live)
        return items
    }

    @ViewBuilder
    private func transcriptItemView(_ item: TranscriptItem) -> some View {
        switch item {
        case .user(let message):
            VStack(alignment: .trailing, spacing: 2) {
                UserBubble(message: message)
                actionBar(for: message)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .activity(let steps, let live):
            ActivityGroupView(steps: steps, live: live, accent: session.agent?.color ?? Theme.accent)
        case .answer(let message):
            VStack(alignment: .leading, spacing: 2) {
                AssistantMessage(message: message)
                if !message.isStreaming {
                    // Indented past the agent badge so it aligns with the text.
                    actionBar(for: message).padding(.leading, 36)
                }
            }
        }
    }

    /// Resend (redo from here) / copy / select-text (iOS) / delete under a
    /// message.
    private func actionBar(for message: Message) -> some View {
        #if os(iOS)
        let onSelectText: (() -> Void)? = { selectingMessage = message }
        #else
        let onSelectText: (() -> Void)? = nil
        #endif
        return MessageActionBar(
            onResend: { viewModel.resend(from: message, env: env, session: session, context: context) },
            onCopy: { Pasteboard.copy(message.content) },
            onSelectText: onSelectText,
            onDelete: { viewModel.delete(message, context: context) }
        )
    }

    private let bottomID = "bottom-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // One-tick hop: onChange fires inside the same update that removes the
        // expanded thinking view; scrolling immediately would resolve bottomID
        // against stale (pre-collapse) geometry.
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            if animated {
                withAnimation(Theme.Motion.Easing.standard) { proxy.scrollTo(bottomID, anchor: .bottom) }
            } else {
                // disablesAnimations, not just "no withAnimation": the scroll
                // must not inherit a transaction that is already in flight
                // (e.g. a disclosure collapse), or the re-pin animates anyway.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    /// Accepts an image drop anywhere in the chat: rejected when the model
    /// can't see images (drop falls through), otherwise the providers are
    /// turned into attachments asynchronously.
    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard viewModel.canAttachImages else { return false }
        Task {
            viewModel.addBase64Images(await ImageAttachmentProcessor.makeBase64JPEGs(from: providers))
        }
        return true
    }

    private func send() {
        if env.isSending(session) {
            viewModel.stop(env: env, session: session)
        } else {
            viewModel.send(env: env, session: session, agent: session.agent, context: context)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}
