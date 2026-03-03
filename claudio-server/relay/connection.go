package relay

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// ConnectionStatus represents the current state of a relay connection.
type ConnectionStatus struct {
	DeviceID    string `json:"deviceId"`
	OpenclawURL string `json:"openclawURL"`
	Connected   bool   `json:"connected"`
	LastEvent   string `json:"lastEvent,omitempty"` // RFC3339
	LastError   string `json:"lastError,omitempty"`
}

// Connection manages a persistent WebSocket connection to a user's OpenClaw server.
// It listens for chat events and triggers push notifications.
type Connection struct {
	deviceID      string
	openclawURL   string
	openclawToken string

	conn   *websocket.Conn
	mu     sync.Mutex
	nextID atomic.Int64

	pending   map[string]chan json.RawMessage
	pendingMu sync.Mutex

	events chan wireMessage
	done   chan struct{}
	stopCh chan struct{}

	// Ed25519 identity shared across all relay connections
	privateKey ed25519.PrivateKey
	publicKey  ed25519.PublicKey
	relayDeviceID string

	// Callback to send APNs push
	onAgentMessage func(deviceID, agentName string)

	// Status tracking
	connected  atomic.Bool
	lastEvent  atomic.Value // time.Time
	lastError  atomic.Value // string
}

type wireMessage struct {
	Type    string          `json:"type"`
	ID      string          `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  interface{}     `json:"params,omitempty"`
	OK      bool            `json:"ok,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Error   *wireError      `json:"error,omitempty"`
	Event   string          `json:"event,omitempty"`
}

type wireError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func newConnection(deviceID, openclawURL, openclawToken string, privKey ed25519.PrivateKey, onMsg func(string, string)) *Connection {
	pubKey := privKey.Public().(ed25519.PublicKey)
	hash := sha256.Sum256(pubKey)
	relayDeviceID := hex.EncodeToString(hash[:])

	return &Connection{
		deviceID:       deviceID,
		openclawURL:    openclawURL,
		openclawToken:  openclawToken,
		pending:        make(map[string]chan json.RawMessage),
		events:         make(chan wireMessage, 100),
		done:           make(chan struct{}),
		stopCh:         make(chan struct{}),
		privateKey:     privKey,
		publicKey:      pubKey,
		relayDeviceID:  relayDeviceID,
		onAgentMessage: onMsg,
	}
}

// run connects to OpenClaw and listens for events. Reconnects with backoff on disconnect.
func (c *Connection) run() {
	backoff := time.Second
	maxBackoff := 5 * time.Minute

	for {
		select {
		case <-c.stopCh:
			return
		default:
		}

		err := c.connectAndListen()
		if err != nil {
			c.lastError.Store(err.Error())
			slog.Warn("relay connection failed", "deviceId", c.deviceID[:min(8, len(c.deviceID))], "err", err)
		}

		select {
		case <-c.stopCh:
			return
		case <-time.After(backoff):
		}

		backoff = backoff * 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

func (c *Connection) stop() {
	select {
	case <-c.stopCh:
	default:
		close(c.stopCh)
	}
	c.mu.Lock()
	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}
	c.mu.Unlock()
}

func (c *Connection) connectAndListen() error {
	url := c.openclawURL
	for _, prefix := range []string{"wss://", "ws://", "https://", "http://"} {
		url = strings.TrimPrefix(url, prefix)
	}
	url = strings.TrimSuffix(url, "/")
	wsURL := "wss://" + url

	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return fmt.Errorf("dial %s: %w", wsURL, err)
	}

	// Reset state for new connection
	c.mu.Lock()
	c.conn = conn
	c.mu.Unlock()
	c.done = make(chan struct{})
	c.events = make(chan wireMessage, 100)

	go c.readLoop()

	if err := c.authenticate(); err != nil {
		conn.Close()
		return fmt.Errorf("auth: %w", err)
	}

	c.connected.Store(true)
	slog.Info("relay: connected to OpenClaw", "deviceId", c.deviceID[:min(8, len(c.deviceID))], "url", wsURL)

	// Listen for events until disconnect or stop
	err = c.eventLoop()
	c.connected.Store(false)
	return err
}

func (c *Connection) readLoop() {
	defer func() {
		select {
		case <-c.done:
		default:
			close(c.done)
		}
	}()

	for {
		c.mu.Lock()
		conn := c.conn
		c.mu.Unlock()
		if conn == nil {
			return
		}

		_, message, err := conn.ReadMessage()
		if err != nil {
			return
		}

		var msg wireMessage
		if err := json.Unmarshal(message, &msg); err != nil {
			continue
		}

		if msg.Type == "res" && msg.ID != "" {
			c.pendingMu.Lock()
			ch, ok := c.pending[msg.ID]
			if ok {
				delete(c.pending, msg.ID)
			}
			c.pendingMu.Unlock()
			if ok {
				ch <- message
				close(ch)
				continue
			}
		}

		if msg.Type == "event" {
			select {
			case c.events <- msg:
			default:
			}
		}
	}
}

func (c *Connection) eventLoop() error {
	pingTicker := time.NewTicker(30 * time.Second)
	defer pingTicker.Stop()

	for {
		select {
		case <-c.stopCh:
			c.mu.Lock()
			if c.conn != nil {
				c.conn.Close()
				c.conn = nil
			}
			c.mu.Unlock()
			return nil

		case <-c.done:
			return fmt.Errorf("connection closed")

		case evt := <-c.events:
			if evt.Event == "chat" {
				c.handleChatEvent(evt)
			}

		case <-pingTicker.C:
			c.mu.Lock()
			conn := c.conn
			c.mu.Unlock()
			if conn != nil {
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					return fmt.Errorf("ping failed: %w", err)
				}
			}
		}
	}
}

