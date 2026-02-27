package rpc

import (
	"encoding/json"
	"log/slog"
	"time"

	"github.com/nicebartender/claudio-server/db"
	"github.com/nicebartender/claudio-server/joincode"
	"github.com/nicebartender/claudio-server/ws"
)

func (r *Router) handleRoomsList(client *ws.Client, req ws.RPCRequest) {
	rooms, err := r.DB.ListRoomsForUser(client.UserID())
	if err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
		return
	}
	if rooms == nil {
		rooms = []db.Room{}
	}
	client.SendJSON(ws.NewResponse(req.ID, map[string]interface{}{
		"rooms": rooms,
	}))
}

func (r *Router) handleRoomsCreate(client *ws.Client, req ws.RPCRequest) {
	name := jsonString(req.Params["name"])
	emoji := jsonString(req.Params["emoji"])

	if name == "" {
		client.SendJSON(ws.NewErrorResponse(req.ID, "INVALID_PARAMS", "name is required"))
		return
	}

	room, err := r.DB.CreateRoom(name, emoji, client.UserID())
	if err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
		return
	}

	// Create initial invite code
	dur := 7 * 24 * time.Hour
	invite, err := r.DB.CreateInvite(room.ID, client.UserID(), &dur, 0)
	if err != nil {
		slog.Error("create invite failed", "err", err)
	}

	// Subscribe creator to room events
	r.Hub.SubscribeRoom(room.ID, client)

	resp := map[string]interface{}{
		"room": room,
	}
	if invite != nil {
		resp["inviteCode"] = invite.Code
		if r.ExternalURL != "" {
			resp["universalCode"] = joincode.Encode(r.ExternalURL, invite.Code)
		}
	}
	client.SendJSON(ws.NewResponse(req.ID, resp))
}

func (r *Router) handleRoomsJoin(client *ws.Client, req ws.RPCRequest) {
	code := jsonString(req.Params["inviteCode"])
	if code == "" {
		client.SendJSON(ws.NewErrorResponse(req.ID, "INVALID_PARAMS", "inviteCode is required"))
		return
	}

	roomID, err := r.DB.RedeemInvite(code)
	if err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "INVALID_INVITE", err.Error()))
		return
	}

	// Check if already a participant
	already, _ := r.DB.IsParticipant(roomID, client.UserID())
	if !already {
		if err := r.DB.AddParticipant(roomID, client.UserID(), "member"); err != nil {
			client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
			return
		}

		// Broadcast join event
		user, _ := r.DB.GetUser(client.UserID())
		if user != nil {
			r.Hub.BroadcastToRoom(roomID, ws.NewEvent("room.join", map[string]interface{}{
				"roomId":      roomID,
				"displayName": user.DisplayName,
				"emoji":       user.AvatarEmoji,
				"userId":      user.ID,
			}), nil)
		}
	}

	// Subscribe to room events
	r.Hub.SubscribeRoom(roomID, client)

	room, err := r.DB.GetRoom(roomID)
	if err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
		return
	}

	client.SendJSON(ws.NewResponse(req.ID, map[string]interface{}{
		"room": room,
	}))
}

func (r *Router) handleRoomsLeave(client *ws.Client, req ws.RPCRequest) {
	roomID := jsonString(req.Params["roomId"])
	if roomID == "" {
		client.SendJSON(ws.NewErrorResponse(req.ID, "INVALID_PARAMS", "roomId is required"))
		return
	}

	if err := r.DB.RemoveParticipant(roomID, client.UserID()); err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
		return
	}

	r.Hub.UnsubscribeRoom(roomID, client)

	// Broadcast leave event
	user, _ := r.DB.GetUser(client.UserID())
	if user != nil {
		r.Hub.BroadcastToRoom(roomID, ws.NewEvent("room.leave", map[string]interface{}{
			"roomId":      roomID,
			"displayName": user.DisplayName,
			"userId":      user.ID,
		}), nil)
	}

	client.SendJSON(ws.NewResponse(req.ID, map[string]interface{}{
		"ok": true,
	}))
}

