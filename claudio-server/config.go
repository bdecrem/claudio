package main

import (
	"flag"
	"os"

	"github.com/nicebartender/claudio-server/apns"
)

type Config struct {
	ListenAddr  string
	DBPath      string
	ExternalURL string
	APNS        apns.Config
	PushSecret  string
}

func LoadConfig() Config {
	cfg := Config{}

	flag.StringVar(&cfg.ListenAddr, "addr", defaultAddr(), "Listen address")
	flag.StringVar(&cfg.DBPath, "db", envOrDefault("CLAUDIO_DB", "claudio.db"), "SQLite database path")
	flag.StringVar(&cfg.ExternalURL, "external-url", envOrDefault("CLAUDIO_EXTERNAL_URL", ""), "External URL advertised in join codes")
	flag.Parse()

	cfg.APNS = apns.Config{
		KeyPath:   os.Getenv("CLAUDIO_APNS_KEY_PATH"),
		KeyBase64: os.Getenv("CLAUDIO_APNS_KEY_BASE64"),
		KeyID:     os.Getenv("CLAUDIO_APNS_KEY_ID"),
		TeamID:    os.Getenv("CLAUDIO_APNS_TEAM_ID"),
		Sandbox:   os.Getenv("CLAUDIO_APNS_SANDBOX") == "true",
	}
	cfg.PushSecret = os.Getenv("CLAUDIO_PUSH_SECRET")

	return cfg
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func defaultAddr() string {
	if v := os.Getenv("CLAUDIO_ADDR"); v != "" {
		return v
	}
	// Railway, Render, etc. set PORT
	if port := os.Getenv("PORT"); port != "" {
		return ":" + port
	}
	return ":8090"
}
