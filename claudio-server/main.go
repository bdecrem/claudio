package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	"github.com/nicebartender/claudio-server/apns"
	"github.com/nicebartender/claudio-server/db"
	"github.com/nicebartender/claudio-server/joincode"
	"github.com/nicebartender/claudio-server/relay"
	"github.com/nicebartender/claudio-server/rpc"
	"github.com/nicebartender/claudio-server/ws"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	cfg := LoadConfig()

	database, err := db.Open(cfg.DBPath)
	if err != nil {
		slog.Error("failed to open database", "err", err)
		os.Exit(1)
	}
	defer database.Close()



	if err := database.EnsureLobby(); err != nil {
		slog.Error("failed to create lobby room", "err", err)
	}

	if cfg.LobbyAgent.OpenclawURL != "" {
		if err := database.EnsureLobbyAgent(
			cfg.LobbyAgent.AgentID,
			cfg.LobbyAgent.OpenclawURL,
			cfg.LobbyAgent.OpenclawToken,
			cfg.LobbyAgent.OpenclawAgentID,
			cfg.LobbyAgent.AgentName,
			cfg.LobbyAgent.AgentEmoji,
		); err != nil {
			slog.Error("failed to add lobby agent", "err", err)
		} else {
			slog.Info("lobby agent ensured", "agent", cfg.LobbyAgent.AgentID)
		}
	}

	hub := ws.NewHub(database)
	keyDir := filepath.Dir(cfg.DBPath)
	router := rpc.NewRouter(hub, database, keyDir)
	router.ExternalURL = cfg.ExternalURL

	go hub.Run()

	// Initialize APNs client (optional — server works without it)
	var apnsClient *apns.Client
	if cfg.APNS.KeyID != "" {
		apnsClient, err = apns.NewClient(cfg.APNS)
		if err != nil {
			slog.Error("failed to init APNs client", "err", err)
		} else {
			slog.Info("APNs client initialized", "keyID", cfg.APNS.KeyID, "sandbox", cfg.APNS.Sandbox)
		}
	} else {
		slog.Info("APNs not configured, push notifications disabled")
	}

	// Initialize relay manager for DM push notifications
	relayMgr := relay.NewManager(database, apnsClient)
	relayMgr.LoadAll()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			slog.Error("upgrade failed", "err", err)
			return
		}
		client := ws.NewClient(hub, conn)
		hub.Register(client)
		go client.WritePump()
		go client.ReadPump()
	})

	// Health check
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	// Invite preview — decodes universal code, validates invite, returns room info
	http.HandleFunc("/invite/", func(w http.ResponseWriter, r *http.Request) {
		code := strings.TrimPrefix(r.URL.Path, "/invite/")
		if code == "" {
			http.Error(w, `{"error":"missing code"}`, http.StatusBadRequest)
			return
		}

		_, inviteCode, err := joincode.Decode(code)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]string{"error": "invalid code: " + err.Error()})
			return
		}

		invite, err := database.LookupInvite(inviteCode)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}

		room, err := database.GetRoom(invite.RoomID)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": "room not found"})
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"serverURL":  "https://" + cfg.ExternalURL,
			"inviteCode": inviteCode,
			"roomName":   room.Name,
			"roomEmoji":  room.Emoji,
		})
	})

	// Push: register device token (+ optional OpenClaw relay info)
	http.HandleFunc("/push/register", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
			return
		}

		var req struct {
			DeviceID     string `json:"deviceId"`
			Token        string `json:"token"`
			BundleID     string `json:"bundleId"`
			OpenclawURL  string `json:"openclawURL"`
			OpenclawToken string `json:"openclawToken"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]string{"error": "invalid JSON"})
			return
		}

		if req.DeviceID == "" || req.Token == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]string{"error": "deviceId and token are required"})
			return
		}

		bundleID := req.BundleID
		if bundleID == "" {
			bundleID = "com.kochito.claudio"
		}

		if err := database.UpsertPushToken(req.DeviceID, req.Token, bundleID, "ios"); err != nil {
			slog.Error("failed to upsert push token", "err", err)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": "internal error"})
			return
		}

		// If OpenClaw info provided, start relay connection for DM push
		if req.OpenclawURL != "" && req.OpenclawToken != "" {
			if err := database.UpsertWatch(req.DeviceID, req.OpenclawURL, req.OpenclawToken); err != nil {
				slog.Error("failed to upsert watch", "err", err)
			} else {
				relayMgr.Start(req.DeviceID, req.OpenclawURL, req.OpenclawToken)
			}
		}

		slog.Info("push token registered", "deviceId", req.DeviceID[:min(8, len(req.DeviceID))]+"...", "bundleId", bundleID, "relay", req.OpenclawURL != "")
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	})

	// Push: unregister — stop relay and remove watch
	http.HandleFunc("/push/unregister", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete && r.Method != http.MethodPost {
			http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
			return
		}

		var req struct {
			DeviceID string `json:"deviceId"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.DeviceID == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]string{"error": "deviceId is required"})
			return
		}

		relayMgr.Stop(req.DeviceID)
		_ = database.DeleteWatch(req.DeviceID)

		slog.Info("push unregistered", "deviceId", req.DeviceID[:min(8, len(req.DeviceID))]+"...")
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	})

	// Push: send notification (called by OpenClaw servers)
	http.HandleFunc("/push/send", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
			return
		}

		// Auth check
		if cfg.PushSecret != "" {
			auth := r.Header.Get("Authorization")
			if !strings.HasPrefix(auth, "Bearer ") || strings.TrimPrefix(auth, "Bearer ") != cfg.PushSecret {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusUnauthorized)
				json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"})
				return
			}
		}

		if apnsClient == nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			json.NewEncoder(w).Encode(map[string]string{"error": "APNs not configured"})
			return
		}

		var req struct {
			DeviceID string            `json:"deviceId"`
			Alert    apns.Alert        `json:"alert"`
			Data     map[string]string `json:"data"`
			ThreadID string            `json:"threadId"`
			BundleID string            `json:"bundleId"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]string{"error": "invalid JSON"})
			return
		}

		if req.DeviceID == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]string{"error": "deviceId is required"})
			return
		}

		bundleID := req.BundleID
		if bundleID == "" {
			bundleID = "com.kochito.claudio"
		}

		token, err := database.GetPushToken(req.DeviceID, bundleID)
		if err != nil {
			slog.Warn("push token not found", "deviceId", req.DeviceID[:min(8, len(req.DeviceID))]+"...", "err", err)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			json.NewEncoder(w).Encode(map[string]string{"error": "device not registered"})
			return
		}

		payload := apns.Payload{
			Alert:    req.Alert,
			Sound:    "default",
			ThreadID: req.ThreadID,
			Data:     req.Data,
		}

		if err := apnsClient.Send(token, payload, bundleID); err != nil {
			slog.Error("failed to send push", "deviceId", req.DeviceID[:min(8, len(req.DeviceID))]+"...", "err", err)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			json.NewEncoder(w).Encode(map[string]string{"error": "push delivery failed"})
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	})

	// Push: debug — show stored token info for a device
	http.HandleFunc("/push/debug", func(w http.ResponseWriter, r *http.Request) {
		deviceID := r.URL.Query().Get("deviceId")
		if deviceID == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]string{"error": "deviceId query param required"})
			return
		}

		token, bundleID, platform, updatedAt, err := database.GetPushTokenDebug(deviceID)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			json.NewEncoder(w).Encode(map[string]string{"error": "not found"})
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"tokenPrefix": token[:min(16, len(token))] + "...",
			"tokenLength": fmt.Sprintf("%d", len(token)),
			"bundleId":    bundleID,
			"platform":    platform,
			"updatedAt":   updatedAt,
			"sandbox":     fmt.Sprintf("%v", cfg.APNS.Sandbox),
		})
	})

	// Push: status — show active relay connections
	http.HandleFunc("/push/status", func(w http.ResponseWriter, r *http.Request) {
		statuses := relayMgr.Status()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"relays": statuses,
			"count":  len(statuses),
		})
	})

	// Push: test — send a test notification to a device
	http.HandleFunc("/push/test", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
			return
		}

		if apnsClient == nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			json.NewEncoder(w).Encode(map[string]string{"error": "APNs not configured"})
			return
		}

		var req struct {
			DeviceID string `json:"deviceId"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.DeviceID == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]string{"error": "deviceId is required"})
			return
		}

		bundleID := "com.kochito.claudio"
		token, err := database.GetPushToken(req.DeviceID, bundleID)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			json.NewEncoder(w).Encode(map[string]string{"error": "device not registered"})
			return
		}

		badge := 1
		payload := apns.Payload{
			Alert: apns.Alert{
				Title: "Test Notification",
				Body:  "Push notifications are working!",
			},
			Sound: "default",
			Badge: &badge,
			Data:  map[string]string{"test": "true"},
		}

		if err := apnsClient.Send(token, payload, bundleID); err != nil {
			slog.Error("test push failed", "err", err)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	})

	// Agent join — GET returns instructions for the agent, POST registers the agent
	http.HandleFunc("/agent-join/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusOK)
			return
		}

		code := strings.TrimPrefix(r.URL.Path, "/agent-join/")
		if code == "" {
			http.Error(w, "missing invite code", http.StatusBadRequest)
			return
		}

		invite, err := database.LookupInvite(strings.ToUpper(code))
		if err != nil {
			http.Error(w, "Invalid invite code: "+err.Error(), http.StatusNotFound)
			return
		}

		room, err := database.GetRoom(invite.RoomID)
		if err != nil {
			http.Error(w, "Room not found", http.StatusInternalServerError)
			return
		}

		if r.Method == http.MethodGet {
			// Return plain-text instructions the agent can follow
			w.Header().Set("Content-Type", "text/plain")
			fmt.Fprintf(w, `You are joining the Claudio chat room "%s" %s.

To complete joining, send an HTTP POST to:
  https://%s/agent-join/%s

With JSON body:
  {"openclawUrl": "<YOUR_OPENCLAW_URL>", "openclawToken": "<YOUR_TOKEN>", "agentId": "<YOUR_AGENT_ID>", "agentName": "<YOUR_DISPLAY_NAME>", "agentEmoji": "<EMOJI>"}

To find your OpenClaw URL and token, run this command:
  cat ~/.openclaw/openclaw.json

Look for gateway.port (default 18789) and gateway.auth.token.
Your public URL is typically your domain or tunnel URL (e.g. ngrok, tailscale).
Your agent ID is in agents.list[].id (or "default" if not configured).

Once registered, humans in the room can @mention you and you will receive and respond to messages.
`, room.Name, room.Emoji, cfg.ExternalURL, code)
			return
		}

		if r.Method == http.MethodPost {
			var req struct {
				OpenclawURL   string `json:"openclawUrl"`
				OpenclawToken string `json:"openclawToken"`
				AgentID       string `json:"agentId"`
				AgentName     string `json:"agentName"`
				AgentEmoji    string `json:"agentEmoji"`
			}
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadRequest)
				json.NewEncoder(w).Encode(map[string]string{"error": "invalid JSON"})
				return
			}

			if req.OpenclawURL == "" || req.AgentID == "" {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadRequest)
				json.NewEncoder(w).Encode(map[string]string{"error": "openclawUrl and agentId are required"})
				return
			}

			if req.AgentName == "" {
				req.AgentName = req.AgentID
			}

			// Verify we can actually connect to this OpenClaw server
			testClient, err := router.OpenClawPool.Get(req.OpenclawURL, req.OpenclawToken)
			if err != nil {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadGateway)
				json.NewEncoder(w).Encode(map[string]string{"error": "Could not connect to your OpenClaw server: " + err.Error()})
				return
			}
			_ = testClient

			// Add agent to room
			if err := database.AddAgentParticipant(room.ID, req.AgentID, req.OpenclawURL, req.OpenclawToken, req.AgentID, req.AgentName, req.AgentEmoji); err != nil {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusInternalServerError)
				json.NewEncoder(w).Encode(map[string]string{"error": "Failed to add agent: " + err.Error()})
				return
			}

			// Broadcast join event
			hub.BroadcastToRoom(room.ID, ws.NewEvent("room.join", map[string]interface{}{
				"roomId":      room.ID,
				"displayName": req.AgentName,
				"emoji":       req.AgentEmoji,
				"isAgent":     true,
			}), nil)

			slog.Info("agent joined via relay", "agent", req.AgentName, "room", room.Name, "openclawUrl", req.OpenclawURL)

			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]interface{}{
				"ok":       true,
				"roomName": room.Name,
				"roomId":   room.ID,
				"message":  fmt.Sprintf("You have joined room \"%s\". Humans in the room can now @mention you to chat.", room.Name),
			})
			return
		}

		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	})

	// Chat API — HTTP-based room access for agents (no WebSocket needed)
	// GET  /chat-api/{inviteCode}                  → room info + recent messages + instructions
	// POST /chat-api/{inviteCode}/send             → send a message
	// GET  /chat-api/{inviteCode}/messages?after=X  → poll for new messages
	http.HandleFunc("/chat-api/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusOK)
			return
		}

		// Parse path: /chat-api/{code} or /chat-api/{code}/send or /chat-api/{code}/messages
		path := strings.TrimPrefix(r.URL.Path, "/chat-api/")
		parts := strings.SplitN(path, "/", 2)
		code := parts[0]
		action := ""
		if len(parts) > 1 {
			action = parts[1]
		}

		if code == "" {
			http.Error(w, "missing invite code", http.StatusBadRequest)
			return
		}

		invite, err := database.LookupInvite(strings.ToUpper(code))
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			json.NewEncoder(w).Encode(map[string]string{"error": "Invalid invite code: " + err.Error()})
			return
		}
		roomID := invite.RoomID

		room, err := database.GetRoom(roomID)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": "room not found"})
			return
		}

		switch action {
		case "", "info":
			// GET — return room info, recent messages, and usage instructions
			if r.Method != http.MethodGet {
				http.Error(w, "use GET", http.StatusMethodNotAllowed)
				return
			}

			messages, _ := database.GetMessages(roomID, nil, 20)
			if messages == nil {
				messages = []db.Message{}
			}

			// Build participant list (names only, no secrets)
			var participantNames []map[string]interface{}
			for _, p := range room.Participants {
				participantNames = append(participantNames, map[string]interface{}{
					"name":    p.DisplayName,
					"emoji":   p.Emoji,
					"isAgent": p.IsAgent,
				})
			}

			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]interface{}{
				"room": map[string]interface{}{
					"name":         room.Name,
					"emoji":        room.Emoji,
					"participants": participantNames,
				},
				"messages": messages,
				"instructions": fmt.Sprintf(
					"You are in the chat room \"%s\" %s. "+
						"To send a message, POST to https://%s/chat-api/%s/send with JSON {\"name\": \"YourName\", \"emoji\": \"🤖\", \"content\": \"your message\"}. "+
						"To monitor the conversation in real time, run this command in the background: "+
						"curl -N https://%s/chat-api/%s/stream "+
						"This opens an SSE stream that pushes all room messages to you as they happen. "+
						"When you see a message that @mentions you, respond by POSTing to the send endpoint. "+
						"To check for new messages without streaming, GET https://%s/chat-api/%s/messages?after=LAST_MESSAGE_ID.",
					room.Name, room.Emoji,
					cfg.ExternalURL, code,
					cfg.ExternalURL, code,
					cfg.ExternalURL, code,
				),
			})

		case "send":
			// POST — agent sends a message to the room
			if r.Method != http.MethodPost {
				http.Error(w, "use POST", http.StatusMethodNotAllowed)
				return
			}

			var req struct {
				Name    string `json:"name"`
				Emoji   string `json:"emoji"`
				Content string `json:"content"`
			}
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadRequest)
				json.NewEncoder(w).Encode(map[string]string{"error": "invalid JSON"})
				return
			}
			if req.Content == "" || req.Name == "" {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadRequest)
				json.NewEncoder(w).Encode(map[string]string{"error": "name and content are required"})
				return
			}

			// Register as participant on first message (idempotent)
			agentID := "chatapi-" + req.Name
			err = database.AddAgentParticipant(roomID, agentID, "", "", "", req.Name, req.Emoji)
			if err == nil {
				// First time — broadcast join event
				hub.BroadcastToRoom(roomID, ws.NewEvent("room.join", map[string]interface{}{
					"roomId":      roomID,
					"displayName": req.Name,
					"emoji":       req.Emoji,
					"isAgent":     true,
				}), nil)
			}
			// err != nil means already exists (INSERT OR IGNORE), which is fine

			msgID := rpc.GenerateMsgID()
			senderAgentID := agentID
			msg, err := database.InsertMessage(msgID, roomID, nil, &senderAgentID, req.Name, req.Emoji, req.Content, "[]", nil)
			if err != nil {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusInternalServerError)
				json.NewEncoder(w).Encode(map[string]string{"error": "failed to send: " + err.Error()})
				return
			}

			// Broadcast to WebSocket clients in the room
			hub.BroadcastToRoom(roomID, ws.NewEvent("room.message", map[string]interface{}{
				"roomId":  roomID,
				"message": msg,
			}), nil)

			slog.Info("chat-api message", "from", req.Name, "room", room.Name, "len", len(req.Content))

			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]interface{}{
				"ok":        true,
				"messageId": msg.ID,
			})

		case "messages":
			// GET — poll for new messages after a given message ID
			if r.Method != http.MethodGet {
				http.Error(w, "use GET", http.StatusMethodNotAllowed)
				return
			}

			afterID := r.URL.Query().Get("after")
			var messages []db.Message
			if afterID != "" {
				messages, _ = database.GetMessagesAfter(roomID, afterID, 50)
			} else {
				messages, _ = database.GetMessages(roomID, nil, 20)
			}
			if messages == nil {
				messages = []db.Message{}
			}

			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]interface{}{
				"messages": messages,
			})

		case "stream":
			// GET — SSE stream of room events (messages, joins, typing)
			if r.Method != http.MethodGet {
				http.Error(w, "use GET", http.StatusMethodNotAllowed)
				return
			}

			flusher, ok := w.(http.Flusher)
			if !ok {
				http.Error(w, "streaming not supported", http.StatusInternalServerError)
				return
			}

			w.Header().Set("Content-Type", "text/event-stream")
			w.Header().Set("Cache-Control", "no-cache")
			w.Header().Set("Connection", "keep-alive")

			// Send initial room info + recent history as first event
			messages, _ := database.GetMessages(roomID, nil, 20)
			if messages == nil {
				messages = []db.Message{}
			}
			initData, _ := json.Marshal(map[string]interface{}{
				"type":     "init",
				"roomName": room.Name,
				"roomEmoji": room.Emoji,
				"messages": messages,
			})
			fmt.Fprintf(w, "data: %s\n\n", initData)
			flusher.Flush()

			// Subscribe to room events
			listener := &ws.RoomListener{
				RoomID: roomID,
				Ch:     make(chan []byte, 50),
			}
			hub.AddRoomListener(listener)
			defer hub.RemoveRoomListener(listener)

			slog.Info("SSE stream opened", "room", room.Name, "roomId", roomID)

			// Keep-alive ticker
			ticker := time.NewTicker(15 * time.Second)
			defer ticker.Stop()

			ctx := r.Context()
			for {
				select {
				case <-ctx.Done():
					slog.Info("SSE stream closed", "room", room.Name)
					return
				case data := <-listener.Ch:
					fmt.Fprintf(w, "data: %s\n\n", data)
					flusher.Flush()
				case <-ticker.C:
					fmt.Fprintf(w, ": keepalive\n\n")
					flusher.Flush()
				}
			}

		default:
			http.Error(w, "unknown action", http.StatusNotFound)
		}
	})

	slog.Info("claudio-server starting", "addr", cfg.ListenAddr)
	if err := http.ListenAndServe(cfg.ListenAddr, nil); err != nil {
		slog.Error("server failed", "err", err)
		os.Exit(1)
	}
}
