# OpenClaw Technical Overview

> Reference for Claudio client developers. Describes how OpenClaw works so we can build the client correctly without modifying OpenClaw.

## What OpenClaw Is

OpenClaw is a **self-hosted personal AI assistant** written in TypeScript (Node ≥22). The user runs a single **Gateway** process on their own machine or server. The Gateway is the control plane — it manages agents, sessions, channels, tools, TTS, and all AI model interactions. Claudio is one of many possible clients; OpenClaw also supports WhatsApp, Telegram, Slack, Discord, Signal, iMessage, and 15+ other channels.

The Gateway listens on a single port (default `18789`) that multiplexes:
- **WebSocket** — real-time RPC + streaming events (primary protocol)
- **HTTP REST** — OpenAI-compatible `/v1/chat/completions` endpoint
- **Control UI** — built-in web dashboard

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   Gateway                        │
│              (Node.js process)                   │
│         ws://127.0.0.1:18789 (default)          │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐ │
│  │  Agents   │  │ Sessions │  │   Channels    │ │
│  │ (Pi core) │  │ (JSONL)  │  │ (WA/TG/etc)  │ │
│  └──────────┘  └──────────┘  └───────────────┘ │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐ │
│  │  Models   │  │   TTS    │  │    Tools      │ │
│  │ (failover)│  │(3 engines)│ │ (browser/fs)  │ │
│  └──────────┘  └──────────┘  └───────────────┘ │
└────────┬───────────────┬───────────────┬────────┘
         │               │               │
    WebSocket        HTTP/SSE       Channel APIs
    (Claudio)        (Claudio)     (WhatsApp etc)
```

## Two Client Protocols

Claudio can talk to OpenClaw via **either** protocol. Both hit the same Gateway port.

### 1. WebSocket Protocol (Advanced Mode)

Full-duplex connection with RPC request/response and server-pushed events.

**Connection flow:**
1. Client opens `wss://{server}:{port}`
2. Server sends `event: connect.challenge` with a `nonce`
3. Client sends `req` with method `connect`, including auth credentials and client metadata
4. Server responds with `hello-ok` containing: protocol version, server info, feature list, snapshot (presence, health), auth result, and policy (tick interval, max payload)
5. Client is now connected and can send RPC requests

**Frame types (all JSON over WebSocket text frames):**

```typescript
// Client → Server
{ "type": "req", "id": "<unique>", "method": "<method>", "params": { ... } }

// Server → Client (response to a request)
{ "type": "res", "id": "<matching-req-id>", "ok": true, "payload": { ... } }
{ "type": "res", "id": "<matching-req-id>", "ok": false, "error": { "code": "...", "message": "..." } }

// Server → Client (unsolicited event)
{ "type": "event", "event": "<event-name>", "payload": { ... }, "seq": <int> }
```

**Key RPC methods:**

| Method | Purpose |
|--------|---------|
| `connect` | Authenticate (first req after challenge) |
| `chat.send` | Send a message to the agent |
| `chat.abort` | Cancel an in-progress agent run |
| `chat.history` | Fetch conversation history |
| `agents.list` | List configured agents |
| `agents.identity` | Get agent name/emoji/avatar |
| `sessions.list` | List active sessions |
| `sessions.reset` | Start a fresh session |
| `tts.convert` | Convert text to speech audio |
| `tts.status` | Check TTS config |
| `tts.providers` | List available TTS engines |

**Key server events:**

| Event | Purpose |
|-------|---------|
| `connect.challenge` | Auth challenge with nonce |
| `chat` | Chat state updates (delta/final/error) |
| `agent` | Agent execution events (tool use, lifecycle) |
| `tick` | Periodic heartbeat with timestamp |
| `presence` | Client connect/disconnect |
| `health` | Channel health changes |
| `shutdown` | Server shutting down |

**Chat event payloads:**

```typescript
// Streaming delta (arrives repeatedly as agent generates text)
{
  "runId": "abc123",
  "sessionKey": "agent:mave:main",
  "seq": 5,
  "state": "delta",
  "message": {
    "role": "assistant",
    "content": [{ "type": "text", "text": "partial response so far..." }],
    "timestamp": 1710000000000
  }
}

// Final complete response
{
  "runId": "abc123",
  "sessionKey": "agent:mave:main",
  "seq": 12,
  "state": "final",
  "message": {
    "role": "assistant",
    "content": [{ "type": "text", "text": "full response text" }],
    "timestamp": 1710000000000
  }
}

// Error
{
  "runId": "abc123",
  "sessionKey": "agent:mave:main",
  "seq": 3,
  "state": "error",
  "errorMessage": "Model returned an error"
}
```

