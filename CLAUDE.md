# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Chatter — a multiplatform (iOS 17+ / macOS 14+ / watchOS 10+) SwiftUI LLM chat app backed by Ollama Cloud, with MCP tool support and user-defined Agents. One shared codebase: app target `Chatter` (iOS+macOS), watch target `ChatterWatch`, test target. The only package dependency is the MCP Swift SDK.

The watchOS app (`ChatterWatch/`, own views, watchOS 10+) is a standalone chat client — read history, reply via dictation — that shares models, services, `ChatEngine`, `AppEnvironment`, and `ChatViewModel` with the main app (explicit source paths in `project.yml`, excluding the PDF importer and `ImageAttachmentProcessor`, which don't exist on watchOS). It syncs everything (agents, MCP configs, sessions via CloudKit; the API key from the paired iPhone via WatchConnectivity/`WatchKeySync` — iCloud Keychain doesn't reliably sync to watchOS) and intentionally has no settings UI.

## Project generation & builds

`Chatter.xcodeproj` is **generated and gitignored** — the source of truth is `project.yml` (XcodeGen). Never edit the xcodeproj; after changing `project.yml` (or on a fresh checkout), regenerate with:

```bash
./generate.sh    # NOT `xcodegen generate` directly
```

`generate.sh` also patches the scheme to disable "Enable backtrace recording" (queue debugging), which crashes the app under LLDB on Xcode 26 / macOS 26. New source files under `Chatter/` are picked up automatically (the target globs the folder), but you must re-run `./generate.sh` for them to appear in the project.

```bash
# Build for iOS Simulator
xcodebuild -project Chatter.xcodeproj -scheme Chatter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Build for macOS
xcodebuild -project Chatter.xcodeproj -scheme Chatter -destination 'platform=macOS' build

# Build for watchOS (compiling only needs the generic simulator destination)
xcodebuild -project Chatter.xcodeproj -scheme ChatterWatch \
  -destination 'generic/platform=watchOS Simulator' build
```

Tests live in `ChatterTests` (codecs, transfer, tool providers, plus `ChatEngineTests` driving the tool loop against the protocol mocks): `xcodebuild ... -destination 'platform=macOS' test`. Signing is automatic with the team from `project.yml`; entitlements are per-platform files (`Chatter/Chatter-iOS.entitlements`, `Chatter/Chatter-macOS.entitlements` — the APNs entitlement key differs between the platforms, and only macOS carries the sandbox key). TestFlight release: bump `CURRENT_PROJECT_VERSION` in `project.yml`, `./generate.sh`, archive with `xcodebuild ... archive -allowProvisioningUpdates`, upload via Xcode Organizer. **If the release adds or changes any `@Model`, deploy the CloudKit schema to Production first** (see below).

## Architecture

The data flow for a chat turn: `ComposerView` → `ChatViewModel` → `ChatEngine.send(...)` → `OllamaService` (streaming) + `MCPConnectionManager` (tool calls) → SwiftData `Message` objects that views observe directly.

