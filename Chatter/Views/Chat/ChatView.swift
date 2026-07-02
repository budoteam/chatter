import SwiftUI
import SwiftData

struct ChatView: View {
    let session: ChatSession

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var viewModel = ChatViewModel()

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
                    HStack(spacing: 6) {
                        AgentBadge(symbol: agent.iconSymbol, color: agent.color, size: 22)
                        Text(agent.name).font(.headline)
                    }
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
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(session.orderedMessages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.orderedMessages.last?.content) { scrollToBottom(proxy) }
            .onChange(of: session.orderedMessages.count) { scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
    }

    private let bottomID = "bottom-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
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
