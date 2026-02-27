package rpc

import (
	"crypto/rand"
	"encoding/hex"
	"time"

	"github.com/nicebartender/claudio-server/db"
	"github.com/nicebartender/claudio-server/ws"
)

func (r *Router) handleRoomsSend(client *ws.Client, req ws.RPCRequest) {
	roomID := jsonString(req.Params["roomId"])
	content := jsonString(req.Params["content"])

	if roomID == "" || content == "" {
		client.SendJSON(ws.NewErrorResponse(req.ID, "INVALID_PARAMS", "roomId and content are required"))
		return
	}

	// Verify participant
	ok, _ := r.DB.IsParticipant(roomID, client.UserID())
	if !ok {
		client.SendJSON(ws.NewErrorResponse(req.ID, "FORBIDDEN", "Not a participant"))
		return
	}

	// Get sender info
	user, _ := r.DB.GetUser(client.UserID())
	senderName := client.DisplayName()
	senderEmoji := ""
	if user != nil {
		if user.DisplayName != "" {
			senderName = user.DisplayName
		}
		senderEmoji = user.AvatarEmoji
	}

	// Parse mentions
	mentions := "[]"
	if raw, ok := req.Params["mentions"]; ok {
		mentions = string(raw)
	}

	// Parse replyTo
	var replyTo *string
	if rt := jsonString(req.Params["replyTo"]); rt != "" {
		replyTo = &rt
	}

	userID := client.UserID()
	msgID := generateMsgID()
	msg, err := r.DB.InsertMessage(msgID, roomID, &userID, nil, senderName, senderEmoji, content, mentions, replyTo)
	if err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
		return
	}

	// Broadcast to room
	r.Hub.BroadcastToRoom(roomID, ws.NewEvent("room.message", map[string]interface{}{
		"roomId":  roomID,
		"message": msg,
	}), nil)

	client.SendJSON(ws.NewResponse(req.ID, map[string]interface{}{
		"messageId": msg.ID,
	}))

	// Check for @mentions of agents and dispatch
	r.dispatchAgentMentions(roomID, msg)
}

func (r *Router) handleRoomsHistory(client *ws.Client, req ws.RPCRequest) {
	roomID := jsonString(req.Params["roomId"])
	if roomID == "" {
		client.SendJSON(ws.NewErrorResponse(req.ID, "INVALID_PARAMS", "roomId is required"))
		return
	}

	// Verify participant
	ok, _ := r.DB.IsParticipant(roomID, client.UserID())
	if !ok {
		client.SendJSON(ws.NewErrorResponse(req.ID, "FORBIDDEN", "Not a participant"))
		return
	}

	limit := jsonInt(req.Params["limit"])
	if limit <= 0 {
		limit = 50
	}

	var before *time.Time
	if bs := jsonString(req.Params["before"]); bs != "" {
		if t, err := time.Parse(time.RFC3339, bs); err == nil {
			before = &t
		}
	}

	messages, err := r.DB.GetMessages(roomID, before, limit)
	if err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
		return
	}
	if messages == nil {
		messages = []db.Message{}
	}

	client.SendJSON(ws.NewResponse(req.ID, map[string]interface{}{
		"messages": messages,
	}))
}

func (r *Router) handleUserUpdate(client *ws.Client, req ws.RPCRequest) {
	displayName := jsonString(req.Params["displayName"])
	avatarEmoji := jsonString(req.Params["avatarEmoji"])

	if err := r.DB.UpdateUser(client.UserID(), displayName, avatarEmoji); err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
		return
	}

	client.SendJSON(ws.NewResponse(req.ID, map[string]interface{}{
		"ok": true,
	}))
}

func generateMsgID() string {
	b := make([]byte, 10)
	rand.Read(b)
	return hex.EncodeToString(b)[:16]
}