- **`AppEnvironment`** (`@MainActor @Observable`, injected via SwiftUI environment) owns the three shared services — `OllamaService`, `MCPConnectionManager`, `ChatEngine` — plus cross-view UI state (selected session, cached model list, API-key presence).
- **`ChatEngine`** drives one assistant turn including the agentic tool loop: stream the response → if the model requested tools, execute them via MCP, append `tool` messages, and stream again — up to 42 tool rounds, after which one last round is streamed *without* offering tools so the turn always ends in a text answer. Streaming writes into a live SwiftData `Message` with `isStreaming = true`; token deltas are **buffered and flushed at ~12 Hz** because mutating the `@Model` per token re-renders (and re-parses Markdown for) the whole message and stalls the main thread. Preserve this batching when touching the streaming path. Besides MCP it dispatches built-in providers: `knowledge__*`, `memory__*`, skills, artifacts, web — and `reminders__*` (`ReminderToolProvider`/`ReminderScheduler`): reminders fire as local notifications (`UNUserNotificationCenter`, reconciled per device at launch so CloudKit-synced entries fire everywhere); a reminder with an `actionPrompt` runs that prompt as an agent turn when the app is next opened after the due date (`AppEnvironment.runDueReminderActions`), stamped `actionCompletedAt` before the turn starts so it can't double-run.
- **`MCPConnectionManager`** owns live MCP `Client` sessions and a **namespaced tool registry** (`serverName.toolName`) so tools from different servers can't collide; `ChatEngine` calls tools by namespaced name. Transports: Streamable HTTP + legacy SSE (`LegacySSEClientTransport`) on all platforms; stdio subprocesses on macOS only (`#if os(macOS)` — this is why the macOS sandbox is disabled in `Chatter-macOS.entitlements`).
- **`OllamaService`** streams NDJSON from Ollama Cloud `/api/chat` (deltas, thinking traces, tool calls). The API key lives in the Keychain via `KeychainService` (iCloud-synced), never in SwiftData or UserDefaults.
- **Services are behind protocols** (`Services/Protocols/`): `OllamaServiceProtocol`, `MCPClientProtocol`, `KnowledgeToolProviding` — `ChatEngine` and views depend on the protocols (the mocking seam for `ChatterTests`).
- **Background execution & handoff**: `TurnRuntimeKeeper` wraps every turn (`AppEnvironment.runTurn`) — iOS 26 uses `BGContinuedProcessingTask` (system Live Activity), older iOS falls back to `beginBackgroundTask`; a turn finishing while the app is inactive posts a local notification. `HandoffRequest` (model) + `HandoffCoordinator` (claim rules) + `HandoffServer` (macOS, always on) implement the CloudKit-based turn handoff to a Mac — see `SERVER-HANDOFF.md`.

### SwiftData models must stay CloudKit-compatible

All models (`Agent`, `ChatSession`, `Message`, `MCPServerConfig`, `HandoffRequest`, …) sync via CloudKit (`Persistence.makeContainer()` tries `.automatic`, falls back to local, then in-memory). That imposes conventions any new/changed model property must follow:

- Every property needs a default value; relationships must be optional; no `@Attribute(.unique)`.
- Nested/structured data is stored as JSON strings or raw values with computed-property accessors (e.g. `Message.toolCallsJSON` ↔ `toolCalls`, `roleRaw` ↔ `role`). Enums are stored as their raw value.
- Message ordering uses an explicit `orderIndex` (via `session.nextOrderIndex`), not timestamps.

**CloudKit schema deployment (before every TestFlight release that touches a `@Model`):** CloudKit has separate Development and Production environments. Debug builds talk to Development, where SwiftData creates record types/fields automatically; TestFlight/App Store builds talk to Production, which is only updated by a manual deploy. Shipping a build whose models aren't in the Production schema makes every `RecordSave` fail with `BAD_REQUEST`, which stalls the device's entire export pipeline — nothing syncs anymore, and un-exported data is lost if the app is deleted (this happened with 1.4: `Skill`/`MemoryEntry` were missing in Production). Procedure: run a debug build once **and write one record of the new model type** — the schema is only pushed to Development on the first actual save, not on container init (e.g. create one reminder for `ReminderEntry`) — then in the [CloudKit Console](https://icloud.developer.apple.com) → container `iCloud.team.budo.chatter` → Schema → *Deploy Schema Changes* to Production, **then** upload the build. Sync health is visible in Settings → iCloud Sync (`CloudSyncMonitor`), and container-fallback / export errors are logged via `AppLogger.data`.

### UI

Views live under `Views/` (Sidebar, Chat, Agents, Settings, Components); shared styling in `DesignSystem/Theme.swift` (Gemini-inspired: brand gradient, airy surfaces). `MarkdownText` renders assistant Markdown. Platform differences are handled inline with `#if os(macOS)` in the shared views rather than separate view files.

## Conventions

- Commit messages are written in German.
- Logging goes through `AppLogger` (os.Logger categories: `api`, `mcp`, `data`, …) with `privacy: .public` annotations where needed.
- Save SwiftData contexts via `context.saveOrLog()` (extension in `Persistence.swift`) — best-effort, but failures are logged via `AppLogger.data` instead of disappearing like the former `try? context.save()`.
- In-memory test containers need `cloudKitDatabase: .none`: tests run hosted in the app process, and the `.automatic` default hooks the store into the app's CloudKit mirroring (crash on first save: "No eligible connection available").
- `NSAllowsArbitraryLoads` is intentionally true (self-hosted MCP servers over plain HTTP on LAN/Tailscale) — don't "fix" it.
