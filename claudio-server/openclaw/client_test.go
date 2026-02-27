package openclaw

import (
	"testing"
)

func TestLiveConnect(t *testing.T) {
	url := "wss://theaf-web.ngrok.io"
	token := "***REDACTED***"

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
	url := "wss://theaf-web.ngrok.io"
	token := "***REDACTED***"

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
