import SwiftUI
import SwiftData

struct ChatView: View {
    let session: ChatSession

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var viewModel = ChatViewModel()
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
        .navigationTitle(session.title.isEmpty ? "New Chat" : session.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let agent = session.agent {
                    HStack(spacing: 7) {
                        AgentBadge(symbol: agent.iconSymbol, color: agent.color, size: 20)
                        Text(agent.name).font(.headline)
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
        #endif
    }

    @ViewBuilder
    private var transcript: some View {
        if session.orderedMessages.isEmpty {
            // Fresh chat — greet instead of showing an empty scroll area.
            VStack(spacing: 8) {
                GradientText(text: "Hello", font: .system(size: 32, weight: .semibold))
                Text("Ask \(session.agent?.name ?? "Chatter") anything")
                    .font(.callout)
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
                .onChange(of: lastMessageFingerprint) { scrollToBottom(proxy) }
                .onChange(of: session.orderedMessages.count) { scrollToBottom(proxy) }
                .onChange(of: viewModel.isSending) { scrollToBottom(proxy) }
                .onAppear { scrollToBottom(proxy, animated: false) }
            }
        }
    }

    /// Streamed content + thinking of the newest message — drives auto-scroll.
    /// Includes isStreaming so the scroll also fires when streaming ends and
    /// the thoughts disclosure auto-collapses without a content change.
    private var lastMessageFingerprint: String {
        guard let last = session.orderedMessages.last else { return "" }
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

    private var transcriptItems: [TranscriptItem] {
        var items: [TranscriptItem] = []
        var steps: [Message] = []

        func flushSteps(live: Bool = false) {
            guard !steps.isEmpty else { return }
            items.append(.activity(steps, live: live))
            steps = []
        }

        for message in session.orderedMessages {
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
        flushSteps(live: viewModel.isSending)
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
            ActivityGroupView(steps: steps, live: live)
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
        Task { @MainActor in
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            } else {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private func send() {
        if viewModel.isSending {
            viewModel.stop()
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
