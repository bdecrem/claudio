package rpc

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"

	"github.com/nicebartender/claudio-server/db"
	"github.com/nicebartender/claudio-server/ws"
)

// dispatchAgentMentions checks for @mentions of agents in a message and dispatches to OpenClaw
func (r *Router) dispatchAgentMentions(roomID string, msg *db.Message) {
	if msg.SenderUserID == nil {
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

		mention := "@" + strings.ToLower(p.DisplayName)
		if !strings.Contains(strings.ToLower(msg.Content), mention) {
			continue
		}

		slog.Info("agent mentioned", "agent", p.DisplayName, "agentId", p.AgentID, "roomId", roomID)

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

	sessionKey := "agent:" + agent.AgentID + ":main"

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
	// Just send the last message as the prompt — the agent's session
	// on OpenClaw doesn't share our room history, so we provide context.
	last := messages[len(messages)-1]
	return last.Content
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
