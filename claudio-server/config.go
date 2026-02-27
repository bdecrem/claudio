package main

import (
	"flag"
	"os"
)

type Config struct {
	ListenAddr  string
	DBPath      string
	ExternalURL string
}

func LoadConfig() Config {
	cfg := Config{}

	flag.StringVar(&cfg.ListenAddr, "addr", defaultAddr(), "Listen address")
	flag.StringVar(&cfg.DBPath, "db", envOrDefault("CLAUDIO_DB", "claudio.db"), "SQLite database path")
	flag.StringVar(&cfg.ExternalURL, "external-url", envOrDefault("CLAUDIO_EXTERNAL_URL", ""), "External URL advertised in join codes")
	flag.Parse()

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
