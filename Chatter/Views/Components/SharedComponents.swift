import SwiftUI
import SwiftData

// MARK: - Session creation

enum SessionFactory {
    /// Creates and persists a new session, seeding its model from the agent
    /// (or the first available model as a fallback).
    @MainActor
    static func create(in context: ModelContext, agent: Agent?, models: [OllamaModel]) -> ChatSession {
        let session = ChatSession(agent: agent, modelId: defaultModel(agent: agent, models: models))
        context.insert(session)
        context.saveOrLog()
        return session
    }

    /// The model to use by default: the agent's model, else the first
    /// available model, else empty. One rule, shared by chat creation and the
    /// PDF import sheet.
    static func defaultModel(agent: Agent?, models: [OllamaModel]) -> String {
        let agentModel = (agent?.modelId).flatMap { $0.isEmpty ? nil : $0 }
        return agentModel ?? models.first?.name ?? ""
    }

    /// The default agent: the one flagged default, else the first.
    static func defaultAgent(in agents: [Agent]) -> Agent? {
        agents.first(where: \.isDefault) ?? agents.first
    }
}

// MARK: - Gradient text (Gemini-style greeting)

struct GradientText: View {
    let text: String
    var font: Font = Theme.Typography.font(.display)

    var body: some View {
        Text(text)
            .font(font)
            .overlay { Theme.brandGradient.mask(Text(text).font(font)) }
            .foregroundStyle(.clear)
    }
}

// MARK: - Soft background wash

struct GeminiBackground: View {
    var body: some View {
        Theme.canvas
            .overlay(alignment: .top) {
                Theme.brandGradient
                    .opacity(0.10)
                    .blur(radius: 90)
                    .frame(height: 320)
                    .offset(y: -140)
            }
            .ignoresSafeArea()
    }
}

// MARK: - Animated typing indicator

struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: 7, height: 7)
                    .opacity(0.35 + 0.65 * pulse(i))
                    .scaleEffect(0.8 + 0.2 * pulse(i))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
        .accessibilityLabel("Assistant is typing")
    }

    private func pulse(_ index: Int) -> Double {
        let shifted = (phase + Double(index) * 0.33).truncatingRemainder(dividingBy: 1)
        return abs(sin(shifted * .pi))
    }
}

// MARK: - Circular icon badge

struct AgentBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [color, color.opacity(0.72)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: Circle()
            )
    }
}
