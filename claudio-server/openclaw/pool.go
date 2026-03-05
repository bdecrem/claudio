package openclaw

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
)

// Pool manages WebSocket connections to OpenClaw servers.
// One connection per unique (url, token) pair.
// A single Ed25519 identity is shared across all connections so that
// the device only needs to be paired once — even across deploys.
type Pool struct {
	mu      sync.Mutex
	clients map[string]*Client // key: "url|token"

	// Stable device identity — persisted to disk
	privateKey ed25519.PrivateKey
	publicKey  ed25519.PublicKey
	deviceID   string
}

type persistedKey struct {
	PrivateKey []byte `json:"privateKey"`
	PublicKey  []byte `json:"publicKey"`
}

// NewPool creates a pool with a persisted Ed25519 identity.
// keyDir is the directory to store the key file (e.g. same dir as the DB).
// If empty or load fails, a new key is generated (and saved if possible).
func NewPool(keyDir string) *Pool {
	keyPath := ""
	if keyDir != "" {
		keyPath = filepath.Join(keyDir, "openclaw_device_key.json")
	}

	// Try loading existing key
	if keyPath != "" {
		if data, err := os.ReadFile(keyPath); err == nil {
			var pk persistedKey
			if err := json.Unmarshal(data, &pk); err == nil && len(pk.PrivateKey) == ed25519.PrivateKeySize && len(pk.PublicKey) == ed25519.PublicKeySize {
				hash := sha256.Sum256(pk.PublicKey)
				deviceID := hex.EncodeToString(hash[:])
				slog.Info("openclaw pool: loaded persisted device key", "deviceID", deviceID[:12]+"...")
				return &Pool{
					clients:    make(map[string]*Client),
					privateKey: ed25519.PrivateKey(pk.PrivateKey),
					publicKey:  ed25519.PublicKey(pk.PublicKey),
					deviceID:   deviceID,
				}
			}
		}
	}

	// Generate new key
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	hash := sha256.Sum256(pub)
	deviceID := hex.EncodeToString(hash[:])

	// Persist it
	if keyPath != "" {
		data, _ := json.Marshal(persistedKey{PrivateKey: priv, PublicKey: pub})
		if err := os.WriteFile(keyPath, data, 0600); err != nil {
			slog.Warn("openclaw pool: failed to persist device key", "err", err)
		} else {
			slog.Info("openclaw pool: generated and saved new device key", "deviceID", deviceID[:12]+"...", "path", keyPath)
		}
	}

	return &Pool{
		clients:    make(map[string]*Client),
		privateKey: priv,
		publicKey:  pub,
		deviceID:   deviceID,
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
