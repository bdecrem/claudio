package ws

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"github.com/nicebartender/claudio-server/db"
)

type Hub struct {
	clients    map[*Client]bool
	register   chan *Client
	unregister chan *Client

	// Room subscriptions: roomID -> set of clients
	roomSubs map[string]map[*Client]bool
	mu       sync.RWMutex

	DB        *db.DB
	RPCRouter func(client *Client, req RPCRequest)
}

func NewHub(database *db.DB) *Hub {
	return &Hub{
		clients:    make(map[*Client]bool),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		roomSubs:   make(map[string]map[*Client]bool),
		DB:         database,
	}
}

func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			h.clients[client] = true
			// Send challenge
			nonce := generateNonce()
			client.challengeNonce = nonce
			client.SendJSON(NewEvent("connect.challenge", map[string]string{
				"nonce": nonce,
			}))
			slog.Info("client connected, challenge sent")

		case client := <-h.unregister:
			if _, ok := h.clients[client]; ok {
				delete(h.clients, client)
				close(client.done)
				close(client.send)
				h.removeFromAllRooms(client)
				slog.Info("client unregistered", "userID", client.UserID())
			}
		}
	}
}

func (h *Hub) Register(client *Client) {
	h.register <- client
}

func (h *Hub) SubscribeRoom(roomID string, client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.roomSubs[roomID] == nil {
		h.roomSubs[roomID] = make(map[*Client]bool)
	}
	h.roomSubs[roomID][client] = true
}

func (h *Hub) UnsubscribeRoom(roomID string, client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if subs, ok := h.roomSubs[roomID]; ok {
		delete(subs, client)
		if len(subs) == 0 {
			delete(h.roomSubs, roomID)
		}
	}
}

func (h *Hub) BroadcastToRoom(roomID string, event RPCEvent, exclude *Client) {
	h.mu.RLock()
	subs := h.roomSubs[roomID]
	h.mu.RUnlock()

	for client := range subs {
		if client != exclude {
			client.SendJSON(event)
		}
	}
}

func (h *Hub) removeFromAllRooms(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for roomID, subs := range h.roomSubs {
		delete(subs, client)
		if len(subs) == 0 {
			delete(h.roomSubs, roomID)
		}
	}
}

// IsUserOnline checks if a user has any connected client
func (h *Hub) IsUserOnline(userID string) bool {
	for client := range h.clients {
		if client.UserID() == userID {
			return true
		}
	}
	return false
}

func (h *Hub) handleMessage(client *Client, data []byte) {
	var msg RPCMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		slog.Warn("invalid message", "err", err)
		return
	}

	switch msg.Type {
	case "req":
		// Handle connect specially (before auth check)
		if msg.Method == "connect" {
			h.handleConnect(client, msg)
			return
		}

		// All other methods require auth
		if !client.IsAuthenticated() {
			client.SendJSON(NewErrorResponse(msg.ID, "AUTH_REQUIRED", "Not authenticated"))
			return
		}

		// Parse params into map
		var params map[string]json.RawMessage
		if msg.Params != nil {
			json.Unmarshal(msg.Params, &params)
		}
		if params == nil {
			params = make(map[string]json.RawMessage)
		}

		req := RPCRequest{ID: msg.ID, Method: msg.Method, Params: params}
		if h.RPCRouter != nil {
			h.RPCRouter(client, req)
		}

	default:
		slog.Warn("unknown message type", "type", msg.Type)
	}
}

func (h *Hub) handleConnect(client *Client, msg RPCMessage) {
	userID, displayName, err := VerifyConnect(msg.Params, client.challengeNonce)
	if err != nil {
		slog.Warn("auth failed", "err", err)
		client.SendJSON(NewErrorResponse(msg.ID, "AUTH_FAILED", err.Error()))
		return
	}

	// Upsert user in DB
	_, err = h.DB.UpsertUser(userID, "", displayName, "")
	if err != nil {
		slog.Error("upsert user failed", "err", err)
	}

	client.SetAuth(userID, displayName)

	// Subscribe to all rooms this user is in
	rooms, _ := h.DB.ListRoomsForUser(userID)
	for _, room := range rooms {
		h.SubscribeRoom(room.ID, client)
	}

	client.SendJSON(RPCResponse{
		Type: "res",
		ID:   msg.ID,
		OK:   true,
		Payload: map[string]interface{}{
			"protocol": 3,
			"policy": map[string]interface{}{
				"tickIntervalMs": 15000,
			},
		},
	})

	slog.Info("client authenticated", "userID", userID, "displayName", displayName)

	// Start tick loop for this client
	go h.tickLoop(client)
}

func (h *Hub) tickLoop(client *Client) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-client.done:
			return
		case <-ticker.C:
			if !client.IsAuthenticated() {
				return
			}
			select {
			case client.send <- mustJSON(NewEvent("tick", nil)):
			case <-client.done:
				return
			default:
				return
			}
		}
	}
}

func mustJSON(v interface{}) []byte {
	data, _ := json.Marshal(v)
	return data
}

func generateNonce() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}
