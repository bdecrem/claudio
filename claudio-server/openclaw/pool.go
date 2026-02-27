package openclaw

import (
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

func (p *Pool) Get(url, token string) *Client {
	key := url + "|" + token
	p.mu.Lock()
	defer p.mu.Unlock()

	if c, ok := p.clients[key]; ok && c.IsConnected() {
		return c
	}

	c := NewClient(url, token)
	p.clients[key] = c
	return c
}

func (p *Pool) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, c := range p.clients {
		c.Close()
	}
	p.clients = make(map[string]*Client)
}
