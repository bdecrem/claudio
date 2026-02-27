package main

import (
	"flag"
	"os"
)

type Config struct {
	ListenAddr string
	DBPath     string
}

func LoadConfig() Config {
	cfg := Config{}

	flag.StringVar(&cfg.ListenAddr, "addr", envOrDefault("CLAUDIO_ADDR", ":8090"), "Listen address")
	flag.StringVar(&cfg.DBPath, "db", envOrDefault("CLAUDIO_DB", "claudio.db"), "SQLite database path")
	flag.Parse()

	return cfg
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
