# Chatter Privacy Policy

*Last updated: July 7, 2026*

Chatter is built on a simple principle: **your data is none of our business.** This policy explains what data Chatter handles, where it lives, and who can access it.

## What we collect

**Nothing.** Chatter has no analytics, no tracking, no telemetry, no crash reporting, no advertising identifiers, and no servers of our own. We never see your conversations, your agents, your documents, or your usage. Chatter requires no account, no sign-up, and no login.

## Where your data lives

- **On your devices.** Chats, agents, knowledge bases, agent memories, and skills are stored locally in the app's database.
- **In your personal iCloud.** If iCloud is enabled, the same data syncs across your devices through Apple CloudKit — in the *private* database tied to your Apple ID. Only you can access it; we cannot. Apple's handling of CloudKit data is governed by [Apple's Privacy Policy](https://www.apple.com/legal/privacy/).
- **Your API key** is stored exclusively in the Apple Keychain (synced via iCloud Keychain). It is never written to the app database or shared with anyone but the API it belongs to.

You can delete any of this data at any time from within the app; deleting the app (and its iCloud data via iOS/macOS settings) removes everything.

## Services you choose to connect

Chatter is a client for services **you** configure with **your own** credentials. When you use them, your data goes directly from your device to that service — never through us:

- **Ollama Cloud** (required): your messages, attached images, and knowledge excerpts are sent to Ollama Cloud to generate responses, using your own API key. Ollama Cloud operates with zero data retention according to its provider; see the [Ollama privacy policy](https://ollama.com/privacy) for their terms.
- **MCP servers** (optional): if you add Model Context Protocol servers (for example, self-hosted tools on your LAN), your agents send tool requests and receive results directly from those servers. What those servers do with the data is governed by whoever operates them — typically you.
- **Web search** (optional, per agent): when enabled, search queries the agent formulates are sent to Ollama's web search API under your API key.

Chatter makes no network connections other than to the services listed above.

## Third-party components

Chatter's only third-party software dependency is the open-source [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), used to talk to the MCP servers you configure. It phones home to no one.

## Changes to this policy

If Chatter's data handling ever changes, this document will be updated and the change noted in the app's release notes before it takes effect.

## Contact

Questions about privacy in Chatter: **fabian@budo-team.ch**
