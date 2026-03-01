package apns

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"time"
)

// signJWT creates an ES256-signed JWT for APNs token-based auth.
func signJWT(keyID, teamID string, key *ecdsa.PrivateKey, now time.Time) (string, error) {
	header := map[string]string{
		"alg": "ES256",
		"kid": keyID,
	}
	claims := map[string]interface{}{
		"iss": teamID,
		"iat": now.Unix(),
	}

	headerJSON, err := json.Marshal(header)
	if err != nil {
		return "", fmt.Errorf("marshal header: %w", err)
	}
	claimsJSON, err := json.Marshal(claims)
	if err != nil {
		return "", fmt.Errorf("marshal claims: %w", err)
	}

	headerB64 := base64.RawURLEncoding.EncodeToString(headerJSON)
	claimsB64 := base64.RawURLEncoding.EncodeToString(claimsJSON)

	signingInput := headerB64 + "." + claimsB64

	hash := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, key, hash[:])
	if err != nil {
		return "", fmt.Errorf("sign: %w", err)
	}

	// ES256 signature is r || s, each padded to 32 bytes
	curveBits := key.Curve.Params().BitSize
	keyBytes := curveBits / 8
	if curveBits%8 > 0 {
		keyBytes++
	}

	rBytes := r.Bytes()
	sBytes := s.Bytes()

	sig := make([]byte, 2*keyBytes)
	copy(sig[keyBytes-len(rBytes):keyBytes], rBytes)
	copy(sig[2*keyBytes-len(sBytes):], sBytes)

	sigB64 := base64.RawURLEncoding.EncodeToString(sig)

	return signingInput + "." + sigB64, nil
}

// VerifyJWTStructure is a test helper that parses a JWT and returns its claims.
func VerifyJWTStructure(token string) (header, claims map[string]interface{}, sig []byte, err error) {
	parts := splitJWT(token)
	if len(parts) != 3 {
		return nil, nil, nil, fmt.Errorf("expected 3 parts, got %d", len(parts))
	}

	headerJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, nil, nil, fmt.Errorf("decode header: %w", err)
	}
	claimsJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, nil, nil, fmt.Errorf("decode claims: %w", err)
	}
	sigBytes, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, nil, nil, fmt.Errorf("decode sig: %w", err)
	}

	if err := json.Unmarshal(headerJSON, &header); err != nil {
		return nil, nil, nil, fmt.Errorf("unmarshal header: %w", err)
	}
	if err := json.Unmarshal(claimsJSON, &claims); err != nil {
		return nil, nil, nil, fmt.Errorf("unmarshal claims: %w", err)
	}

	return header, claims, sigBytes, nil
}

// VerifyES256 verifies an ES256 JWT signature.
func VerifyES256(token string, key *ecdsa.PublicKey) bool {
	parts := splitJWT(token)
	if len(parts) != 3 {
		return false
	}

	signingInput := parts[0] + "." + parts[1]
	hash := sha256.Sum256([]byte(signingInput))

	sigBytes, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return false
	}

	curveBits := key.Curve.Params().BitSize
	keyBytes := curveBits / 8
	if curveBits%8 > 0 {
		keyBytes++
	}

	if len(sigBytes) != 2*keyBytes {
		return false
	}

	r := new(big.Int).SetBytes(sigBytes[:keyBytes])
	s := new(big.Int).SetBytes(sigBytes[keyBytes:])

	return ecdsa.Verify(key, hash[:], r, s)
}

func splitJWT(token string) []string {
	var parts []string
	start := 0
	for i := 0; i < len(token); i++ {
		if token[i] == '.' {
			parts = append(parts, token[start:i])
			start = i + 1
		}
	}
	parts = append(parts, token[start:])
	return parts
}
