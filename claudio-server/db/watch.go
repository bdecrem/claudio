package db

import (
	"database/sql"
	"fmt"
)

type Watch struct {
	DeviceID     string
	OpenclawURL  string
	OpenclawToken string
}

// UpsertWatch inserts or updates a push watch for a device.
func (d *DB) UpsertWatch(deviceID, openclawURL, openclawToken string) error {
	_, err := d.Exec(`
		INSERT INTO push_watches (device_id, openclaw_url, openclaw_token, updated_at)
		VALUES (?, ?, ?, datetime('now'))
		ON CONFLICT (device_id)
		DO UPDATE SET openclaw_url = excluded.openclaw_url,
		              openclaw_token = excluded.openclaw_token,
		              updated_at = datetime('now')
	`, deviceID, openclawURL, openclawToken)
	if err != nil {
		return fmt.Errorf("upsert watch: %w", err)
	}
	return nil
}

// GetWatch returns the watch for a given device ID.
func (d *DB) GetWatch(deviceID string) (*Watch, error) {
	var w Watch
	err := d.QueryRow(`SELECT device_id, openclaw_url, openclaw_token FROM push_watches WHERE device_id = ?`, deviceID).
		Scan(&w.DeviceID, &w.OpenclawURL, &w.OpenclawToken)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get watch: %w", err)
	}
	return &w, nil
}

// ListWatches returns all registered watches.
func (d *DB) ListWatches() ([]Watch, error) {
	rows, err := d.Query(`SELECT device_id, openclaw_url, openclaw_token FROM push_watches`)
	if err != nil {
		return nil, fmt.Errorf("list watches: %w", err)
	}
	defer rows.Close()

	var watches []Watch
	for rows.Next() {
		var w Watch
		if err := rows.Scan(&w.DeviceID, &w.OpenclawURL, &w.OpenclawToken); err != nil {
			return nil, fmt.Errorf("scan watch: %w", err)
		}
		watches = append(watches, w)
	}
	return watches, rows.Err()
}

// DeleteWatch removes a watch for a given device ID.
func (d *DB) DeleteWatch(deviceID string) error {
	_, err := d.Exec(`DELETE FROM push_watches WHERE device_id = ?`, deviceID)
	if err != nil {
		return fmt.Errorf("delete watch: %w", err)
	}
	return nil
}
