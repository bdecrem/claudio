package rpc

import (
	"log/slog"

	"github.com/nicebartender/claudio-server/db"
	"github.com/nicebartender/claudio-server/ws"
)

type Router struct {
	Hub *ws.Hub
	DB  *db.DB
}

func NewRouter(hub *ws.Hub, database *db.DB) *Router {
	r := &Router{Hub: hub, DB: database}
	hub.RPCRouter = r.Handle
	return r
}

func (r *Router) Handle(client *ws.Client, req ws.RPCRequest) {
	slog.Info("RPC", "method", req.Method, "userID", client.UserID())

	switch req.Method {
	case "rooms.list":
		r.handleRoomsList(client, req)
	case "rooms.create":
		r.handleRoomsCreate(client, req)
	case "rooms.join":
		r.handleRoomsJoin(client, req)
	case "rooms.leave":
		r.handleRoomsLeave(client, req)
	case "rooms.info":
		r.handleRoomsInfo(client, req)
	case "rooms.history":
		r.handleRoomsHistory(client, req)
	case "rooms.send":
		r.handleRoomsSend(client, req)
	case "rooms.addAgent":
		r.handleRoomsAddAgent(client, req)
	case "rooms.removeAgent":
		r.handleRoomsRemoveAgent(client, req)
	case "rooms.createInvite":
		r.handleRoomsCreateInvite(client, req)
	case "user.update":
		r.handleUserUpdate(client, req)
	default:
		client.SendJSON(ws.NewErrorResponse(req.ID, "UNKNOWN_METHOD", "Unknown method: "+req.Method))
	}
}
