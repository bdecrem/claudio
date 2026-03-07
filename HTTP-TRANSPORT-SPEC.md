# Task: Add HTTP+SSE Transport to Claudio

## What we're doing
Claudio currently uses WebSockets to talk to the OpenClaw server. We're adding HTTP+SSE as a second transport — and making it the **default**. WebSocket stays as an "Advanced" option in Settings.

## Why
HTTP is more reliable on mobile. No connection to maintain, no reconnect logic, no device pairing. Each message is a fresh request. Works across network switches, sleep/wake, background kills.

## How the HTTP connection works

### Endpoint
OpenClaw exposes an **OpenAI-compatible chat completions API**:

```
POST {baseURL}/v1/chat/completions
```

### Auth
Bearer token in the Authorization header:
```
Authorization: Bearer {token}
```

The token is the same one already stored in the server config. No device pairing, no Ed25519 challenge, no approval step.

### URL conversion
Server config stores WebSocket URLs (`ws://` or `wss://`). Convert for HTTP:
- `ws://` → `http://`
- `wss://` → `https://`
- Then append `/v1/chat/completions`

Example: `wss://theaf-web.ngrok.io` → `https://theaf-web.ngrok.io/v1/chat/completions`

### Non-streaming request
```json
POST /v1/chat/completions
Content-Type: application/json
Authorization: Bearer {token}

{
  "model": "default",
  "messages": [
    {"role": "user", "content": "Hello"}
  ]
}
```

Response:
```json
{
  "id": "chatcmpl_abc123",
  "object": "chat.completion",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "Hey there!"},
    "finish_reason": "stop"
  }]
}
```

### Streaming request (SSE)
Add `"stream": true` to the request body. Response is Server-Sent Events:

```json
{
  "model": "default",
  "stream": true,
  "messages": [
    {"role": "user", "content": "Hello"}
  ]
}
```

Response (each line is a separate SSE event):
```
data: {"id":"chatcmpl_abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"}}]}

data: {"id":"chatcmpl_abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hey"}}]}

data: {"id":"chatcmpl_abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" there!"}}]}

data: {"id":"chatcmpl_abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

Each `data:` line is JSON. Parse `choices[0].delta.content` and append to the streaming message. When you see `finish_reason: "stop"` or `data: [DONE]`, the response is complete.

### Conversation history
The HTTP endpoint is **stateless** — you must send the full conversation history in each request. Maintain an array of `{"role": "user"|"assistant", "content": "..."}` messages locally and send them all each time.

### Agent selection
To target a specific agent, include `user` field in the request body:
```json
{
  "model": "default",
  "stream": true,
  "user": "agent:amber:main",
  "messages": [...]
}
```

The `user` field is the session key. Format: `agent:{agentId}:main` where `agentId` matches the agent ID from the server config.

### Getting the agent list
To fetch available agents, you can use:
```
GET {baseURL}/v1/models
Authorization: Bearer {token}
```

This returns the model list. However, the agent list may need to come from a different source. For now, you can hardcode a fallback or reuse the WebSocket agent fetch as a one-shot call.

**Simpler approach:** When in HTTP mode, still make a single WebSocket connection at startup JUST to fetch the agent list (the `agents.list` RPC call), then disconnect. Or, if the agent list is cached from a previous WS session, use that cache. The agents don't change often.

## What to build

### 1. `Claudio/Services/HTTPTransport.swift` (NEW FILE)

A class that:
- Takes a server URL and token
- Converts WS URL to HTTP URL
- Sends chat messages via `POST /v1/chat/completions` with streaming
- Parses SSE chunks and calls back with each content delta
- Maintains conversation history (array of messages)
- Has a `sendMessage(_ text: String, agentId: String)` method
- Reports "connection state" as always `.connected` (it's stateless)

Use `URLSession` with `AsyncBytes` for SSE streaming. Something like:

```swift
let (bytes, response) = try await URLSession.shared.bytes(for: request)
for try await line in bytes.lines {
    if line.hasPrefix("data: ") {
        let json = String(line.dropFirst(6))
        if json == "[DONE]" { break }
        // parse delta.content, call handler
    }
}
```

### 2. Settings toggle (MODIFY `SettingsView.swift`)

Add a "Connection Mode" section:
```
Connection Mode
  ○ Standard (HTTP)    ← default
  ○ Advanced (WebSocket)
```

Use a Picker or segmented control. Persist in UserDefaults under key `"connectionMode"` with values `"http"` or `"websocket"`.

### 3. Wire into ChatService (MODIFY `ChatService.swift`)

- Read `connectionMode` from UserDefaults (default: `"http"`)
- When `"http"`: use HTTPTransport to send messages and receive streaming responses
- When `"websocket"`: use existing WebSocketClient (current behavior, unchanged)
- The message display/UI code stays exactly the same — only the send/receive path changes

Key change: `sendMessage` in ChatService currently sends via WebSocket RPC (`chat.send`). In HTTP mode, it instead calls `HTTPTransport.sendMessage()` which does the HTTP+SSE request.

### 4. Conversation history management

In HTTP mode, ChatService needs to build the messages array from chat history:
```swift
let apiMessages = messages.map { msg in
    ["role": msg.isUser ? "user" : "assistant", "content": msg.text]
}
```
Send this array in each request. The server needs it because HTTP is stateless.

## What NOT to change
- Don't delete or break WebSocketClient.swift
- Don't change the message UI (ChatView, MessageBubble, etc.)
- Don't change how messages are stored/displayed
- Don't change the QR scanner flow — it already provides URL+token which works for both modes

## Tradeoffs the user should know
In HTTP mode:
- ✅ More reliable connection
- ✅ No device pairing needed
- ✅ Works across network switches
- ✅ Streaming still works (SSE)
- ❌ No live tool-use updates (tool calls happen server-side, you only see the final text)
- ❌ No real-time push from server (use push notifications instead)

## Test it
After building:
1. Set connection mode to HTTP (should be default)
2. Send a message
3. Verify streaming response appears token by token
4. Switch to WebSocket mode
5. Verify existing WS behavior still works
6. Switch back to HTTP

## Branch
Work on the `http-transport` branch. Commit when done.