func (c *Connection) handleChatEvent(evt wireMessage) {
	var payload map[string]interface{}
	if err := json.Unmarshal(evt.Payload, &payload); err != nil {
		return
	}

	state, _ := payload["state"].(string)
	if state != "final" {
		return
	}

	// Extract agent name from session key (format: "agent:{agentId}:main")
	agentName := "Agent"
	if sessionKey, ok := payload["sessionKey"].(string); ok {
		parts := strings.Split(sessionKey, ":")
		if len(parts) >= 2 && parts[0] == "agent" {
			agentName = parts[1]
			// Capitalize first letter
			if len(agentName) > 0 {
				agentName = strings.ToUpper(agentName[:1]) + agentName[1:]
			}
		}
	}

	c.lastEvent.Store(time.Now())
	slog.Info("relay: chat final event", "deviceId", c.deviceID[:min(8, len(c.deviceID))], "agent", agentName)

	if c.onAgentMessage != nil {
		c.onAgentMessage(c.deviceID, agentName)
	}
}

func (c *Connection) send(method string, params interface{}) (wireMessage, error) {
	id := fmt.Sprintf("relay-%d", c.nextID.Add(1))

	ch := make(chan json.RawMessage, 1)
	c.pendingMu.Lock()
	c.pending[id] = ch
	c.pendingMu.Unlock()

	req := wireMessage{
		Type:   "req",
		ID:     id,
		Method: method,
		Params: params,
	}
	data, _ := json.Marshal(req)

	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()
	if conn == nil {
		return wireMessage{}, fmt.Errorf("not connected")
	}

	if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
		c.pendingMu.Lock()
		delete(c.pending, id)
		c.pendingMu.Unlock()
		return wireMessage{}, err
	}

	select {
	case raw := <-ch:
		var resp wireMessage
		json.Unmarshal(raw, &resp)
		return resp, nil
	case <-time.After(15 * time.Second):
		c.pendingMu.Lock()
		delete(c.pending, id)
		c.pendingMu.Unlock()
		return wireMessage{}, fmt.Errorf("timeout")
	case <-c.done:
		return wireMessage{}, fmt.Errorf("connection closed")
	}
}

func (c *Connection) authenticate() error {
	var nonce string
	timeout := time.After(10 * time.Second)
	for {
		select {
		case evt := <-c.events:
			if evt.Event == "connect.challenge" {
				var payload map[string]interface{}
				json.Unmarshal(evt.Payload, &payload)
				if n, ok := payload["nonce"].(string); ok {
					nonce = n
				}
			}
		case <-timeout:
			return fmt.Errorf("timeout waiting for challenge")
		case <-c.done:
			return fmt.Errorf("connection closed before challenge")
		}
		if nonce != "" {
			break
		}
	}

	clientID := "openclaw-ios"
	mode := "ui"
	role := "operator"
	scopes := "operator.read,operator.write"
	signedAt := time.Now().UnixMilli()

	signPayload := fmt.Sprintf("v2|%s|%s|%s|%s|%s|%d|%s|%s",
		c.relayDeviceID, clientID, mode, role, scopes, signedAt, c.openclawToken, nonce)

	signature := ed25519.Sign(c.privateKey, []byte(signPayload))

	params := map[string]interface{}{
		"minProtocol": 3,
		"maxProtocol": 3,
		"client": map[string]interface{}{
			"id":          clientID,
			"displayName": "Claudio Relay",
			"version":     "1.0.0",
			"platform":    "server",
			"mode":        mode,
		},
		"role":   role,
		"scopes": []string{"operator.read", "operator.write"},
		"caps":   []string{},
		"auth":   map[string]interface{}{"token": c.openclawToken},
		"device": map[string]interface{}{
			"id":        c.relayDeviceID,
			"publicKey": base64URLEncode(c.publicKey),
			"signature": base64URLEncode(signature),
			"signedAt":  signedAt,
			"nonce":     nonce,
		},
	}

	resp, err := c.send("connect", params)
	if err != nil {
		return err
	}

	if resp.Error != nil {
		return fmt.Errorf("connect error: %s: %s", resp.Error.Code, resp.Error.Message)
	}
	if !resp.OK {
		return fmt.Errorf("connect rejected")
	}

	return nil
}

// Status returns the current status of this connection.
func (c *Connection) Status() ConnectionStatus {
	s := ConnectionStatus{
		DeviceID:    c.deviceID[:min(8, len(c.deviceID))] + "...",
		OpenclawURL: c.openclawURL,
		Connected:   c.connected.Load(),
	}
	if t, ok := c.lastEvent.Load().(time.Time); ok && !t.IsZero() {
		s.LastEvent = t.Format(time.RFC3339)
	}
	if e, ok := c.lastError.Load().(string); ok && e != "" {
		s.LastError = e
	}
	return s
}

func base64URLEncode(data []byte) string {
	s := base64.StdEncoding.EncodeToString(data)
	s = strings.ReplaceAll(s, "+", "-")
	s = strings.ReplaceAll(s, "/", "_")
	s = strings.TrimRight(s, "=")
	return s
}
