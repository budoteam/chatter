# Repository Guidelines

## Project Overview

Chatter is a multiplatform (iOS 17+ / iPadOS / macOS 14+ / watchOS 10+) SwiftUI LLM chat app powered by Ollama Cloud, with MCP (Model Context Protocol) tool support, user-defined Agents, a knowledge base (OKF), skills, and memory. Each Agent configures a model, system prompt, temperature, MCP servers, and knowledge bundles. Session history syncs across devices via CloudKit. UI is inspired by Google Gemini.

- Bundle ID: `team.budo.chatter` (watch app: `team.budo.chatter.watch`)
- CloudKit container: `iCloud.team.budo.chatter`
- Shared codebase: app target `Chatter` (iOS/macOS) + watch target `ChatterWatch` + one test target; only third-party dependency is the MCP Swift SDK (`0.11.0+`).
- `CLAUDE.md` covers the same ground from a Claude Code angle; keep both in sync when updating.

## Architecture & Data Flow

MVVM-ish over SwiftData + SwiftUI. Layers:

```
SwiftUI Views  →  ViewModels (@Observable)  →  ChatEngine (orchestrator)
                                                      ↓
                            OllamaService (streaming)  +  MCPConnectionManager (MCP tools)
                                                       +  built-in tool providers (knowledge/memory/skill/web)
                                                      ↓
                                SwiftData @Model objects (observed by views)
```

- **DI**: `AppEnvironment` (`@MainActor @Observable`) is the root: owns `OllamaService`, `MCPConnectionManager`, `ChatEngine`, plus cross-view UI state. Injected through the SwiftUI environment.
- **Service abstraction**: Services sit behind protocols in `Chatter/Services/Protocols/` (`OllamaServiceProtocol`, `MCPClientProtocol`, `KnowledgeToolProviding`). `ChatEngine` and views depend on protocols, not concrete types — the mocking seam used by `ChatterTests`.
- **Streaming flow** (`ChatEngine.send`):
  1. Insert user `Message`.
  2. Resolve tools: agent's MCP tools via `MCPConnectionManager` (namespaced `server.tool`) plus built-in providers (`knowledge__*`, `memory__*`, skill, web search/fetch) owned by `ChatEngine`.
  3. Loop (≤42 tool rounds): build `[system + orderedMessages]`, stream `OllamaChatChunk` (delta / thinking / toolCalls / done) into a live streaming `Message` (buffered ~12 Hz flushes — mutating the `@Model` per token re-renders and re-parses Markdown for the whole message and stalls the main thread).
  4. If `toolCalls` present: persist + execute, append tool `Message`s, stream again. After 42 rounds one final round is streamed **without** offering tools, so every turn ends in text.
  5. Errors bubble to `ChatViewModel.errorMessage`; `CancellationError` preserves partial content.

## Key Directories

- `Chatter/ChatterApp.swift` — `@main` App; builds `ModelContainer` via `Persistence`, injects `AppEnvironment`, macOS Settings scene.
- `Chatter/AppEnvironment.swift` — composition root / DI container.
- `Chatter/Persistence.swift` — CloudKit-backed `ModelContainer` with local / in-memory fallback.
- `Chatter/Models/` — SwiftData `@Model` objects: `Agent`, `ChatSession`, `Message`, `MCPServerConfig`, `KnowledgeBundle`, `KnowledgeConcept`, `Skill`, `MemoryEntry`.
- `Chatter/Services/` — `ChatEngine`, `OllamaService`, `MCPConnectionManager`, `Knowledge/` (OKFCodec, KnowledgeTransfer, KnowledgeToolProvider, PDFKnowledgeImporter, PDFImportJob), `SkillCodec`/`SkillTransfer`/`SkillToolProvider`, `MemoryToolProvider`, `WebToolProvider`, `KeychainService`, `CloudSyncMonitor`, `AppLogger`, `LegacySSEClientTransport`, plus `Protocols/`.
- `Chatter/Views/` — `RootView` + `Sidebar/`, `Chat/`, `Agents/`, `Knowledge/`, `Skills/`, `Settings/`, `Components/`. Platform diffs inline via `#if os(macOS)`.
- `ChatterWatch/` — watchOS app (own `@main` + views; session list, chat, dictation composer). Shares `Chatter/Models`, `Chatter/Services` (minus PDF importer + `ImageAttachmentProcessor`), `Persistence.swift`, `AppEnvironment.swift`, `ChatViewModel.swift`, `DesignSystem/Theme.swift` via explicit source paths in `project.yml` — no settings UI: agents/MCP/sessions sync via CloudKit, the API key via iCloud Keychain.
- `ChatterTests/` — XCTest bundle: codec round-trips (OKF, Skill), transfer, tool providers, PDF importer.
- `ci_scripts/ci_post_clone.sh` — Xcode Cloud post-clone (see CI below).
- `project.yml` — XcodeGen spec, **source of truth** for the Xcode project.
- `generate.sh` — regenerates `Chatter.xcodeproj` from `project.yml` (runs `xcodegen generate`, then patches the scheme to disable "Enable backtrace recording" / queueDebugging — workaround for an Xcode 26/macOS 26 LLDB crash). Always use this, never `xcodegen generate` directly.

## Development Commands

No `package.json` / npm / Bun. Pure Swift/Xcode, XcodeGen-managed.

