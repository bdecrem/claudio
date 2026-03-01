package apns

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"

	"golang.org/x/net/http2"
)

const (
	productionURL = "https://api.push.apple.com"
	sandboxURL    = "https://api.sandbox.push.apple.com"
)

// Client sends APNs push notifications using JWT (token-based) auth.
type Client struct {
	keyID      string
	teamID     string
	privateKey *ecdsa.PrivateKey
	httpClient *http.Client
	useSandbox bool

	mu       sync.Mutex
	jwtToken string
	jwtExp   time.Time
}

// Config holds APNs configuration loaded from environment.
type Config struct {
	KeyPath   string // path to .p8 file
	KeyBase64 string // or base64-encoded .p8 contents
	KeyID     string
	TeamID    string
	Sandbox   bool
}

// Alert is the alert payload for a push notification.
type Alert struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

// Payload is the full APNs payload.
type Payload struct {
	Alert    Alert             `json:"alert"`
	Sound    string            `json:"sound,omitempty"`
	Badge    *int              `json:"badge,omitempty"`
	ThreadID string            `json:"thread-id,omitempty"`
	Data     map[string]string `json:"data,omitempty"`
}

// NewClient creates an APNs client from config.
func NewClient(cfg Config) (*Client, error) {
	var keyPEM []byte
	var err error

	if cfg.KeyBase64 != "" {
		keyPEM, err = base64.StdEncoding.DecodeString(cfg.KeyBase64)
		if err != nil {
			return nil, fmt.Errorf("decode key base64: %w", err)
		}
	} else if cfg.KeyPath != "" {
		keyPEM, err = os.ReadFile(cfg.KeyPath)
		if err != nil {
			return nil, fmt.Errorf("read key file: %w", err)
		}
	} else {
		return nil, fmt.Errorf("no APNs key configured (set CLAUDIO_APNS_KEY_PATH or CLAUDIO_APNS_KEY_BASE64)")
	}

	block, _ := pem.Decode(keyPEM)
	if block == nil {
		return nil, fmt.Errorf("failed to parse PEM block from key")
	}

	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse private key: %w", err)
	}

	ecKey, ok := key.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("key is not ECDSA (got %T)", key)
	}

	// HTTP/2 transport for APNs
	transport := &http2.Transport{}

	return &Client{
		keyID:      cfg.KeyID,
		teamID:     cfg.TeamID,
		privateKey: ecKey,
		useSandbox: cfg.Sandbox,
		httpClient: &http.Client{
			Transport: transport,
			Timeout:   30 * time.Second,
		},
	}, nil
}

// Send sends a push notification to the given device token.
func (c *Client) Send(token string, payload Payload, bundleID string) error {
	apsPayload := map[string]interface{}{
		"aps": map[string]interface{}{
			"alert": map[string]string{
				"title": payload.Alert.Title,
				"body":  payload.Alert.Body,
			},
			"sound":             orDefault(payload.Sound, "default"),
			"mutable-content":   1,
			"interruption-level": "active",
		},
	}

	if payload.ThreadID != "" {
		apsPayload["aps"].(map[string]interface{})["thread-id"] = payload.ThreadID
	}
	if payload.Badge != nil {
		apsPayload["aps"].(map[string]interface{})["badge"] = *payload.Badge
	}

	// Add custom data at top level
	for k, v := range payload.Data {
		apsPayload[k] = v
	}

	body, err := json.Marshal(apsPayload)
	if err != nil {
		return fmt.Errorf("marshal payload: %w", err)
	}

	baseURL := productionURL
	if c.useSandbox {
		baseURL = sandboxURL
	}

	url := fmt.Sprintf("%s/3/device/%s", baseURL, token)
	req, err := http.NewRequest("POST", url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}

	jwt, err := c.getJWT()
	if err != nil {
		return fmt.Errorf("get JWT: %w", err)
	}

	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", bundleID)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		slog.Info("push sent", "token", token[:8]+"...", "status", resp.StatusCode)
		return nil
	}

	respBody, _ := io.ReadAll(resp.Body)
	slog.Error("push failed", "token", token[:min(8, len(token))]+"...", "status", resp.StatusCode, "body", string(respBody))
	return fmt.Errorf("APNs returned %d: %s", resp.StatusCode, string(respBody))
}

// getJWT returns a cached or fresh JWT for APNs auth.
func (c *Client) getJWT() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Reuse if valid for at least 5 more minutes
	if c.jwtToken != "" && time.Now().Add(5*time.Minute).Before(c.jwtExp) {
		return c.jwtToken, nil
	}

	now := time.Now()
	token, err := signJWT(c.keyID, c.teamID, c.privateKey, now)
	if err != nil {
		return "", err
	}

	c.jwtToken = token
	c.jwtExp = now.Add(50 * time.Minute) // Apple allows up to 60 min
	return token, nil
}

func orDefault(s, d string) string {
	if s != "" {
		return s
	}
	return d
}
