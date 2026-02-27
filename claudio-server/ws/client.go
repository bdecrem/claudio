package ws

import (
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	writeWait  = 10 * time.Second
	pongWait   = 60 * time.Second
	pingPeriod = (pongWait * 9) / 10
	maxMsgSize = 1 << 20 // 1MB
)

type Client struct {
	hub    *Hub
	conn   *websocket.Conn
	send   chan []byte
	done   chan struct{} // closed on unregister
	userID string       // set after auth
	mu     sync.RWMutex

	// Auth state
	challengeNonce string
	authenticated  bool
	displayName    string
}

func NewClient(hub *Hub, conn *websocket.Conn) *Client {
	return &Client{
		hub:  hub,
		conn: conn,
		send: make(chan []byte, 256),
		done: make(chan struct{}),
	}
}

func (c *Client) UserID() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.userID
}

func (c *Client) IsAuthenticated() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.authenticated
}

func (c *Client) DisplayName() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.displayName
}

func (c *Client) SetAuth(userID, displayName string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.userID = userID
	c.authenticated = true
	c.displayName = displayName
}

func (c *Client) SendJSON(v interface{}) {
	data, err := json.Marshal(v)
	if err != nil {
		slog.Error("marshal error", "err", err)
		return
	}
	select {
	case c.send <- data:
	default:
		slog.Warn("client send buffer full, dropping message")
	}
}

func (c *Client) ReadPump() {
	defer func() {
		c.hub.unregister <- c
		c.conn.Close()
	}()

	c.conn.SetReadLimit(maxMsgSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				slog.Info("client disconnected", "err", err)
			}
			return
		}
		c.hub.handleMessage(c, message)
	}
}

func (c *Client) WritePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case message, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, message); err != nil {
				return
			}

		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}
