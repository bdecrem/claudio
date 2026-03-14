# Claudio WebSocket Protocol Spec

## Overview

Claudio should connect to the OpenClaw Gateway via WebSocket — same as the macOS app, Android app, and Control UI. This makes it a peer to Discord, WhatsApp, TUI, etc. — **shared session, shared history, streaming responses**.

## Connection URL

- Local: `ws://127.0.0.1:18789`
- Remote (ngrok): `wss://YOUR-NGROK-URL.ngrok.app`

## Protocol: JSON text frames

Every message is one of three types:
- **Request**: `{ "type": "req", "id": "<unique>", "method": "<method>", "params": {...} }`
- **Response**: `{ "type": "res", "id": "<same-id>", "ok": true, "payload": {...} }` or `{ "ok": false, "error": {...} }`
- **Event**: `{ "type": "event", "event": "<name>", "payload": {...} }`

## Connection Flow

### Step 1: Wait for challenge

After connecting, the server sends:
```json
{ "type": "event", "event": "connect.challenge", "payload": { "nonce": "abc123", "ts": 1772060000000 } }
```

### Step 2: Generate device identity (once, persist in Keychain)

Generate an Ed25519 keypair. Persist it. The device ID is `SHA-256(publicKey)` as hex.

```
deviceId = SHA256(publicKeyBytes).hex()
publicKey = base64url(publicKeyBytes)  // SPKI DER format
```

### Step 3: Sign the challenge

Build the sign payload string:
```
"v2|{deviceId}|openclaw-ios|ui|operator|operator.read,operator.write|{signedAtMs}|{token}|{nonce}"
```

Sign it with Ed25519 using your private key. Encode signature as base64url.

### Step 4: Send connect request

```json
{
  "type": "req",
  "id": "c1",
  "method": "connect",
  "params": {
    "minProtocol": 3,
    "maxProtocol": 3,
    "client": {
      "id": "openclaw-ios",
      "displayName": "Claudio",
      "version": "1.0.0",
      "platform": "ios",
      "mode": "ui"
    },
    "role": "operator",
    "scopes": ["operator.read", "operator.write"],
    "caps": [],
    "auth": { "token": "<gateway-auth-token>" },
    "device": {
      "id": "<deviceId>",
      "publicKey": "<base64url-public-key>",
      "signature": "<base64url-signature>",
      "signedAt": 1772060000000,
      "nonce": "abc123"
    }
  }
}
```

### Step 5: Receive hello-ok

```json
{
  "type": "res",
  "id": "c1",
  "ok": true,
  "payload": {
    "type": "hello-ok",
    "protocol": 3,
    "auth": {
      "deviceToken": "<persist-this-for-future-connects>",
      "role": "operator",
      "scopes": ["operator.read", "operator.write"]
    },
    "features": { "methods": [...], "events": [...] },
    "policy": { "tickIntervalMs": 15000 }
  }
}
```

**Important**: Save the `deviceToken` — use it as `auth.token` on future connects (instead of the gateway master token).

### Step 6: First-time pairing (remote connections only)

If you get error code `PAIRING_REQUIRED`, the user needs to approve the device on the server:
```bash
openclaw devices list
openclaw devices approve <requestId>
```

Local connections (127.0.0.1) are auto-approved.

## Chat Methods

### Get agent list

```json
{ "type": "req", "id": "a1", "method": "agents.list", "params": {} }
```

Response:
```json
{
  "agents": [
    { "id": "main", "... ": "..." }
  ],
  "defaultId": "main"
}
```

### Get agent identity (name, emoji, avatar)

```json
{ "type": "req", "id": "ai1", "method": "agent.identity.get", "params": { "agentId": "main" } }
```

### Load chat history

```json
{ "type": "req", "id": "h1", "method": "chat.history", "params": { "limit": 50 } }
```

Response payload has `messages` array with `{ role, content, timestamp }` entries.

### Send a message

```json
{
  "type": "req",
  "id": "s1",
  "method": "chat.send",
  "params": {
    "message": "Hello!",
    "deliver": false,
    "idempotencyKey": "<unique-uuid>"
  }
}
```

**`chat.send` is non-blocking.** It immediately acks with:
```json
{ "type": "res", "id": "s1", "ok": true, "payload": { "runId": "...", "status": "started" } }
```

The actual response streams back via `chat` events.

### Receive streaming response (chat events)

After sending, you'll receive `chat` events:

```json
{
  "type": "event",
  "event": "chat",
  "payload": {
    "sessionKey": "agent:main:main",
    "runId": "...",
    "state": "delta",
    "message": { "role": "assistant", "content": [{ "type": "text", "text": "Hello, how are" }] }
  }
}
```

States:
- `"delta"` — partial response, accumulating text. Update the UI with the latest text.
- `"final"` — complete response. Add to message list, clear streaming state.
- `"aborted"` — user cancelled. May include partial text.
- `"error"` — something went wrong. `errorMessage` field has details.

**For the typing effect**: on each `delta`, extract the text from `message.content[0].text` and display it. Each delta contains the FULL text so far (not just the new chunk).

### Abort a response

```json
{ "type": "req", "id": "ab1", "method": "chat.abort", "params": { "sessionKey": "agent:main:main" } }
```

## Keepalive

The server sends `tick` events periodically (every ~15s). No response needed, but if you don't receive one for 2x the interval, assume disconnection and reconnect.

## Reconnection

On disconnect:
- Backoff: start at 800ms, multiply by 1.7, cap at 15s
- On successful reconnect, re-fetch `chat.history` to sync state

## Valid Client IDs

Must be one of these exact strings:
- `"openclaw-ios"` ← use this for Claudio
- `"openclaw-macos"`
- `"openclaw-android"`
- `"webchat-ui"`
- `"openclaw-control-ui"`
- `"cli"`

## Valid Client Modes

- `"ui"` ← use this for Claudio
- `"webchat"`
- `"cli"`
- `"backend"`
- `"node"`

## Summary

1. Connect WebSocket
2. Wait for `connect.challenge` event
3. Sign challenge with Ed25519 device key
4. Send `connect` request
5. On `hello-ok`: save device token, fetch `chat.history`, call `agents.list`
6. Send messages with `chat.send` (non-blocking)
7. Receive responses via `chat` events (delta → final)
8. Display delta text for live typing effect
