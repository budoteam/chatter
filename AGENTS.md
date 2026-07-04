# Repository Guidelines

## Project Overview

Chatter is a multiplatform (iOS 17+ / iPadOS / macOS 14+) SwiftUI LLM chat app powered by Ollama Cloud, with MCP (Model Context Protocol) tool support and user-defined Agents. Each Agent configures a model, system prompt, temperature, and a set of MCP servers. Session history syncs across devices via CloudKit. UI is inspired by Google Gemini.

- Bundle ID: `team.budo.chatter`
- CloudKit container: `iCloud.team.budo.chatter`
- Single shared codebase, one app target; only third-party dependency is the MCP Swift SDK (`0.11.0+`).

## Architecture & Data Flow

MVVM-ish over SwiftData + SwiftUI. Layers:

```
SwiftUI Views  →  ViewModels (@Observable)  →  ChatEngine (orchestrator)
                                                      ↓
                            OllamaService (streaming)  +  MCPConnectionManager (tool calls)
                                                      ↓
                                SwiftData @Model objects (observed by views)
```

- **DI**: `AppEnvironment` (`@MainActor @Observable`) is the root: owns `OllamaService`, `MCPConnectionManager`, `ChatEngine`, plus cross-view UI state. Injected through the SwiftUI environment.
- **Service abstraction**: Services sit behind protocols in `Chatter/Services/Protocols/` (`OllamaServiceProtocol`, `MCPClientProtocol`). `ChatEngine` and views depend on protocols, not concrete types — this is the mocking seam for future tests.
- **Streaming flow** (`ChatEngine.send(text, session, agent, context)`):
  1. Insert user `Message`.
  2. Resolve agent's MCP tools via `MCPConnectionManager.tools(forServerIDs:)`.
  3. Loop (≤6 iterations): build `[system + orderedMessages]`, stream `OllamaChatChunk` (delta / thinking / toolCalls / done) into a live streaming `Message` (buffered ~12 Hz / ~80ms flushes to avoid re-rendering the whole message).
  4. If `toolCalls` present: persist + execute via `mcp.callTool(namespacedName:)`, append tool `Message`s, stream again.
  5. Errors bubble to `ChatViewModel.errorMessage`; `CancellationError` preserves partial content.

## Key Directories

- `Chatter/ChatterApp.swift` — `@main` App; builds `ModelContainer` via `Persistence`, injects `AppEnvironment`, macOS Settings scene.
- `Chatter/AppEnvironment.swift` — `@MainActor @Observable` root; owns services + cross-view UI state.
- `Chatter/Persistence.swift` — builds CloudKit-backed `ModelContainer` with local / in-memory fallback.
- `Chatter/Models/` — SwiftData `@Model` objects: `Agent`, `ChatSession`, `Message`, `MCPServerConfig`.
- `Chatter/Services/` — `ChatEngine`, `OllamaService`, `MCPConnectionManager`, `KeychainService`, `AppLogger`, `JSONValue`, `OllamaModels`, `LegacySSEClientTransport`, plus `Protocols/`.
- `Chatter/ViewModels/` — `ChatViewModel` (composer state, `send`/`stop` via `Task`, error surfacing).
- `Chatter/Views/` — `RootView` + `Sidebar/`, `Chat/`, `Agents/`, `Settings/`, `Components/`. Platform diffs inline via `#if os(macOS)`.
- `Chatter/DesignSystem/` — `Theme.swift`.
- `project.yml` — XcodeGen spec, **source of truth** for the Xcode project.
- `generate.sh` — regenerates `Chatter.xcodeproj` from `project.yml` (runs `xcodegen generate`, then patches the scheme to disable "Enable backtrace recording" / queueDebugging — workaround for an Xcode 26/macOS 26 LLDB crash).

## Development Commands

No `package.json` / npm / Bun. Pure Swift/Xcode, XcodeGen-managed.

| Action | Command |
| --- | --- |
| Generate Xcode project (after editing `project.yml` or adding files) | `./generate.sh` (requires `brew install xcodegen`) |
| Build (iOS Simulator) | `xcodebuild -project Chatter.xcodeproj -scheme Chatter -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` |
| Build (macOS) | `xcodebuild -project Chatter.xcodeproj -scheme Chatter -destination 'platform=macOS' build` |
| Open in Xcode | `open Chatter.xcodeproj` |
| TestFlight | bump `CURRENT_PROJECT_VERSION`, `./generate.sh`, archive with `-allowProvisioningUpdates`, upload via Xcode Organizer |

No dedicated lint / format / test commands exist. No CI workflows (`.github/workflows` absent).

## Code Conventions & Common Patterns

