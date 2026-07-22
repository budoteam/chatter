import SwiftUI
import SwiftData

/// One conversation: message history (streaming-aware) plus a composer.
/// watchOS `TextField` offers dictation/scribble out of the box — no custom
/// input UI needed. Tool messages are hidden; assistant answers render as
/// lightweight Markdown via `AttributedString`.
struct WatchChatView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    let session: ChatSession
    @State private var viewModel = ChatViewModel()
    /// Local composer draft, decoupled from `viewModel.inputText`: watchOS
    /// commits dictated text into the binding *after* `onSubmit`, so a direct
    /// binding to the view model replays the just-sent text into the field.
    @State private var draft = ""
    /// Armed briefly after sending to swallow the late dictation commit.
    @State private var justSent = false
    /// The text as it was sent — the late commit re-writes exactly this.
    @State private var lastSentText = ""

    /// Tool calls and empty assistant stubs stay invisible — on the watch the
    /// answer is what matters.
    private var visibleMessages: [Message] {
        session.orderedMessages.filter { message in
            switch message.role {
            case .user:
                return !message.content.isEmpty || !message.imageAttachments.isEmpty
            case .assistant:
                return !message.content.isEmpty || message.isStreaming
            case .system, .tool:
                return false
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleMessages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 4)
            }
            .safeAreaInset(edge: .bottom) {
                composer
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: session.orderedMessages.last?.content) {
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: session.orderedMessages.count) {
                scrollToBottom(proxy, animated: true)
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("Message", text: $draft)
                .onSubmit(send)
                .onChange(of: draft) { _, newValue in
                    // watchOS commits dictation/scribble text back into the
                    // binding after onSubmit. Discard that replay; mirror
                    // everything else into the view model for `hasDraft`.
                    if justSent, newValue == lastSentText, !newValue.isEmpty {
                        draft = ""
                        return
                    }
                    viewModel.inputText = newValue
                }
            if env.isSending(session) {
                Button(role: .destructive) {
                    viewModel.stop(env: env, session: session)
                } label: {
                    Image(systemName: "stop.circle.fill")
                }
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .disabled(!viewModel.hasDraft || !env.hasAPIKey)
            }
        }
        .buttonStyle(.borderless)
    }

    private func send() {
        let sent = draft
        viewModel.inputText = sent
        viewModel.send(env: env, session: session, agent: session.agent, context: context)
        // Arm the late-commit guard *before* clearing, so a dictation
        // re-commit of the sent text is swallowed by `onChange` above.
        // 250 ms covers the modal dictation controller's commit delay while
        // staying below a noticeable typing gap.
        lastSentText = sent
        justSent = true
        draft = ""
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            justSent = false
        }
    }

    // MARK: - Bubbles

    @ViewBuilder
    private func bubble(for message: Message) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 24)
                Text(message.content)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.userBubble, in: .rect(cornerRadius: Theme.Radius.md))
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                if !message.content.isEmpty {
                    Text(markdown(message.content))
                        .font(.callout)
                }
                if message.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markdown(_ content: String) -> AttributedString {
        (try? AttributedString(markdown: content)) ?? AttributedString(content)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = visibleMessages.last else { return }
        withAnimation(animated ? .default : nil) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}
