package ws

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"time"
)

type ConnectParams struct {
	MinProtocol int              `json:"minProtocol"`
	MaxProtocol int              `json:"maxProtocol"`
	Client      *ConnectClient   `json:"client"`
	Device      *ConnectDevice   `json:"device"`
	Auth        *ConnectAuth     `json:"auth"`
	Role        string           `json:"role"`
}

type ConnectClient struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Version     string `json:"version"`
	Platform    string `json:"platform"`
	Mode        string `json:"mode"`
}

type ConnectDevice struct {
	ID        string `json:"id"`
	PublicKey string `json:"publicKey"`
	Signature string `json:"signature"`
	SignedAt  int64  `json:"signedAt"`
	Nonce     string `json:"nonce"`
}

type ConnectAuth struct {
	Token string `json:"token"`
}

// VerifyConnect validates the connect handshake and returns the user ID (device ID)
func VerifyConnect(paramsRaw json.RawMessage, challengeNonce string) (userID string, displayName string, err error) {
	var params ConnectParams
	if err := json.Unmarshal(paramsRaw, &params); err != nil {
		return "", "", fmt.Errorf("invalid connect params: %w", err)
	}

	if params.Device == nil {
		return "", "", fmt.Errorf("missing device info")
	}

	dev := params.Device

	// Verify nonce matches
	if dev.Nonce != challengeNonce {
		return "", "", fmt.Errorf("nonce mismatch")
	}

	// Check timestamp freshness (within 5 minutes)
	signedAt := time.UnixMilli(dev.SignedAt)
	if math.Abs(time.Since(signedAt).Seconds()) > 300 {
		return "", "", fmt.Errorf("signature expired")
	}

	// Decode public key
	pubKeyBytes, err := base64URLDecode(dev.PublicKey)
	if err != nil || len(pubKeyBytes) != ed25519.PublicKeySize {
		return "", "", fmt.Errorf("invalid public key")
	}
	pubKey := ed25519.PublicKey(pubKeyBytes)

	// Verify device ID = SHA256(publicKey)
	hash := sha256.Sum256(pubKeyBytes)
	expectedID := hex.EncodeToString(hash[:])
	if dev.ID != expectedID {
		return "", "", fmt.Errorf("device ID mismatch")
	}

	// Reconstruct and verify signature
	token := ""
	if params.Auth != nil {
		token = params.Auth.Token
	}
	payload := fmt.Sprintf("v2|%s|%s|%s|%s|%s|%d|%s|%s",
		dev.ID,
		safeClientID(params.Client),
		safeClientMode(params.Client),
		params.Role,
		"operator.read,operator.write",
		dev.SignedAt,
		token,
		dev.Nonce,
	)

	sigBytes, err := base64URLDecode(dev.Signature)
	if err != nil {
		return "", "", fmt.Errorf("invalid signature encoding")
	}

	if !ed25519.Verify(pubKey, []byte(payload), sigBytes) {
		slog.Warn("signature verification failed", "payload", payload)
		return "", "", fmt.Errorf("invalid signature")
	}

	displayName = ""
	if params.Client != nil {
		displayName = params.Client.DisplayName
	}

	return dev.ID, displayName, nil
}

func base64URLDecode(s string) ([]byte, error) {
	// Add padding if needed
	switch len(s) % 4 {
	case 2:
		s += "=="
	case 3:
		s += "="
	}
	s = strings.ReplaceAll(s, "-", "+")
	s = strings.ReplaceAll(s, "_", "/")
	return base64.StdEncoding.DecodeString(s)
}

func safeClientID(c *ConnectClient) string {
	if c == nil {
		return "unknown"
	}
	return c.ID
}

func safeClientMode(c *ConnectClient) string {
	if c == nil {
		return "ui"
	}
	return c.Mode
}
