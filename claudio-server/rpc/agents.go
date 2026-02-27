package rpc

import (
	"encoding/json"
	"log/slog"
	"strings"

	"github.com/nicebartender/claudio-server/db"
	"github.com/nicebartender/claudio-server/ws"
)

// dispatchAgentMentions checks for @mentions of agents in a message and dispatches to OpenClaw
func (r *Router) dispatchAgentMentions(roomID string, msg *db.Message) {
	// Only human messages trigger agents
	if msg.SenderUserID == nil {
		return
	}

	// Parse mentions from message content (look for @agentName patterns)
	participants, err := r.DB.GetParticipants(roomID)
	if err != nil {
		return
	}

	for _, p := range participants {
		if !p.IsAgent {
			continue
		}

		// Check if agent is mentioned (case-insensitive)
		mention := "@" + strings.ToLower(p.DisplayName)
		if !strings.Contains(strings.ToLower(msg.Content), mention) {
			continue
		}

		slog.Info("agent mentioned", "agent", p.DisplayName, "roomId", roomID)

		// TODO Phase 4: Dispatch to OpenClaw via connection pool
		// For now, just log the mention. The full agent integration
		// (connection pool, context building, streaming response relay)
		// will be implemented in Phase 4.

		// Placeholder: send a "typing" indicator
		r.Hub.BroadcastToRoom(roomID, ws.NewEvent("room.typing", map[string]interface{}{
			"roomId":      roomID,
			"displayName": p.DisplayName,
		}), nil)
	}
}

// ParseMentions extracts mentioned participant names from message content
func ParseMentions(content string, participants []db.Participant) []string {
	var mentioned []string
	lower := strings.ToLower(content)
	for _, p := range participants {
		mention := "@" + strings.ToLower(p.DisplayName)
		if strings.Contains(lower, mention) {
			mentioned = append(mentioned, p.ID)
		}
	}
	return mentioned
}

// MentionsJSON converts a list of mention IDs to JSON
func MentionsJSON(mentions []string) string {
	if len(mentions) == 0 {
		return "[]"
	}
	data, _ := json.Marshal(mentions)
	return string(data)
}
