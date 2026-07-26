#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only demo mode for App Store marketing screenshots.
///
/// Activated purely through launch environment variables (never committed),
/// e.g. via `simctl launch` (`SIMCTL_CHILD_…`) or a direct binary launch:
///
///     CHATTER_SCREENSHOT_DEMO=1   enable demo mode
///     CHATTER_DEMO_API_KEY=<key>  in-memory Ollama key override — the real
///                                 keychain item is never read or written
///     CHATTER_DEMO_SCREEN=<name>  screen to present after launch:
///                                 sidebar | welcome | chat1…chat4 | composer |
///                                 agents | agent-editor | knowledge | skills |
///                                 settings
///
/// Demo mode runs on a seeded in-memory store (see `Persistence.makeContainer`),
/// so the user's real chats and settings are never touched.
enum ScreenshotDemo {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["CHATTER_SCREENSHOT_DEMO"] == "1"
    }

    /// The demo key, read straight from the environment on every access:
    /// `AppEnvironment.hasAPIKey` is initialized before any app `init()` body
    /// runs, so there is no safe "configure once" hook earlier than this.
    static var apiKey: String? {
        guard let key = ProcessInfo.processInfo.environment["CHATTER_DEMO_API_KEY"],
              !key.isEmpty else { return nil }
        return key
    }

    static var screen: String {
        ProcessInfo.processInfo.environment["CHATTER_DEMO_SCREEN"] ?? "chat1"
    }

    // MARK: - Container & seeding

    static func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(
            schema: Persistence.schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: Persistence.schema, configurations: config)
            seed(context: ModelContext(container))
            AppLogger.data.info("Screenshot demo container ready (in-memory, seeded)")
            return container
        } catch {
            preconditionFailure("Screenshot demo container failed: \(error.localizedDescription)")
        }
    }

    private static func seed(context: ModelContext) {
        let now = Date()

        // MARK: Agents

        let assistant = Agent(
            name: "Everyday Assistant",
            systemPrompt: "You are a friendly, concise everyday assistant. Answer in clear markdown, keep it practical, and ask a follow-up question when it helps.",
            modelId: "kimi-k2.6",
            temperature: 0.7,
            iconSymbol: "sparkles",
            colorHex: "6C5CE7",
            memoryEnabled: true,
            webAccessEnabled: true,
            isDefault: true
        )
        let coder = Agent(
            name: "Code Companion",
            systemPrompt: "You are a senior Swift engineer. Prefer Swift 6, SwiftUI and structured concurrency. Show short, compilable examples.",
            modelId: "kimi-k2.7-code",
            temperature: 0.3,
            iconSymbol: "chevron.left.forwardslash.chevron.right",
            colorHex: "4F86FF"
        )
        let researcher = Agent(
            name: "Research Scout",
            systemPrompt: "You are a thorough research assistant. Use web search to ground your answers and cite your sources.",
            modelId: "deepseek-v4-pro",
            temperature: 0.5,
            iconSymbol: "book.fill",
            colorHex: "00B894",
            webAccessEnabled: true
        )
        assistant.createdAt = now.addingTimeInterval(-60 * 60 * 24 * 30)
        coder.createdAt = now.addingTimeInterval(-60 * 60 * 24 * 20)
        researcher.createdAt = now.addingTimeInterval(-60 * 60 * 24 * 10)
        [assistant, coder, researcher].forEach { context.insert($0) }

        // MARK: Skills

        let meetingNotes = Skill(
            name: "meeting-notes",
            summary: "Turn raw meeting transcripts into structured notes with decisions and action items.",
            content: "# Meeting Notes\n\n1. Read the transcript.\n2. Extract **decisions**, **action items** (with owners) and **open questions**.\n3. Output markdown with those three sections."
        )
        let prSummary = Skill(
            name: "pr-summary",
            summary: "Summarize a pull request: intent, key changes, and risks.",
            content: "# PR Summary\n\nGiven a diff, produce: intent (1 sentence), key changes (bullets), risks & follow-ups."
        )
        [meetingNotes, prSummary].forEach { context.insert($0) }
        researcher.skillIDs = [prSummary.id]

        // MARK: Knowledge

        let japan = KnowledgeBundle(name: "Japan Trip 2026", about: "Research and plans for the October trip.")
        context.insert(japan)
        let concepts: [(String, String, String)] = [
            ("tokyo/food", "Tokyo Food Map", "# Tokyo Food Map\n\n- **Tsukiji outer market** — tamagoyaki & tuna bowls before 9am\n- **Afuri** — yuzu ramen in Ebisu\n- **Han no Daidokoro** — wagyu yakiniku, book ahead"),
            ("kyoto/temples", "Kyoto Temple Shortlist", "# Kyoto Temples\n\n- Kinkaku-ji at opening (8am) to beat the crowds\n- Fushimi Inari after 5pm for the lanterns\n- Arashiyama bamboo grove + Okochi Sanso garden"),
            ("packing", "Packing List", "# Packing List\n\n- Suica card (mobile)\n- Pocket wifi / eSIM\n- Light layers — 12–20°C in October"),
        ]
        for (path, title, body) in concepts {
            let concept = KnowledgeConcept(path: path, title: title, body: body)
            concept.bundle = japan
            context.insert(concept)
        }
        assistant.knowledgeBundleIDs = [japan.id]

        // MARK: Sessions & messages

        func message(
            _ role: MessageRole,
            _ content: String,
            session: ChatSession,
            order: Int,
            at: Date,
            thinking: String? = nil
        ) {
            let message = Message(role: role, content: content, orderIndex: order)
            message.createdAt = at
            message.thinking = thinking
            message.session = session
            context.insert(message)
        }

        func session(
            _ title: String,
            agent: Agent,
            updatedAt: Date
        ) -> ChatSession {
            let session = ChatSession(title: title, agent: agent, modelId: agent.modelId)
            session.createdAt = updatedAt.addingTimeInterval(-1800)
            session.updatedAt = updatedAt
            context.insert(session)
            return session
        }

        // 1 — hero chat (today)
        let lisbon = session("Lisbon weekend — 3-day plan", agent: assistant, updatedAt: now.addingTimeInterval(-2 * 3600))
        let t0 = lisbon.createdAt
        message(.user, "Plan a relaxed 3-day weekend in Lisbon for two. We love food, miradouros, and vintage trams. Where should we stay?",
                session: lisbon, order: 0, at: t0)
        message(.assistant, """
        Great pick — late spring in Lisbon is hard to beat. Stay in **Chiado** or **Príncipe Real**: central, walkable, and full of cafés.

        ## Day 1 — Alfama & the classics
        - Morning: **Sé Cathedral**, then wander up to **Castelo de São Jorge**
        - Lunch: grilled sardines in Alfama
        - Sunset: **Miradouro da Senhora do Monte** — the best view in town

        ## Day 2 — Belém
        - **Pastéis de Belém** first thing (skip the line, take them to the park)
        - **Jerónimos Monastery** and the **MAAT** museum
        - Evening: fado dinner back in Alfama

        ## Day 3 — Tram 28 & LX Factory
        - Ride **Tram 28** end to end early, before the crowds
        - Brunch and shops at **LX Factory**
        - Sunset drinks at **Park Bar** (rooftop on a parking garage)

        Want me to turn this into an hour-by-hour itinerary with reservations?
        """,
                session: lisbon, order: 1, at: t0.addingTimeInterval(45),
                thinking: "The user wants a relaxed 3-day plan for two, focused on food, viewpoints and trams, plus a neighborhood recommendation. I'll structure by day with the highlights they named: miradouros (Senhora do Monte, Santa Catarina), Tram 28, Belém for food. Keep it relaxed — no more than 3–4 stops per day.")
        message(.user, "Can we fit a half-day trip to Sintra in without rushing?",
                session: lisbon, order: 2, at: t0.addingTimeInterval(600))
        message(.assistant, """
        Yes — swap Day 3. Take the **8:30 train from Rossio** (40 min), do **Pena Palace** first (book the 9:30 slot), then **Quinta da Regaleira** around noon. You'll be back in Lisbon by 4pm, still in time for sunset drinks at Park Bar.

        Move Tram 28 to Day 1 morning — it starts near Martim Moniz, an easy walk from Chiado.
        """,
                session: lisbon, order: 3, at: t0.addingTimeInterval(660))

        // 2 — code chat (today, earlier)
        let swiftUI = session("SwiftUI spring animation", agent: coder, updatedAt: now.addingTimeInterval(-5 * 3600))
        let t1 = swiftUI.createdAt
        message(.user, "How do I make a SwiftUI card bounce in with a spring animation when it appears?",
                session: swiftUI, order: 0, at: t1)
        message(.assistant, """
        Use a `.spring` response with a scale transition. The trick is driving it from `onAppear` with an explicit animation:

        ```swift
        struct BounceCard: View {
            @State private var appeared = false

            var body: some View {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.blue.gradient)
                    .frame(width: 220, height: 140)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                    .onAppear {
                        withAnimation(.spring(duration: 0.5, bounce: 0.5)) {
                            appeared = true
                        }
                    }
            }
        }
        ```

        Two knobs worth tuning:

        - **`bounce`** (0…1): how much it overshoots. 0.3 is subtle, 0.6 is playful.
        - **`duration`**: total settle time — keep it under 0.6s or it feels sluggish.

        For a list of cards, stagger them with `.animation(.spring.delay(…), value:)` so they pop in one after another.
        """,
                session: swiftUI, order: 1, at: t1.addingTimeInterval(60))

        // 3 — explainer chat (yesterday)
        let quantum = session("Quantum entanglement, simply", agent: assistant, updatedAt: now.addingTimeInterval(-26 * 3600))
        let t2 = quantum.createdAt
        message(.user, "Explain quantum entanglement like I'm five.",
                session: quantum, order: 0, at: t2)
        message(.assistant, """
        Imagine you have two magic coins. You shake them in a box, then mail one to a friend on the other side of the world — **without looking at either**.

        The moment you peek at yours and see heads, you *instantly* know theirs shows tails. Always. No matter how far away it is.

        That's entanglement: two tiny particles can be linked so that measuring one tells you about the other immediately — as if the coins had agreed on a secret before parting.

        The spooky part Einstein disliked? The particles don't "decide" their answer until someone looks. They're connected by something deeper than a hidden note.

        **What it's good for:** quantum computers use these linked pairs to solve certain puzzles much faster than normal computers.
        """,
                session: quantum, order: 1, at: t2.addingTimeInterval(50))

        // 4 — small chat (previous 7 days)
        let email = session("Draft email to landlord", agent: assistant, updatedAt: now.addingTimeInterval(-4 * 24 * 3600))
        let t3 = email.createdAt
        message(.user, "Draft a short, friendly email to my landlord: the kitchen faucet is dripping and I'd like it fixed.",
                session: email, order: 0, at: t3)
        message(.assistant, """
        Here's a draft:

        > Hi Ms. Berger,
        >
        > I hope you're doing well. The kitchen faucet in my apartment has started dripping steadily, and I'd appreciate it if someone could take a look at it. I'm flexible on timing and happy to be home whenever works best.
        >
        > Thank you!
        > Alex

        Want a more formal version, or one in German?
        """,
                session: email, order: 1, at: t3.addingTimeInterval(30))

        // MARK: MCP servers (disabled — shows the feature without a connection)

        let homeAssistant = MCPServerConfig(
            name: "Home Assistant",
            transport: .http,
            url: "http://homeassistant.local:8123/mcp",
            enabled: false
        )
        context.insert(homeAssistant)

        context.saveOrLog()
    }

    // MARK: - Navigation

    /// Drives the app to the screen named by `CHATTER_DEMO_SCREEN`. Called
    /// once from `RootView.task` after the model list loaded.
    @MainActor
    static func applyNavigation(
        env: AppEnvironment,
        context: ModelContext,
        showSidebar: () -> Void,
        openSettings: () -> Void
    ) {
        guard isActive else { return }

        func session(at index: Int) -> ChatSession? {
            var descriptor = FetchDescriptor<ChatSession>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            descriptor.fetchLimit = index + 1
            let sessions = (try? context.fetch(descriptor)) ?? []
            return sessions.count > index ? sessions[index] : nil
        }

        switch screen {
        case "sidebar":
            showSidebar()
        case "welcome":
            env.showScreen(.chat)
        case "chat1": if let s = session(at: 0) { env.openChat(s) }
        case "chat2": if let s = session(at: 1) { env.openChat(s) }
        case "chat3": if let s = session(at: 2) { env.openChat(s) }
        case "chat4": if let s = session(at: 3) { env.openChat(s) }
        case "composer":
            if let s = session(at: 0) {
                env.openChat(s)
                // Picked up by ChatView.onAppear into the composer's text field.
                env.pendingPrompt = "What should we absolutely not miss in Sintra?"
            }
        case "agents", "agent-editor":
            // The editor sheet itself is opened by AgentsScreen.onAppear.
            env.showScreen(.agents)
        case "knowledge":
            env.showScreen(.knowledge)
        case "skills":
            env.showScreen(.skills)
        case "settings":
            openSettings()
        default:
            AppLogger.ui.error("Unknown CHATTER_DEMO_SCREEN: \(screen, privacy: .public)")
        }
    }
}
#endif
