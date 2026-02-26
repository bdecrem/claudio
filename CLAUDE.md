# Claudio

Native iPhone client for OpenClaw — a self-hosted AI agent backend. The app is purely a client: the backend handles all AI logic, tool calls, memory, and TTS proxying. Users configure one server URL and go.

## Apple Documentation

An Apple Docs MCP server is configured in `.mcp.json`. When working with Apple frameworks and APIs, don't guess — look it up. Use `search_apple_docs`, `get_apple_doc_content`, and related MCP tools to verify API signatures, availability, and correct usage before writing code.

## Build Verification

After modifying Swift files, ALWAYS build to catch compile errors:

```
xcodebuild -project Claudio.xcodeproj -scheme Claudio -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build 2>&1 | tail -20
```

If the build fails, fix the errors before moving on. Do not skip this step.

After build succeeds, run unit tests:

```
xcodebuild -project Claudio.xcodeproj -scheme Claudio -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' test 2>&1 | tail -30
```

If any tests fail, fix them before moving on. When adding new parsing logic or modifying models, add tests in `ClaudioTests/`.

To take a simulator screenshot:

```
xcrun simctl io booted screenshot screenshot.png
```

## Test Coverage

Tests live in `ClaudioTests/`. Current test files:

**RPCTypesTests.swift** (18 tests) — Wire format parsing:
- `AnyCodableValue` type accessors and coercion (string, int, double, bool, null)
- `AnyCodableValue` JSON encode/decode round-trip
- `ChatEvent` parsing: delta, final, invalid state, nil payload
- `AgentEvent` parsing: args flattening (int/double/bool → string), missing fields
- `HistoryMessage` parsing: plain string, content blocks, empty content skipping
- `WSAgent` parsing: full fields, name fallback to id, missing id rejection

**ChatServiceTests.swift** (14 tests) — State management:
- Message Codable round-trip (fields survive encode/decode)
- Streaming messages always restore as non-streaming
- Message array serialization
- API representation output
- Agent switching preserves per-agent chat history
- Switching to same agent is a no-op
- Agent visibility toggling (hide/show)
- Cannot hide the last visible agent
- Hiding selected agent auto-switches to first visible
- Clear messages resets messages and errors
- Chat state persists to and restores from UserDefaults
- Stale chat state (>24h) is discarded
- Fresh init has no servers
- ToolCall.isComplete

## Architecture

Pure SwiftUI, no external dependencies. iOS 17+. No API keys, no credentials, no auth stored on device — ever.

## API Contract

All endpoints on the user-configured server URL. All unauthenticated for v1.

```
GET  {server}/api/agents
  → { "agents": [{"id": "mave", "name": "Mave", "emoji": "🌊", "color": "#00CCCC"}, ...] }

POST {server}/api/chat/agent
  Body: { "messages": [...], "agent": "mave" }
  → { "choices": [{"message": {"role": "assistant", "content": "..."}}] }

POST {server}/api/tts          → audio/mpeg binary
  Body: { "text": "response text", "agent": "mave" }
```

## Key Behaviors

- **Settings**: One field — Server URL. On save/change, fetch `/api/agents`. If that fails, fall back to free-text agent name field.
- **Text chat**: POST to `/api/chat/agent`, extract `choices[0].message.content`. Maintain full messages array in memory, send history each turn.
- **Voice input**: Apple Speech framework (SFSpeechRecognizer + AVAudioEngine). Hold mic to speak, release to send transcript as a normal message.
- **Voice output**: On agent response, POST text to `/api/tts`, play returned audio. Show speaking indicator during playback. If TTS fails, still show text — voice is enhancement, not requirement.
- **Conversation**: Text and voice share the same messages array and session. Switching modes mid-conversation is fine.
- **Errors**: "Can't connect to server" with Settings prompt if unreachable. Graceful fallbacks. Never show raw errors or crash.

## Not in v1

No auth, no user accounts, no push notifications, no background modes, no streaming responses, no direct Hume integration.

## File Structure

```
Claudio/
├── ClaudioApp.swift
├── Models/
│   ├── Message.swift             — Chat message model
│   └── ChatService.swift         — API client (chat, agents, TTS)
├── Views/
│   ├── ChatView.swift            — Main conversation screen
│   ├── MessageBubble.swift       — Message row
│   ├── InputBar.swift            — Text/voice input area
│   ├── VoiceOrb.swift            — Pulsing voice animation
│   ├── AgentPicker.swift         — Agent selector
│   └── SettingsView.swift        — Server URL config
├── Services/
│   ├── SpeechRecognizer.swift    — Apple Speech STT
│   └── HapticsManager.swift      — Haptic feedback
├── Theme/
│   └── Theme.swift               — Colors, fonts, spacing
└── Info.plist
```

## Design

- Background #0A0A0A, text #F5F0EB, accent #D4A574
- SF Pro Rounded, generous whitespace, minimal chrome
- Voice orb: concentric pulsing circles, audio-level reactive
