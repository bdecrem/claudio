package openclaw

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log/slog"
	"sync"
)

// Pool manages WebSocket connections to OpenClaw servers.
// One connection per unique (url, token) pair.
// A single Ed25519 identity is shared across all connections so that
// the device only needs to be paired once per server process lifetime.
type Pool struct {
	mu      sync.Mutex
	clients map[string]*Client // key: "url|token"

	// Stable device identity — survives reconnects
	privateKey ed25519.PrivateKey
	publicKey  ed25519.PublicKey
	deviceID   string
}

func NewPool() *Pool {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	hash := sha256.Sum256(pub)
	return &Pool{
		clients:    make(map[string]*Client),
		privateKey: priv,
		publicKey:  pub,
		deviceID:   hex.EncodeToString(hash[:]),
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

	// Create and connect a new client with the pool's stable identity
	slog.Info("openclaw pool: connecting", "url", url, "deviceID", p.deviceID[:12]+"...")
	c := NewClientWithIdentity(url, token, p.privateKey, p.publicKey, p.deviceID)
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