func (r *Router) handleRoomsInfo(client *ws.Client, req ws.RPCRequest) {
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

	room, err := r.DB.GetRoom(roomID)
	if err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
		return
	}

	// Annotate online status
	for i, p := range room.Participants {
		if !p.IsAgent {
			room.Participants[i].IsOnline = r.Hub.IsUserOnline(p.ID)
		}
	}

	client.SendJSON(ws.NewResponse(req.ID, map[string]interface{}{
		"room": room,
	}))
}

func (r *Router) handleRoomsAddAgent(client *ws.Client, req ws.RPCRequest) {
	roomID := jsonString(req.Params["roomId"])
	openclawURL := jsonString(req.Params["openclawUrl"])
	openclawToken := jsonString(req.Params["openclawToken"])
	agentID := jsonString(req.Params["agentId"])
	agentName := jsonString(req.Params["agentName"])
	agentEmoji := jsonString(req.Params["agentEmoji"])

	if roomID == "" || openclawURL == "" || agentID == "" {
		client.SendJSON(ws.NewErrorResponse(req.ID, "INVALID_PARAMS", "roomId, openclawUrl, and agentId are required"))
		return
	}

	// Verify participant with admin+ role
	role, err := r.DB.GetParticipantRole(roomID, client.UserID())
	if err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "FORBIDDEN", "Not a participant"))
		return
	}
	if role != "owner" && role != "admin" {
		client.SendJSON(ws.NewErrorResponse(req.ID, "FORBIDDEN", "Only owners and admins can add agents"))
		return
	}

	if agentName == "" {
		agentName = agentID
	}

	if err := r.DB.AddAgentParticipant(roomID, agentID, openclawURL, openclawToken, agentName, agentEmoji); err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
		return
	}

	participant, _ := r.DB.GetAgentParticipant(roomID, agentID, openclawURL)

	// Broadcast join
	r.Hub.BroadcastToRoom(roomID, ws.NewEvent("room.join", map[string]interface{}{
		"roomId":      roomID,
		"displayName": agentName,
		"emoji":       agentEmoji,
		"isAgent":     true,
	}), nil)

	client.SendJSON(ws.NewResponse(req.ID, map[string]interface{}{
		"participant": participant,
	}))
}

func (r *Router) handleRoomsRemoveAgent(client *ws.Client, req ws.RPCRequest) {
	roomID := jsonString(req.Params["roomId"])
	agentID := jsonString(req.Params["agentId"])
	openclawURL := jsonString(req.Params["openclawUrl"])

	if roomID == "" || agentID == "" || openclawURL == "" {
		client.SendJSON(ws.NewErrorResponse(req.ID, "INVALID_PARAMS", "roomId, agentId, and openclawUrl are required"))
		return
	}

	if err := r.DB.RemoveAgentParticipant(roomID, agentID, openclawURL); err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
		return
	}

	client.SendJSON(ws.NewResponse(req.ID, map[string]interface{}{
		"ok": true,
	}))
}

func (r *Router) handleRoomsCreateInvite(client *ws.Client, req ws.RPCRequest) {
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

	maxUses := jsonInt(req.Params["maxUses"])
	var expiresIn *time.Duration
	if seconds := jsonInt(req.Params["expiresIn"]); seconds > 0 {
		d := time.Duration(seconds) * time.Second
		expiresIn = &d
	} else {
		d := 7 * 24 * time.Hour
		expiresIn = &d
	}

	invite, err := r.DB.CreateInvite(roomID, client.UserID(), expiresIn, maxUses)
	if err != nil {
		client.SendJSON(ws.NewErrorResponse(req.ID, "DB_ERROR", err.Error()))
		return
	}

	resp := map[string]interface{}{
		"code":      invite.Code,
		"expiresAt": invite.ExpiresAt,
	}
	if r.ExternalURL != "" {
		resp["universalCode"] = joincode.Encode(r.ExternalURL, invite.Code)
	}
	client.SendJSON(ws.NewResponse(req.ID, resp))
}

// helpers

func jsonString(raw json.RawMessage) string {
	var s string
	if raw != nil {
		json.Unmarshal(raw, &s)
	}
	return s
}

func jsonInt(raw json.RawMessage) int {
	var i int
	if raw != nil {
		json.Unmarshal(raw, &i)
	}
	return i
}
