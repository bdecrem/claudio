package db

import (
	"database/sql"
	_ "embed"
	"fmt"
	"log/slog"

	_ "github.com/mattn/go-sqlite3"
)

//go:embed schema.sql
var schema string

type DB struct {
	*sql.DB
}

func Open(path string) (*DB, error) {
	sqlDB, err := sql.Open("sqlite3", path+"?_journal_mode=WAL&_foreign_keys=ON&_busy_timeout=5000")
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	if _, err := sqlDB.Exec(schema); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("init schema: %w", err)
	}

	// Migrations: add columns that may not exist on older DBs
	sqlDB.Exec("ALTER TABLE rooms ADD COLUMN public BOOLEAN NOT NULL DEFAULT 0")
	sqlDB.Exec("ALTER TABLE participants ADD COLUMN openclaw_agent_id TEXT")

	slog.Info("database opened", "path", path)
	return &DB{sqlDB}, nil
}
