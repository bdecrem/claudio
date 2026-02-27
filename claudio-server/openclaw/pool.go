package openclaw

import (
	"fmt"
	"log/slog"
	"sync"
)

// Pool manages WebSocket connections to OpenClaw servers.
// One connection per unique (url, token) pair.
type Pool struct {
	mu      sync.Mutex
	clients map[string]*Client // key: "url|token"
}

func NewPool() *Pool {
	return &Pool{
		clients: make(map[string]*Client),
	}
}

// Get returns a connected client for the given URL/token, creating one if needed.
func (p *Pool) Get(url, token string) (*Client, error) {
	key := url + "|" + token
	p.mu.Lock()
	if c, ok := p.clients[key]; ok && c.IsConnected() {
		p.mu.Unlock()
		return c, nil
	}
	p.mu.Unlock()

	// Create and connect a new client
	slog.Info("openclaw pool: connecting", "url", url)
	c := NewClient(url, token)
	if err := c.Connect(); err != nil {
		return nil, fmt.Errorf("pool connect: %w", err)
	}

	p.mu.Lock()
	p.clients[key] = c
	p.mu.Unlock()

	return c, nil
}

func (p *Pool) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, c := range p.clients {
		c.Close()
	}
	p.clients = make(map[string]*Client)
}