- **Concurrency**: `@MainActor` + `@Observable` for services and view models. `async/await` and `AsyncThrowingStream` for streaming. `TaskGroup` for concurrent MCP server connects. View-model work runs in `Task` so `send`/`stop` can cancel.
- **Logging**: `AppLogger` (os.Logger) with categories `api`, `mcp`, `data`; annotate with `privacy: .public`. Do not log secrets.
- **Errors**: Localized `EngineError` / `ServiceError`. `CancellationError` is expected on user-initiated stop — keep partial content, do not surface as an error.
- **SwiftData / CloudKit compatibility** (mandatory for all `@Model` changes):
  - Every property needs a default.
  - Relationships must be optional.
  - No `@Attribute(.unique)`.
  - Nested data as JSON strings / raw values.
  - `Message` ordering via explicit `orderIndex`, not timestamps.
- **Streaming batching**: token deltas are buffered and flushed ~12 Hz to avoid re-rendering the whole `Message`. Preserve this batching when touching the streaming path.
- **Platform diffs**: inline via `#if os(macOS)`; no separate macOS target. `MCPConnectionManager` stdio subprocess transport is macOS-only (`#if os(macOS)`).
- **Commit messages**: written in German.
- **ATS**: `NSAllowsArbitraryLoads` is intentionally `true` (self-hosted MCP over plain HTTP on LAN / Tailscale). Do not change.
- **Project editing**: `Chatter.xcodeproj/` is gitignored and generated. Edit `project.yml`, run `./generate.sh`. Never edit the `.xcodeproj` directly. New source files under `Chatter/` are auto-globbed but require `./generate.sh` to appear in the project.

## Important Files

- `project.yml` — XcodeGen spec; source of truth for targets, settings, packages, Info.plist properties, entitlements wiring.
- `generate.sh` — project generation + scheme patch.
- `Chatter/ChatterApp.swift` — `@main` entry point.
- `Chatter/AppEnvironment.swift` — composition root / DI container.
- `Chatter/Persistence.swift` — `ModelContainer` construction (CloudKit → local → in-memory fallback).
- `Chatter/Services/ChatEngine.swift` — one assistant turn + agentic tool loop (≤6 iterations).
- `Chatter/Services/OllamaService.swift` — Ollama Cloud `/api/chat` NDJSON streaming, `/api/tags` model list; Bearer key from Keychain.
- `Chatter/Services/MCPConnectionManager.swift` — namespaced tool registry (`server.tool`), Streamable HTTP + SSE; stdio subprocess on macOS only.
- `Chatter/Services/KeychainService.swift` — iCloud-synced API key storage.
- `Chatter/Services/Protocols/OllamaServiceProtocol.swift`, `MCPClientProtocol.swift` — abstractions consumed by `ChatEngine`/views; the mocking seam.
- `Chatter/Models/{Agent,ChatSession,Message,MCPServerConfig}.swift` — SwiftData models.
- `Chatter/Chatter-iOS.entitlements`, `Chatter/Chatter-macOS.entitlements` — per-platform entitlements (APNs key differs; only macOS carries app-sandbox key).
- `README.md`, `CLAUDE.md` — existing project docs.

## Runtime / Tooling Preferences

- **Runtime**: Swift 5 language mode; Xcode 16+ (built with Xcode 26). Deployment targets iOS 17.0, macOS 14.0.
- **Package manager**: Swift Package Manager via Xcode (declared in `project.yml` under `packages:`). No npm / pnpm / Bun.
- **Project generation**: XcodeGen (`brew install xcodegen`). `project.yml` is the source of truth; `Chatter.xcodeproj/` is generated and gitignored.
- **Signing**: automatic, `DEVELOPMENT_TEAM = X9FHM3F6WK`. macOS App Sandbox disabled (stdio MCP servers run as subprocesses). Distribution via Developer ID + notarization, not Mac App Store.
- **Secrets**: the only runtime secret is the Ollama Cloud API key (ollama.com → Settings → API keys), entered in-app Settings, stored in Keychain (iCloud-synced). No `.env`.

## Testing & QA

- **No test infrastructure exists.** No test target, no test files, no test config, no coverage tooling.
- The mocking seam is already in place: `Chatter/Services/Protocols/OllamaServiceProtocol.swift` (lines 3–5) states it exists "so views/engine can be tested against a mock" — tests are intended but not yet authored.
- To add tests: add a `targets.ChatterTests` entry (type: `bundle.unit-test`) in `project.yml` pointing at a new `ChatterTests/` directory, run `./generate.sh`, then `xcodebuild test -scheme Chatter -destination 'platform=iOS Simulator,name=...'`.