**Agent events** are lower-level execution traces. The `stream` field distinguishes:
- `"assistant"` — text generation (text deltas)
- `"tool"` — tool invocation (phase: start/result/error)
- `"lifecycle"` — run lifecycle (phase: start/end/error)

```typescript
{
  "runId": "abc123",
  "seq": 1,
  "stream": "tool",
  "ts": 1710000000000,
  "data": {
    "phase": "start",
    "name": "web_search",
    "args": { "query": "..." }
  }
}
```

**Agent execution model:** Chat sends are two-stage. The `chat.send` response comes back immediately with `status: "accepted"`. Then `chat` events stream in (deltas), and finally a `chat` event with `state: "final"` signals completion.

**Auth in WebSocket mode:**
The `connect` request includes an `auth` object:
```json
{
  "auth": {
    "token": "the-gateway-token",
    "deviceToken": "optional-device-specific-token"
  }
}
```
The token is the same `OPENCLAW_GATEWAY_TOKEN` configured on the server.

### 2. HTTP+SSE Protocol (Standard Mode — Claudio Default)

OpenAI-compatible REST API. Simpler, more reliable on mobile (no persistent connection).

**Endpoint:**
```
POST {baseURL}/v1/chat/completions
Authorization: Bearer {token}
Content-Type: application/json
```

URL conversion from stored WebSocket URLs:
- `ws://` → `http://`
- `wss://` → `https://`

**Non-streaming request:**
```json
{
  "model": "default",
  "user": "agent:mave:main",
  "messages": [
    { "role": "user", "content": "Hello" }
  ]
}
```

**Response:**
```json
{
  "id": "chatcmpl_abc123",
  "object": "chat.completion",
  "choices": [{
    "index": 0,
    "message": { "role": "assistant", "content": "Hey there!" },
    "finish_reason": "stop"
  }]
}
```

**Streaming request (add `"stream": true`):**
```
data: {"id":"chatcmpl_abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"}}]}

data: {"id":"chatcmpl_abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hey"}}]}

data: {"id":"chatcmpl_abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" there!"}}]}

data: {"id":"chatcmpl_abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}}]}

data: [DONE]
```

**Agent selection:** The `user` field is the session key. Format: `agent:{agentId}:main`.

**Conversation history:** HTTP is stateless. Send the full message array every request. The server does not remember previous turns.

