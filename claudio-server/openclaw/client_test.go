package openclaw

import (
	"os"
	"testing"
)

func TestLiveConnect(t *testing.T) {
	url := os.Getenv("OPENCLAW_URL")
	token := os.Getenv("OPENCLAW_TOKEN")
	if url == "" || token == "" {
		t.Skip("OPENCLAW_URL and OPENCLAW_TOKEN must be set")
	}

	c := NewClient(url, token)
	err := c.Connect()
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer c.Close()

	if !c.IsConnected() {
		t.Fatal("Expected connected")
	}
	t.Log("Connected successfully")
}

func TestLiveChatSend(t *testing.T) {
	url := os.Getenv("OPENCLAW_URL")
	token := os.Getenv("OPENCLAW_TOKEN")
	if url == "" || token == "" {
		t.Skip("OPENCLAW_URL and OPENCLAW_TOKEN must be set")
	}

	c := NewClient(url, token)
	err := c.Connect()
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer c.Close()

	resp, err := c.ChatSend("agent:hallman:main", "Say hi in one sentence")
	if err != nil {
		t.Fatalf("ChatSend failed: %v", err)
	}

	if resp.Text == "" {
		t.Fatal("Expected non-empty response")
	}
	t.Logf("Agent response: %s", resp.Text)
}
