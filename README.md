# Chatter

Multiplatform (iOS / iPadOS / macOS) LLM chat app powered by **Ollama Cloud**, with
**MCP tool** support and user-defined **Agents**. UI inspired by the Google Gemini app.

## Features

- **Ollama Cloud** chat with live token streaming (`/api/chat`, NDJSON).
- **Agents**: each has its own model, system prompt, temperature, icon/color, and set of MCP servers.
- **MCP tools**: Streamable HTTP + SSE on all platforms; stdio (local subprocess) on macOS.
  Static auth header per server. The model's tool calls are run and fed back automatically (agentic loop).
- **Session history** with SwiftData, synced across devices via **CloudKit** (when the iCloud
  capability is provisioned; falls back to a local store otherwise).
- Gemini-style design: airy canvas, brand gradient, rounded surfaces, streaming typing indicator.

## Requirements

- Xcode 16+ (built with Xcode 26), Swift 5 language mode.
- An **Ollama Cloud API key** (ollama.com → Settings → API keys), entered in the app's Settings.
  Stored in the keychain (synced via iCloud Keychain).

## Project generation

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen   # if needed
./generate.sh           # runs xcodegen + patches the scheme
```

> `generate.sh` also disables the scheme option "Enable backtrace recording"
> (Queue Debugging) — on Xcode 26 / macOS 26 it crashes the app under the
> debugger with `-[OS_dispatch_mach_msg _setContext:]`.

## Build & run

```bash
# iOS Simulator
xcodebuild -project Chatter.xcodeproj -scheme Chatter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# macOS
xcodebuild -project Chatter.xcodeproj -scheme Chatter -destination 'platform=macOS' build

# Or just open it
open Chatter.xcodeproj
```

## CloudKit sync

CloudKit sync is configured: container `iCloud.team.budo.chatter`, per-platform
entitlements (`Chatter/Chatter-iOS.entitlements`, `Chatter/Chatter-macOS.entitlements`)
with CloudKit + push, and the `remote-notification` background mode so devices pick up
changes promptly. `Persistence.makeContainer()` requests `.automatic` CloudKit and falls
back to a local store when iCloud is unavailable (e.g. no signed-in account).

Signing uses `DEVELOPMENT_TEAM` from `project.yml`; building for a different team means
changing that value and the container ID.

## macOS stdio MCP servers

stdio servers are launched as subprocesses, so the macOS target ships with the App Sandbox
**disabled** (`Chatter/Chatter-macOS.entitlements`). This is fine for local/dev use; a
sandboxed App Store build would need to drop stdio (HTTP/SSE still work everywhere).
Distributing the Mac app therefore means Developer ID + notarization, not the Mac App Store.

## Structure

```
Chatter/
  ChatterApp.swift, AppEnvironment.swift, Persistence.swift
  Models/        Agent, ChatSession, Message, MCPServerConfig  (SwiftData, CloudKit-safe)
  Services/      OllamaService, MCPConnectionManager, ChatEngine, KeychainService, JSONValue
  ViewModels/    ChatViewModel
  Views/         RootView, Sidebar/, Chat/, Agents/, Settings/, Components/
  DesignSystem/  Theme
```
