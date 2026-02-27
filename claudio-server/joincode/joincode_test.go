package joincode

import (
	"testing"
)

func TestRoundTrip(t *testing.T) {
	tests := []struct {
		url    string
		invite string
	}{
		{"192.168.7.189:8090", "K7MX9PR2"},
		{"claudio.example.com", "ABCD1234"},
		{"my-server.io:443", "XXXXXXXX"},
	}

	for _, tt := range tests {
		code := Encode(tt.url, tt.invite)
		t.Logf("Encode(%q, %q) = %q", tt.url, tt.invite, code)

		serverURL, inviteCode, err := Decode(code)
		if err != nil {
			t.Fatalf("Decode(%q) error: %v", code, err)
		}
		if serverURL != "https://"+tt.url {
			t.Errorf("serverURL = %q, want %q", serverURL, "https://"+tt.url)
		}
		if inviteCode != tt.invite {
			t.Errorf("inviteCode = %q, want %q", inviteCode, tt.invite)
		}
	}
}

func TestDecodeStripsPrefix(t *testing.T) {
	// Encode with https:// prefix should still work
	code := Encode("https://example.com", "TEST1234")
	serverURL, inviteCode, err := Decode(code)
	if err != nil {
		t.Fatalf("Decode error: %v", err)
	}
	if serverURL != "https://example.com" {
		t.Errorf("serverURL = %q, want %q", serverURL, "https://example.com")
	}
	if inviteCode != "TEST1234" {
		t.Errorf("inviteCode = %q, want %q", inviteCode, "TEST1234")
	}
}

func TestDecodeCaseInsensitive(t *testing.T) {
	code := Encode("example.com", "ABCD1234")
	lower := ""
	for _, c := range code {
		if c >= 'A' && c <= 'Z' {
			lower += string(c + 32)
		} else {
			lower += string(c)
		}
	}
	serverURL, inviteCode, err := Decode(lower)
	if err != nil {
		t.Fatalf("Decode lowercase error: %v", err)
	}
	if serverURL != "https://example.com" {
		t.Errorf("serverURL = %q", serverURL)
	}
	if inviteCode != "ABCD1234" {
		t.Errorf("inviteCode = %q", inviteCode)
	}
}

func TestDecodeInvalid(t *testing.T) {
	cases := []string{
		"",
		"AAAA",  // too short payload
		"!@#$%", // invalid chars
	}
	for _, c := range cases {
		_, _, err := Decode(c)
		if err == nil {
			t.Errorf("Decode(%q) should have returned error", c)
		}
	}
}

func TestDashFormat(t *testing.T) {
	code := Encode("192.168.7.189:8090", "K7MX9PR2")
	// Verify dashes every 4 chars
	for i, part := range splitDashes(code) {
		if i < len(splitDashes(code))-1 && len(part) != 4 {
			t.Errorf("part %d has length %d, expected 4", i, len(part))
		}
	}
}

func splitDashes(s string) []string {
	var parts []string
	current := ""
	for _, c := range s {
		if c == '-' {
			parts = append(parts, current)
			current = ""
		} else {
			current += string(c)
		}
	}
	if current != "" {
		parts = append(parts, current)
	}
	return parts
}
