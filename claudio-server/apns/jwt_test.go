package apns

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"testing"
	"time"
)

func TestSignJWT(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	now := time.Date(2025, 1, 15, 12, 0, 0, 0, time.UTC)
	token, err := signJWT("KEY123", "TEAM456", key, now)
	if err != nil {
		t.Fatal(err)
	}

	// Verify structure
	header, claims, _, err := VerifyJWTStructure(token)
	if err != nil {
		t.Fatal(err)
	}

	if header["alg"] != "ES256" {
		t.Errorf("alg = %v, want ES256", header["alg"])
	}
	if header["kid"] != "KEY123" {
		t.Errorf("kid = %v, want KEY123", header["kid"])
	}
	if claims["iss"] != "TEAM456" {
		t.Errorf("iss = %v, want TEAM456", claims["iss"])
	}
	// JSON numbers are float64
	if iat, ok := claims["iat"].(float64); !ok || int64(iat) != now.Unix() {
		t.Errorf("iat = %v, want %d", claims["iat"], now.Unix())
	}

	// Verify signature
	if !VerifyES256(token, &key.PublicKey) {
		t.Error("signature verification failed")
	}
}

func TestSignJWTDifferentKeys(t *testing.T) {
	key1, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	key2, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)

	token, err := signJWT("K1", "T1", key1, time.Now())
	if err != nil {
		t.Fatal(err)
	}

	// Should not verify with wrong key
	if VerifyES256(token, &key2.PublicKey) {
		t.Error("should not verify with wrong key")
	}
}