| Action | Command |
| --- | --- |
| Generate Xcode project (after editing `project.yml` or adding files) | `./generate.sh` (requires `brew install xcodegen`) |
| Build (iOS Simulator) | `xcodebuild -project Chatter.xcodeproj -scheme Chatter -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` |
| Build (macOS) | `xcodebuild -project Chatter.xcodeproj -scheme Chatter -destination 'platform=macOS' build` |
| Build (watchOS) | `xcodebuild -project Chatter.xcodeproj -scheme ChatterWatch -destination 'generic/platform=watchOS Simulator' build` |
| Test (macOS) | `xcodebuild -project Chatter.xcodeproj -scheme Chatter -destination 'platform=macOS' test` |
| Single test class | append `-only-testing:ChatterTests/OKFCodecTests` |
| Open in Xcode | `open Chatter.xcodeproj` |
| TestFlight | bump `CURRENT_PROJECT_VERSION`, `./generate.sh`, archive with `-allowProvisioningUpdates`, upload via Xcode Organizer |

No lint / format commands exist. CI is **Xcode Cloud** (no `.github/workflows`): `ci_scripts/ci_post_clone.sh` installs pinned XcodeGen 2.46.0 from a GitHub release (brew is flaky/slow on runners), stamps `CURRENT_PROJECT_VERSION` as `<yyyymmdd>.<CI_BUILD_NUMBER>`, runs `./generate.sh`, and re-enables automatic SwiftPM resolution (there is no committed `Package.resolved` because the `.xcodeproj` is generated).

## Code Conventions & Common Patterns

- **Concurrency**: `@MainActor` + `@Observable` for services and view models. `async/await` and `AsyncThrowingStream` for streaming. View-model work runs in `Task` so `send`/`stop` can cancel.
- **Logging**: `AppLogger` (os.Logger) with categories `api`, `mcp`, `data`; annotate with `privacy: .public`. Do not log secrets.
- **Errors**: Localized `EngineError` / `ServiceError`. `CancellationError` is expected on user-initiated stop — keep partial content, do not surface as an error.
- **SwiftData / CloudKit compatibility** (mandatory for all `@Model` changes):
  - Every property needs a default.
  - Relationships must be optional.
  - No `@Attribute(.unique)`.
  - Nested data as JSON strings / raw values with computed accessors (e.g. `Message.toolCallsJSON` ↔ `toolCalls`).
  - `Message` ordering via explicit `orderIndex` (`session.nextOrderIndex`), not timestamps.
  - Save via `context.saveOrLog()` (extension in `Persistence.swift`) — best-effort like the former `try? context.save()`, but failures are logged via `AppLogger.data` instead of vanishing silently.
- **CloudKit schema deploy (before any TestFlight release that adds/changes a `@Model`)**: Debug builds use the Development environment (schema auto-created on first run); TestFlight uses Production, updated only by manual deploy. Missing Production fields make every `RecordSave` fail and stall sync entirely (this happened with 1.4). Procedure: run a debug build once → CloudKit Console → container `iCloud.team.budo.chatter` → Schema → Deploy Schema Changes to Production → then upload. Sync health is visible in Settings → iCloud Sync (`CloudSyncMonitor`).
- **Streaming batching**: token deltas are buffered and flushed ~12 Hz. Preserve this batching when touching the streaming path.
- **Platform diffs**: inline via `#if os(macOS)`; no separate macOS target. stdio MCP subprocess transport is macOS-only.
- **Commit messages**: written in German.
- **ATS**: `NSAllowsArbitraryLoads` is intentionally `true` (self-hosted MCP over plain HTTP on LAN / Tailscale). Do not change.
- **Project editing**: `Chatter.xcodeproj/` is gitignored and generated. Edit `project.yml`, run `./generate.sh`. Never edit the `.xcodeproj` directly. New source files under `Chatter/` are auto-globbed but require `./generate.sh` to appear in the project.

## Runtime / Tooling Preferences

- **Runtime**: Swift 5 language mode; Xcode 16+ (built with Xcode 26). Deployment targets iOS 17.0, macOS 14.0.
- **Package manager**: Swift Package Manager via Xcode (declared in `project.yml` under `packages:`). No npm / pnpm / Bun.
- **Signing**: automatic, `DEVELOPMENT_TEAM = X9FHM3F6WK`. Distribution via Developer ID + notarization for direct download, or TestFlight/App Store.
- **Secrets**: the only runtime secret is the Ollama Cloud API key (ollama.com → Settings → API keys), entered in-app Settings, stored in Keychain (iCloud-synced). No `.env`.

## Testing & QA

- Tests live in `ChatterTests/` (XCTest, `@testable import Chatter`), registered as target `ChatterTests` in `project.yml` and wired into the `Chatter` scheme's test action. Run via the `test` command above.
- Coverage: pure codecs / transfer / tool providers (OKF round-trips must be byte-identical for canonical files, lossless otherwise), plus `ChatEngineTests` driving the tool loop against mocked `OllamaServiceProtocol` / `MCPClientProtocol` / `KnowledgeToolProviding`. No UI tests.
- In-memory test containers must use `ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)`: tests run hosted in the app process, and the `.automatic` default hooks the in-memory store into the app's CloudKit mirroring — the first `save()` crashes with "No eligible connection available".
- macOS quirk already handled in `project.yml`: XcodeGen emits the iOS bundle layout for `TEST_HOST`; the `TEST_HOST[sdk=macosx*]` override points at `Contents/MacOS/Chatter`, without it macOS tests can't find the host app.

## macOS Sandbox Split (easy to get wrong)

- **Debug** uses `Chatter-macOS.entitlements` with the App Sandbox **off** so stdio MCP servers can spawn subprocesses.
- **Release** uses `Chatter-macOS-Release.entitlements` (set in `project.yml` configs) with the sandbox **on** — TestFlight/App Store requires it. Sandboxed builds hide the stdio transport at runtime (`MCPTransportKind.stdioAvailable`); HTTP/SSE MCP works everywhere.
- Don't "fix" the Debug sandbox flag, and don't add capabilities to only one of the two entitlement files.
