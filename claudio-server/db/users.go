package db

import (
	"database/sql"
	"time"
)

type User struct {
	ID          string    `json:"id"`
	PublicKey   string    `json:"publicKey"`
	DisplayName string    `json:"displayName"`
	AvatarEmoji string    `json:"avatarEmoji"`
	CreatedAt   time.Time `json:"createdAt"`
	UpdatedAt   time.Time `json:"updatedAt"`
}

func (db *DB) UpsertUser(id, publicKey, displayName, avatarEmoji string) (*User, error) {
	now := time.Now().UTC()
	_, err := db.Exec(`
		INSERT INTO users (id, public_key, display_name, avatar_emoji, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			display_name = CASE WHEN excluded.display_name != '' THEN excluded.display_name ELSE users.display_name END,
			avatar_emoji = CASE WHEN excluded.avatar_emoji != '' THEN excluded.avatar_emoji ELSE users.avatar_emoji END,
			updated_at = excluded.updated_at
	`, id, publicKey, displayName, avatarEmoji, now, now)
	if err != nil {
		return nil, err
	}
	return db.GetUser(id)
}

func (db *DB) GetUser(id string) (*User, error) {
	u := &User{}
	err := db.QueryRow(`
		SELECT id, public_key, display_name, avatar_emoji, created_at, updated_at
		FROM users WHERE id = ?
	`, id).Scan(&u.ID, &u.PublicKey, &u.DisplayName, &u.AvatarEmoji, &u.CreatedAt, &u.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return u, err
}

func (db *DB) UpdateUser(id, displayName, avatarEmoji string) error {
	_, err := db.Exec(`
		UPDATE users SET
			display_name = CASE WHEN ? != '' THEN ? ELSE display_name END,
			avatar_emoji = CASE WHEN ? != '' THEN ? ELSE avatar_emoji END,
			updated_at = datetime('now')
		WHERE id = ?
	`, displayName, displayName, avatarEmoji, avatarEmoji, id)
	return err
}
