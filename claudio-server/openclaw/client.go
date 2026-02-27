package openclaw

import (
	"crypto/ed25519"
	"crypto/rand"
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

type Client struct {
	url       string
	token     string
	conn      *websocket.Conn
	connected bool
	mu        sync.Mutex
	nextID    atomic.Int64

	pending   map[string]chan json.RawMessage
	pendingMu sync.Mutex

	events chan wireMessage
	done   chan struct{}

	// Ed25519 device identity
	privateKey ed25519.PrivateKey
	publicKey  ed25519.PublicKey
	deviceID   string
}

// Wire format — same as ws/protocol.go
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

type ChatResponse struct {
	Text string
}

func NewClient(url, token string) *Client {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	hash := sha256.Sum256(pub)
	deviceID := hex.EncodeToString(hash[:])

	return &Client{
		url:        url,
		token:      token,
		pending:    make(map[string]chan json.RawMessage),
		events:     make(chan wireMessage, 100),
		done:       make(chan struct{}),
		privateKey: priv,
		publicKey:  pub,
		deviceID:   deviceID,
	}
}

func (c *Client) IsConnected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected
}

func (c *Client) Connect() error {
	url := c.url
	for _, prefix := range []string{"wss://", "ws://", "https://", "http://"} {
		url = strings.TrimPrefix(url, prefix)
	}
	url = strings.TrimSuffix(url, "/")
	wsURL := "wss://" + url

	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return fmt.Errorf("dial %s: %w", wsURL, err)
	}

	c.mu.Lock()
	c.conn = conn
	c.mu.Unlock()

	go c.readLoop()

	if err := c.authenticate(); err != nil {
		conn.Close()
		return fmt.Errorf("auth: %w", err)
	}

	c.mu.Lock()
	c.connected = true
	c.mu.Unlock()

	slog.Info("openclaw: connected", "url", wsURL)
	return nil
}

func (c *Client) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.connected = false
	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}
}

func (c *Client) readLoop() {
	defer func() {
		select {
		case <-c.done:
		default:
			close(c.done)
		}
		c.mu.Lock()
		c.connected = false
		c.mu.Unlock()
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
			slog.Debug("openclaw readLoop ended", "err", err)
			return
		}

		var msg wireMessage
		if err := json.Unmarshal(message, &msg); err != nil {
			continue
		}

		// Response to a pending request?
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

		// Event?
		if msg.Type == "event" {
			select {
			case c.events <- msg:
			default:
			}
		}
	}
}

func (c *Client) send(method string, params interface{}) (wireMessage, error) {
	id := fmt.Sprintf("go-%d", c.nextID.Add(1))

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
	case <-time.After(60 * time.Second):
		c.pendingMu.Lock()
		delete(c.pending, id)
		c.pendingMu.Unlock()
		return wireMessage{}, fmt.Errorf("timeout waiting for %s response", method)
	case <-c.done:
		return wireMessage{}, fmt.Errorf("connection closed")
	}
}

// base64URLEncode encodes bytes to base64url without padding (matching iOS client)
func base64URLEncode(data []byte) string {
	s := base64.StdEncoding.EncodeToString(data)
	s = strings.ReplaceAll(s, "+", "-")
	s = strings.ReplaceAll(s, "/", "_")
	s = strings.TrimRight(s, "=")
	return s
}

func (c *Client) authenticate() error {
	// Wait for connect.challenge event
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

	// Sign the challenge — same format as iOS DeviceIdentity.signChallenge
	clientID := "openclaw-ios"
	mode := "ui"
	role := "operator"
	scopes := "operator.read,operator.write"
	signedAt := time.Now().UnixMilli()

	signPayload := fmt.Sprintf("v2|%s|%s|%s|%s|%s|%d|%s|%s",
		c.deviceID, clientID, mode, role, scopes, signedAt, c.token, nonce)

	signature := ed25519.Sign(c.privateKey, []byte(signPayload))

	params := map[string]interface{}{
		"minProtocol": 3,
		"maxProtocol": 3,
		"client": map[string]interface{}{
			"id":          clientID,
			"displayName": "Claudio Server",
			"version":     "1.0.0",
			"platform":    "server",
			"mode":        mode,
		},
		"role":   role,
		"scopes": []string{"operator.read", "operator.write"},
		"caps":   []string{},
		"auth":   map[string]interface{}{"token": c.token},
		"device": map[string]interface{}{
			"id":        c.deviceID,
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

// ChatSend sends a message to an agent and waits for the final chat event response.
func (c *Client) ChatSend(sessionKey, message string) (*ChatResponse, error) {
	params := map[string]interface{}{
		"sessionKey":     sessionKey,
		"message":        message,
		"deliver":        false,
		"idempotencyKey": fmt.Sprintf("srv-%d", time.Now().UnixNano()),
	}

	resp, err := c.send("chat.send", params)
	if err != nil {
		return nil, fmt.Errorf("chat.send: %w", err)
	}
	if !resp.OK {
		errMsg := "unknown error"
		if resp.Error != nil {
			errMsg = resp.Error.Message
		}
		return nil, fmt.Errorf("chat.send rejected: %s", errMsg)
	}

	// Collect chat events until state=="final"
	var fullText string
	timeout := time.After(120 * time.Second)
	for {
		select {
		case evt := <-c.events:
			if evt.Event == "tick" {
				continue
			}
			if evt.Event != "chat" {
				continue
			}
			var payload map[string]interface{}
			json.Unmarshal(evt.Payload, &payload)

			state, _ := payload["state"].(string)
			text := extractChatText(payload)

			switch state {
			case "delta":
				fullText += text
			case "final":
				if text != "" {
					fullText = text
				}
				return &ChatResponse{Text: fullText}, nil
			case "error":
				errMsg, _ := payload["error"].(string)
				return nil, fmt.Errorf("agent error: %s", errMsg)
			case "aborted":
				return nil, fmt.Errorf("agent aborted")
			}
		case <-timeout:
			if fullText != "" {
				return &ChatResponse{Text: fullText}, nil
			}
			return nil, fmt.Errorf("timeout waiting for agent response")
		case <-c.done:
			return nil, fmt.Errorf("connection closed during chat")
		}
	}
}

func extractChatText(payload map[string]interface{}) string {
	msg, ok := payload["message"].(map[string]interface{})
	if !ok {
		return ""
	}
	content, ok := msg["content"].([]interface{})
	if !ok {
		return ""
	}
	var texts []string
	for _, block := range content {
		bm, ok := block.(map[string]interface{})
		if !ok {
			continue
		}
		if t, ok := bm["text"].(string); ok && t != "" {
			texts = append(texts, t)
		}
	}
	return strings.Join(texts, "")
}
