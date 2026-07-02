import SwiftUI
import SwiftData

// MARK: - Session creation

enum SessionFactory {
    /// Creates and persists a new session, seeding its model from the agent
    /// (or the first available model as a fallback).
    @MainActor
    static func create(in context: ModelContext, agent: Agent?, models: [OllamaModel]) -> ChatSession {
        let agentModel = (agent?.modelId).flatMap { $0.isEmpty ? nil : $0 }
        let model = agentModel ?? models.first?.name ?? ""
        let session = ChatSession(agent: agent, modelId: model)
        context.insert(session)
        try? context.save()
        return session
    }
}

// MARK: - Gradient text (Gemini-style greeting)

struct GradientText: View {
    let text: String
    var font: Font = .largeTitle.weight(.semibold)

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
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [color, color.opacity(0.7)],
                    startPoint: .top, endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            )
    }
}
