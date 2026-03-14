package rpc

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"

	"github.com/nicebartender/claudio-server/db"
	"github.com/nicebartender/claudio-server/ws"
)

// dispatchAgentResponses sends every human message to all agents in the room.
// Agents that are @mentioned respond immediately. All other agents also see the
// message so they can participate in the conversation naturally.
func (r *Router) dispatchAgentResponses(roomID string, msg *db.Message) {
	// Skip messages from agents (prevent loops)
	if msg.SenderAgentID != nil {
		return
	}

	participants, err := r.DB.GetParticipants(roomID)
	if err != nil {
		return
	}

	for _, p := range participants {
		if !p.IsAgent {
			continue
		}

		slog.Info("dispatching to agent", "agent", p.DisplayName, "agentId", p.AgentID, "roomId", roomID)

		r.Hub.BroadcastToRoom(roomID, ws.NewEvent("room.typing", map[string]interface{}{
			"roomId":      roomID,
			"displayName": p.DisplayName,
		}), nil)

		go r.callAgent(roomID, p)
	}
}

func (r *Router) callAgent(roomID string, agent db.Participant) {
	client, err := r.OpenClawPool.Get(agent.OpenclawURL, agent.OpenclawToken)
	if err != nil {
		slog.Error("callAgent: pool connect failed", "err", err, "url", agent.OpenclawURL)
		r.postAgentError(roomID, agent, fmt.Sprintf("Failed to connect: %s", err.Error()))
		return
	}

	// Use the OpenClaw agent ID if set, otherwise fall back to our agent ID
	ocAgentID := agent.OpenclawAgentID
	if ocAgentID == "" {
		ocAgentID = agent.AgentID
	}
	// Session key format: agent:{roomId}:{openclawAgentId}
	// This gives each room its own conversation thread on the OpenClaw side
	sessionKey := "agent:" + roomID + ":" + ocAgentID

	// Get recent history to include as context in the message
	messages, _ := r.DB.GetMessages(roomID, nil, 10)
	contextMsg := buildContextMessage(messages, agent.DisplayName)

	resp, err := client.ChatSend(sessionKey, contextMsg)
	if err != nil {
		slog.Error("callAgent: chat.send failed", "err", err, "agent", agent.DisplayName)
		r.postAgentError(roomID, agent, err.Error())
		return
	}

	if resp.Text != "" {
		r.postAgentMessage(roomID, agent, resp.Text)
	}
}

func buildContextMessage(messages []db.Message, agentName string) string {
	if len(messages) == 0 {
		return "Hello"
	}
	// Build context from recent messages so the agent knows who said what.
	// Messages come newest-first from DB, reverse for chronological order.
	var lines []string
	for i := len(messages) - 1; i >= 0; i-- {
		m := messages[i]
		name := m.SenderDisplayName
		lines = append(lines, fmt.Sprintf("[%s]: %s", name, m.Content))
	}
	return strings.Join(lines, "\n")
}

func (r *Router) postAgentMessage(roomID string, agent db.Participant, content string) {
	agentID := agent.AgentID
	msgID := generateMsgID()
	msg, err := r.DB.InsertMessage(msgID, roomID, nil, &agentID, agent.DisplayName, agent.Emoji, content, "[]", nil)
	if err != nil {
		slog.Error("postAgentMessage: insert failed", "err", err)
		return
	}

	r.Hub.BroadcastToRoom(roomID, ws.NewEvent("room.message", map[string]interface{}{
		"roomId":  roomID,
		"message": msg,
	}), nil)

	slog.Info("agent responded", "agent", agent.DisplayName, "roomId", roomID, "len", len(content))
}

func (r *Router) postAgentError(roomID string, agent db.Participant, errMsg string) {
	content := fmt.Sprintf("_%s encountered an error: %s_", agent.DisplayName, errMsg)
	r.postAgentMessage(roomID, agent, content)
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
