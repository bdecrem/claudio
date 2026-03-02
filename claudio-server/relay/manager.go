package relay

import (
	"crypto/ed25519"
	"crypto/rand"
	"log/slog"
	"sync"

	"github.com/nicebartender/claudio-server/apns"
	"github.com/nicebartender/claudio-server/db"
)

// Manager manages persistent WebSocket connections to users' OpenClaw servers.
// When an agent sends a message, the relay triggers an APNs push notification.
type Manager struct {
	mu   sync.Mutex
	conns map[string]*Connection // deviceID → connection

	db         *db.DB
	apnsClient *apns.Client
	privateKey ed25519.PrivateKey
}

// NewManager creates a relay manager with a shared Ed25519 identity.
func NewManager(database *db.DB, apnsClient *apns.Client) *Manager {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	return &Manager{
		conns:      make(map[string]*Connection),
		db:         database,
		apnsClient: apnsClient,
		privateKey: priv,
	}
}

// LoadAll reconnects to all registered watches from the database.
func (m *Manager) LoadAll() {
	watches, err := m.db.ListWatches()
	if err != nil {
		slog.Error("relay: failed to load watches", "err", err)
		return
	}

	for _, w := range watches {
		m.Start(w.DeviceID, w.OpenclawURL, w.OpenclawToken)
	}

	slog.Info("relay: loaded watches", "count", len(watches))
}

// Start begins a relay connection for the given device.
// If a connection already exists for this device, it is stopped first.
func (m *Manager) Start(deviceID, openclawURL, openclawToken string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Stop existing connection if any
	if existing, ok := m.conns[deviceID]; ok {
		existing.stop()
		delete(m.conns, deviceID)
	}

	conn := newConnection(deviceID, openclawURL, openclawToken, m.privateKey, m.sendPush)
	m.conns[deviceID] = conn

	go conn.run()

	slog.Info("relay: started watch", "deviceId", deviceID[:min(8, len(deviceID))])
}

// Stop disconnects the relay for a given device.
func (m *Manager) Stop(deviceID string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if conn, ok := m.conns[deviceID]; ok {
		conn.stop()
		delete(m.conns, deviceID)
		slog.Info("relay: stopped watch", "deviceId", deviceID[:min(8, len(deviceID))])
	}
}

func (m *Manager) sendPush(deviceID, agentName string) {
	if m.apnsClient == nil {
		slog.Warn("relay: APNs not configured, skipping push")
		return
	}

	bundleID := "com.kochito.claudio"
	token, err := m.db.GetPushToken(deviceID, bundleID)
	if err != nil {
		slog.Warn("relay: no push token for device", "deviceId", deviceID[:min(8, len(deviceID))], "err", err)
		return
	}

	payload := apns.Payload{
		Alert: apns.Alert{
			Title: "New message",
			Body:  agentName + " sent a message",
		},
		Sound: "default",
		Data: map[string]string{
			"agentId": agentName,
		},
	}

	if err := m.apnsClient.Send(token, payload, bundleID); err != nil {
		slog.Error("relay: push send failed", "deviceId", deviceID[:min(8, len(deviceID))], "err", err)
	}
}
