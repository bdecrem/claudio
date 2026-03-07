package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"

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

	// One-time migration: clear stale push watches so devices re-register with new token
	if res, err := database.Exec("DELETE FROM push_watches"); err == nil {
		if n, _ := res.RowsAffected(); n > 0 {
			slog.Info("cleared stale push watches", "count", n)
		}
	}


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

	slog.Info("claudio-server starting", "addr", cfg.ListenAddr)
	if err := http.ListenAndServe(cfg.ListenAddr, nil); err != nil {
		slog.Error("server failed", "err", err)
		os.Exit(1)
	}
}