**Tradeoffs vs WebSocket:**
- ✅ No persistent connection, no reconnect logic
- ✅ Works across network switches, sleep/wake
- ✅ Bearer token auth (no challenge/nonce dance)
- ❌ No live tool-use updates (only final text)
- ❌ No server-pushed events (presence, health, typing)
- ❌ No `chat.abort` (can't cancel in-flight requests easily)

## Agents

OpenClaw runs one or more **agents**, each with:
- **id** — unique identifier (e.g., `"mave"`, `"amber"`)
- **name** — display name
- **emoji** — single emoji for UI
- **workspace** — directory containing agent context files

Each agent has these user-editable context files:
- `AGENTS.md` — operating instructions and memory
- `SOUL.md` — persona, tone, boundaries
- `TOOLS.md` — tool usage guidance
- `IDENTITY.md` — name and emoji config
- `USER.md` — user profile/preferences
- `BOOTSTRAP.md` — one-time setup (auto-deleted after first run)

Agents are configured in `openclaw.json` under `agents.list[]`. The default agent ID is used when no agent is specified.

## Sessions

Sessions are the conversation context containers. Key concepts:

- **Session key** — deterministic identifier: `agent:{agentId}:{scope}` (e.g., `agent:mave:main`)
- **Transcript** — stored as JSONL at `~/.openclaw/agents/{agentId}/sessions/{sessionId}.jsonl`
- **Session reset** — daily at 4 AM gateway-local time by default, or on `/new`/`/reset` command
- **Idle reset** — optional sliding window (`idleMinutes`)

**DM scope modes** control session isolation for multi-user setups:
- `main` (default) — all DMs share one session per agent
- `per-peer` — isolated by sender
- `per-channel-peer` — isolated by channel + sender

For Claudio's DM use case (single user, single device), the session key is always `agent:{agentId}:main`.

## Models

OpenClaw supports multiple AI providers with automatic failover:
- **OpenAI** (GPT-4, etc.)
- **Anthropic** (Claude)
- **Google** (Gemini)
- **OpenRouter** (aggregator)
- Many others

Configuration: `agents.defaults.model.primary` and `agents.defaults.model.fallbacks`. Per-agent overrides via `agents.list[].model`.

API keys are set in the `.env` file or `openclaw.json`. The model can be switched at runtime via `/model` commands without restarting.

## Text-to-Speech

Three TTS engines, with automatic fallback:

| Engine | API Key Required | Quality |
|--------|-----------------|---------|
| ElevenLabs | Yes (`ELEVENLABS_API_KEY`) | Best |
| OpenAI | Yes (`OPENAI_API_KEY`) | Good |
| Edge TTS | No | Decent (Microsoft neural voices) |

**Via WebSocket RPC:**
```json
{ "type": "req", "id": "t1", "method": "tts.convert", "params": { "text": "Hello world" } }
```
Response includes `audioPath` — a file path on the server. The client would need to fetch this.

**For Claudio's HTTP-based TTS:**
Claudio currently POSTs to `/api/tts` on the OpenClaw server. This is a **Claudio-specific proxy endpoint** — not part of OpenClaw's standard API. It returns audio/mpeg binary directly.

## Tools

Agents have access to these tool categories:
- **File system** — read, write, edit, apply_patch
- **Execution** — exec, process, bash
- **Web** — web_search, web_fetch
- **Browser** — full Chromium automation
- **Canvas** — visual workspace rendering
- **Messaging** — send to channels (Discord, Slack, etc.)
- **Session** — list, history, spawn sub-sessions
- **Automation** — cron jobs, webhooks

Tools are invoked server-side by the agent. The client sees tool activity via `agent` events (WebSocket mode only) with `stream: "tool"`.

Tool visibility is controlled by `tools.profile` presets (`minimal`, `coding`, `messaging`, `full`) plus allow/deny overrides.

## Configuration

Server config lives in `~/.openclaw/openclaw.json` (JSON5). Key sections:

```json5
{
  "gateway": {
    "port": 18789,
    "auth": { "token": "..." }
  },
  "agents": {
    "defaults": {
      "model": { "primary": "anthropic/claude-sonnet-4-20250514" },
      "workspace": "~/openclaw-workspace"
    },
    "list": [
      { "id": "mave", "name": "Mave", "emoji": "🌊" }
    ]
  },
  "messages": {
    "tts": { "provider": "elevenlabs", "auto": "inbound" }
  },
  "channels": { ... }
}
```

Config supports hot-reload (`gateway.reload.mode: "hybrid"` by default).

## What Claudio Needs from OpenClaw

For the DM (Agent 1:1) use case, Claudio needs:

1. **Agent list** — `agents.list` via WS RPC or cached
2. **Send message + stream response** — `POST /v1/chat/completions` (HTTP) or `chat.send` (WS)
3. **TTS** — `POST /api/tts` (Claudio proxy) or `tts.convert` (WS RPC)
4. **Session management** — handled server-side; client sends session key in requests

Claudio does **not** need to:
- Manage the agent workspace or files
- Handle tool execution (server-side)
- Deal with channel routing (Claudio IS the channel)
- Implement the config system

## Error Codes

Standard error shape:
```json
{
  "code": "INVALID_REQUEST",
  "message": "Human-readable description",
  "retryable": false,
  "retryAfterMs": 5000
}
```

Common codes:
- `INVALID_REQUEST` — bad params
- `UNAUTHORIZED` — auth failed
- `UNAVAILABLE` — service/feature not available
- `RATE_LIMITED` — too many requests
- `TIMEOUT` — request timed out

## Useful Links

- **Repo:** https://github.com/openclaw/openclaw
- **Docs:** https://docs.openclaw.ai
- **DeepWiki:** https://deepwiki.com/openclaw/openclaw
- **Gateway docs:** https://docs.openclaw.ai/gateway
- **Agent docs:** https://docs.openclaw.ai/concepts/agent
- **Session docs:** https://docs.openclaw.ai/concepts/session
- **TTS docs:** https://docs.openclaw.ai/tts.md
- **Tools docs:** https://docs.openclaw.ai/tools
- **Streaming docs:** https://docs.openclaw.ai/concepts/streaming
