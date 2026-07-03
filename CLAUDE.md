# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Chatter — a multiplatform (iOS 17+ / macOS 14+) SwiftUI LLM chat app backed by Ollama Cloud, with MCP tool support and user-defined Agents. Single app target, one shared codebase for both platforms. The only package dependency is the MCP Swift SDK.

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
```

There is no test target. Builds run unsigned (`CODE_SIGN_IDENTITY: "-"`, empty `DEVELOPMENT_TEAM`); CloudKit sync silently falls back to a local store without a signing team.

## Architecture

The data flow for a chat turn: `ComposerView` → `ChatViewModel` → `ChatEngine.send(...)` → `OllamaService` (streaming) + `MCPConnectionManager` (tool calls) → SwiftData `Message` objects that views observe directly.

- **`AppEnvironment`** (`@MainActor @Observable`, injected via SwiftUI environment) owns the three shared services — `OllamaService`, `MCPConnectionManager`, `ChatEngine` — plus cross-view UI state (selected session, cached model list, API-key presence).
- **`ChatEngine`** drives one assistant turn including the agentic tool loop: stream the response → if the model requested tools, execute them via MCP, append `tool` messages, and stream again — up to 6 iterations. Streaming writes into a live SwiftData `Message` with `isStreaming = true`; token deltas are **buffered and flushed at ~12 Hz** because mutating the `@Model` per token re-renders (and re-parses Markdown for) the whole message and stalls the main thread. Preserve this batching when touching the streaming path.
- **`MCPConnectionManager`** owns live MCP `Client` sessions and a **namespaced tool registry** (`serverName.toolName`) so tools from different servers can't collide; `ChatEngine` calls tools by namespaced name. Transports: Streamable HTTP + legacy SSE (`LegacySSEClientTransport`) on all platforms; stdio subprocesses on macOS only (`#if os(macOS)` — this is why the macOS sandbox is disabled in `Chatter.entitlements`).
- **`OllamaService`** streams NDJSON from Ollama Cloud `/api/chat` (deltas, thinking traces, tool calls). The API key lives in the Keychain via `KeychainService` (iCloud-synced), never in SwiftData or UserDefaults.
- **Services are behind protocols** (`Services/Protocols/`): `OllamaServiceProtocol`, `MCPClientProtocol` — `ChatEngine` and views depend on the protocols.

### SwiftData models must stay CloudKit-compatible

All models (`Agent`, `ChatSession`, `Message`, `MCPServerConfig`) sync via CloudKit (`Persistence.makeContainer()` tries `.automatic`, falls back to local, then in-memory). That imposes conventions any new/changed model property must follow:

- Every property needs a default value; relationships must be optional; no `@Attribute(.unique)`.
- Nested/structured data is stored as JSON strings or raw values with computed-property accessors (e.g. `Message.toolCallsJSON` ↔ `toolCalls`, `roleRaw` ↔ `role`). Enums are stored as their raw value.
- Message ordering uses an explicit `orderIndex` (via `session.nextOrderIndex`), not timestamps.

### UI

Views live under `Views/` (Sidebar, Chat, Agents, Settings, Components); shared styling in `DesignSystem/Theme.swift` (Gemini-inspired: brand gradient, airy surfaces). `MarkdownText` renders assistant Markdown. Platform differences are handled inline with `#if os(macOS)` in the shared views rather than separate view files.

## Conventions

- Commit messages are written in German.
- Logging goes through `AppLogger` (os.Logger categories: `api`, `mcp`, `data`, …) with `privacy: .public` annotations where needed.
- `NSAllowsArbitraryLoads` is intentionally true (self-hosted MCP servers over plain HTTP on LAN/Tailscale) — don't "fix" it.
