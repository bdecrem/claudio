package db

import (
	"crypto/rand"
	"database/sql"
	"fmt"
	"math/big"
	"time"
)

type InviteCode struct {
	Code      string     `json:"code"`
	RoomID    string     `json:"roomId"`
	ExpiresAt *time.Time `json:"expiresAt,omitempty"`
	MaxUses   int        `json:"maxUses"`
	UseCount  int        `json:"useCount"`
	CreatedAt time.Time  `json:"createdAt"`
}

const inviteChars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // no I/O/0/1 for readability

func generateInviteCode() string {
	code := make([]byte, 8)
	for i := range code {
		n, _ := rand.Int(rand.Reader, big.NewInt(int64(len(inviteChars))))
		code[i] = inviteChars[n.Int64()]
	}
	return string(code)
}

func (db *DB) CreateInvite(roomID, createdBy string, expiresIn *time.Duration, maxUses int) (*InviteCode, error) {
	code := generateInviteCode()
	now := time.Now().UTC()

	var expiresAt *time.Time
	if expiresIn != nil {
		t := now.Add(*expiresIn)
		expiresAt = &t
	}

	_, err := db.Exec(`
		INSERT INTO invite_codes (code, room_id, created_by, expires_at, max_uses, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, code, roomID, createdBy, expiresAt, maxUses, now)
	if err != nil {
		return nil, err
	}

	return &InviteCode{
		Code:      code,
		RoomID:    roomID,
		ExpiresAt: expiresAt,
		MaxUses:   maxUses,
		CreatedAt: now,
	}, nil
}

// LookupInvite returns the invite and room ID without redeeming it.
func (db *DB) LookupInvite(code string) (*InviteCode, error) {
	var invite InviteCode
	var expiresAt sql.NullTime
	err := db.QueryRow(`
		SELECT code, room_id, expires_at, max_uses, use_count, created_at
		FROM invite_codes WHERE code = ?
	`, code).Scan(&invite.Code, &invite.RoomID, &expiresAt, &invite.MaxUses, &invite.UseCount, &invite.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("invalid invite code")
	}
	if err != nil {
		return nil, err
	}
	if expiresAt.Valid {
		invite.ExpiresAt = &expiresAt.Time
		if expiresAt.Time.Before(time.Now().UTC()) {
			return nil, fmt.Errorf("invite code expired")
		}
	}
	if invite.MaxUses > 0 && invite.UseCount >= invite.MaxUses {
		return nil, fmt.Errorf("invite code fully used")
	}
	return &invite, nil
}

func (db *DB) RedeemInvite(code string) (string, error) {
	var invite InviteCode
	var expiresAt sql.NullTime
	err := db.QueryRow(`
		SELECT code, room_id, expires_at, max_uses, use_count
		FROM invite_codes WHERE code = ?
	`, code).Scan(&invite.Code, &invite.RoomID, &expiresAt, &invite.MaxUses, &invite.UseCount)
	if err == sql.ErrNoRows {
		return "", fmt.Errorf("invalid invite code")
	}
	if err != nil {
		return "", err
	}

	if expiresAt.Valid && expiresAt.Time.Before(time.Now().UTC()) {
		return "", fmt.Errorf("invite code expired")
	}
	if invite.MaxUses > 0 && invite.UseCount >= invite.MaxUses {
		return "", fmt.Errorf("invite code fully used")
	}

	_, err = db.Exec(`UPDATE invite_codes SET use_count = use_count + 1 WHERE code = ?`, code)
	if err != nil {
		return "", err
	}

	return invite.RoomID, nil
}
