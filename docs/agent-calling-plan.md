# Agent Calling: Incoming Calls from OpenClaw Agents

## Concept

OpenClaw agents can "call" their human via the Claudio app. The phone rings like a real phone call (lock screen, Do Not Disturb rules, green/red buttons) using Apple's CallKit framework. When answered, it opens a voice session using the existing Apple STT + server TTS pipeline.

## Architecture

```
Agent triggers call → OpenClaw sends signal → Claudio receives signal
→ CallKit shows incoming call UI → User answers → VoiceSessionView opens
```

## Phase 1: WebSocket Prototype

Skip push notification infrastructure. Use a persistent WebSocket connection from Claudio to OpenClaw to receive call signals. Gets to a working demo fast.

### OpenClaw Side

- **New WebSocket endpoint**: `ws://{server}/api/ws/calls` (or add to existing WS if one exists)
- **Call signal payload**:
  ```json
  {
    "type": "call",
    "agent": "mave",
    "reason": "Your 2pm meeting is in 15 minutes",
    "call_id": "uuid"
  }
  ```
- **Decline callback**: `POST /api/calls/{call_id}/decline` so the agent knows the user rejected
- **New agent action**: Agents can trigger a call via their existing action system

### Claudio Side

- **WebSocket client**: Maintains connection to `/api/ws/calls`, reconnects on drop
- **CallKit integration** (`CXProvider` + `CXCallController`):
  - Register as a calling app with provider configuration
  - `reportNewIncomingCall()` when WebSocket receives a call signal
  - Handle answer → open `VoiceSessionView` with agent context
  - Handle decline → notify OpenClaw via decline callback
  - Handle end call → tear down voice session
- **Audio session management**: CallKit has specific requirements around `AVAudioSession` categories — must configure correctly for voice
- **Key abstraction**: `handleIncomingCall(agentId:reason:callId:)` method that both WebSocket (now) and PushKit (later) can call. Everything downstream of "we know there's an incoming call" goes through this single entry point.

### Limitations of Phase 1

- Won't wake a killed app (WebSocket dies when app is terminated)
- Battery impact from persistent connection
- Only works while app is in foreground or recently backgrounded

## Phase 2: PushKit VoIP Integration

Layer real push notifications on top of Phase 1. The CallKit work carries over entirely.

### OpenClaw Side (New Work)

- **Device registration endpoint**: `POST /api/devices/register` — receives and stores VoIP push tokens
- **APNs integration**: Server-side Apple Push Notification service (certificate or key-based auth) to send VoIP pushes
- **Call trigger updated**: Instead of (or in addition to) WebSocket, send a VoIP push with the call payload

### Claudio Side (New Work)

- **PushKit delegate** (`PKPushRegistryDelegate`): ~50 lines to receive push token and incoming push payloads
- **Token registration**: Send VoIP push token to OpenClaw on app launch
- **Swap trigger**: PushKit delegate calls the same `handleIncomingCall(agentId:reason:callId:)` method
- **WebSocket**: Keep as fallback for foreground use, or remove

### What This Enables

- Phone rings even when app is killed
- Works with Do Not Disturb rules
- Native lock screen call UI
- No battery drain from persistent connections

### Apple's PushKit Rule

If you use PushKit VoIP pushes, you **must** report a call to CallKit immediately upon receiving the push. If you don't, iOS will terminate your app and may revoke your push privileges.

## What's NOT Needed (Either Phase)

- No WebRTC, SIP, or Twilio
- No carrier integration
- No changes to the existing voice pipeline (Apple Speech STT + server `/api/tts/`)
- No new voice infrastructure — the call IS a voice session

## Effort Split

| Area | Phase 1 | Phase 2 |
|------|---------|---------|
| OpenClaw | WebSocket endpoint + call trigger + decline callback | Device registration + APNs integration |
| Claudio | CallKit + audio session + WebSocket client + VoiceSession wiring | PushKit delegate + token registration |
| **Throwaway** | | WebSocket call listener only (~thin layer) |

## Key Design Decision

Extract `handleIncomingCall(agentId:reason:callId:)` as the single entry point from day one. This makes the Phase 1 → Phase 2 migration a matter of plugging PushKit into the same handler. All CallKit, audio session, and VoiceSessionView work is permanent.
