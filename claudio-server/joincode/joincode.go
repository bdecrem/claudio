package joincode

import (
	"errors"
	"strings"
)

const (
	version1 = 0x01
	charset  = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	dashEvery = 4
)

// Encode builds a universal join code from a server URL and invite code.
// The server URL should be without https:// prefix.
func Encode(externalURL, inviteCode string) string {
	// Strip https:// or http:// if present
	url := externalURL
	for _, prefix := range []string{"https://", "http://"} {
		url = strings.TrimPrefix(url, prefix)
	}

	// Build binary payload: [version][url bytes][0x00][invite code bytes]
	var payload []byte
	payload = append(payload, version1)
	payload = append(payload, []byte(url)...)
	payload = append(payload, 0x00)
	payload = append(payload, []byte(inviteCode)...)

	encoded := base32Encode(payload)
	return insertDashes(encoded)
}

// Decode parses a universal join code back into server URL and invite code.
func Decode(code string) (serverURL, inviteCode string, err error) {
	// Strip dashes, spaces, and normalize to uppercase
	clean := strings.Map(func(r rune) rune {
		if r == '-' || r == ' ' {
			return -1
		}
		return r
	}, strings.ToUpper(code))

	if len(clean) == 0 {
		return "", "", errors.New("empty code")
	}

	payload, err := base32Decode(clean)
	if err != nil {
		return "", "", err
	}

	if len(payload) < 3 {
		return "", "", errors.New("payload too short")
	}

	if payload[0] != version1 {
		return "", "", errors.New("unsupported version")
	}

	// Find null separator
	sepIdx := -1
	for i := 1; i < len(payload); i++ {
		if payload[i] == 0x00 {
			sepIdx = i
			break
		}
	}
	if sepIdx < 0 {
		return "", "", errors.New("missing separator")
	}

	url := string(payload[1:sepIdx])
	invite := string(payload[sepIdx+1:])

	if url == "" || invite == "" {
		return "", "", errors.New("empty url or invite code")
	}

	serverURL = "https://" + url
	inviteCode = invite
	return
}

func base32Encode(data []byte) string {
	if len(data) == 0 {
		return ""
	}

	var result []byte
	buffer := 0
	bitsLeft := 0

	for _, b := range data {
		buffer = (buffer << 8) | int(b)
		bitsLeft += 8
		for bitsLeft >= 5 {
			bitsLeft -= 5
			idx := (buffer >> bitsLeft) & 0x1F
			result = append(result, charset[idx])
		}
	}

	// Remaining bits
	if bitsLeft > 0 {
		idx := (buffer << (5 - bitsLeft)) & 0x1F
		result = append(result, charset[idx])
	}

	return string(result)
}

func base32Decode(s string) ([]byte, error) {
	if len(s) == 0 {
		return nil, nil
	}

	// Build reverse lookup
	lookup := make(map[byte]int)
	for i := 0; i < len(charset); i++ {
		lookup[charset[i]] = i
	}

	var result []byte
	buffer := 0
	bitsLeft := 0

	for i := 0; i < len(s); i++ {
		val, ok := lookup[s[i]]
		if !ok {
			return nil, errors.New("invalid character in code")
		}
		buffer = (buffer << 5) | val
		bitsLeft += 5
		if bitsLeft >= 8 {
			bitsLeft -= 8
			result = append(result, byte((buffer>>bitsLeft)&0xFF))
		}
	}

	return result, nil
}

func insertDashes(s string) string {
	var parts []string
	for i := 0; i < len(s); i += dashEvery {
		end := i + dashEvery
		if end > len(s) {
			end = len(s)
		}
		parts = append(parts, s[i:end])
	}
	return strings.Join(parts, "-")
}
