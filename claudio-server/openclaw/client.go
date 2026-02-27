package openclaw

import (
	"log/slog"
	"sync"
)

// Client represents a connection to an OpenClaw server.
// Phase 4 will implement the full WebSocket connection, auth, and RPC.
type Client struct {
	url       string
	token     string
	connected bool
	mu        sync.Mutex
}

func NewClient(url, token string) *Client {
	return &Client{
		url:   url,
		token: token,
	}
}

func (c *Client) IsConnected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected
}

func (c *Client) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.connected = false
	slog.Info("openclaw client closed", "url", c.url)
}
