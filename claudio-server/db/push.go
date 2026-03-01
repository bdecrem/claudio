package db

import "fmt"

// UpsertPushToken inserts or updates a push token for a device+bundle pair.
func (d *DB) UpsertPushToken(deviceID, token, bundleID, platform string) error {
	_, err := d.Exec(`
		INSERT INTO push_tokens (device_id, token, bundle_id, platform, updated_at)
		VALUES (?, ?, ?, ?, datetime('now'))
		ON CONFLICT (device_id, bundle_id)
		DO UPDATE SET token = excluded.token, platform = excluded.platform, updated_at = datetime('now')
	`, deviceID, token, bundleID, platform)
	if err != nil {
		return fmt.Errorf("upsert push token: %w", err)
	}
	return nil
}

// GetPushToken returns the APNs token for a given device+bundle pair.
func (d *DB) GetPushToken(deviceID, bundleID string) (string, error) {
	var token string
	err := d.QueryRow(`SELECT token FROM push_tokens WHERE device_id = ? AND bundle_id = ?`, deviceID, bundleID).Scan(&token)
	if err != nil {
		return "", fmt.Errorf("get push token: %w", err)
	}
	return token, nil
}

// GetPushTokensForDevice returns all APNs tokens for a device (across bundle IDs).
func (d *DB) GetPushTokensForDevice(deviceID string) ([]string, error) {
	rows, err := d.Query(`SELECT token FROM push_tokens WHERE device_id = ?`, deviceID)
	if err != nil {
		return nil, fmt.Errorf("get push tokens: %w", err)
	}
	defer rows.Close()

	var tokens []string
	for rows.Next() {
		var token string
		if err := rows.Scan(&token); err != nil {
			return nil, fmt.Errorf("scan push token: %w", err)
		}
		tokens = append(tokens, token)
	}
	return tokens, rows.Err()
}
