package openclaw

// Dispatch handles sending messages to OpenClaw agents and relaying responses.
// Phase 4 will implement:
// - Building context (system message + recent room history)
// - Sending chat.send to the agent's OpenClaw server
// - Streaming response back as room.message events
// - Anti-loop protection (only human messages trigger agents)
// - Rate limiting (max 1 response per 30s per agent per room)
// - Circuit breaker (>10 agent messages in 5 min → pause)
