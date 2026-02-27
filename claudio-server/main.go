package main

import (
	"log/slog"
	"net/http"
	"os"

	"github.com/gorilla/websocket"
	"github.com/nicebartender/claudio-server/db"
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

	hub := ws.NewHub(database)
	_ = rpc.NewRouter(hub, database)

	go hub.Run()

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

	slog.Info("claudio-server starting", "addr", cfg.ListenAddr)
	if err := http.ListenAndServe(cfg.ListenAddr, nil); err != nil {
		slog.Error("server failed", "err", err)
		os.Exit(1)
	}
}
