package db

import (
	"crypto/rand"
	"encoding/hex"
	"time"
)

type Room struct {
	ID               string         `json:"id"`
	Name             string         `json:"name"`
	Emoji            string         `json:"emoji"`
	CreatedBy        string         `json:"createdBy"`
	Public           bool           `json:"public"`
	CreatedAt        time.Time      `json:"createdAt"`
	UpdatedAt        time.Time      `json:"updatedAt"`
	ParticipantCount int            `json:"participantCount,omitempty"`
	LastMessage      *LastMessage   `json:"lastMessage,omitempty"`
	UnreadCount      int            `json:"unreadCount,omitempty"`
	Participants     []Participant  `json:"participants,omitempty"`
}

type LastMessage struct {
	Content     string `json:"content"`
	SenderName  string `json:"senderName"`
	SenderEmoji string `json:"senderEmoji"`
	CreatedAt   string `json:"createdAt"`
}

type Participant struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Emoji       string `json:"emoji"`
	IsAgent     bool   `json:"isAgent"`
	IsOnline    bool   `json:"isOnline"`
	Role        string `json:"role"`
	// Agent-specific fields
	AgentID        string `json:"agentId,omitempty"`
	OpenclawURL    string `json:"openclawUrl,omitempty"`
	OpenclawToken  string `json:"-"` // never sent to clients
	OpenclawAgentID string `json:"-"` // agent ID on the OpenClaw server
}

func nanoid() string {
	b := make([]byte, 10)
	rand.Read(b)
	return hex.EncodeToString(b)[:12]
}

const LobbyRoomID = "lobby"

// EnsureLobby creates the default public lobby room if it doesn't already exist.
func (db *DB) EnsureLobby() error {
	var count int
	err := db.QueryRow(`SELECT COUNT(*) FROM rooms WHERE id = ?`, LobbyRoomID).Scan(&count)
	if err != nil {
		return err
	}
	if count > 0 {
		return nil
	}

	// Ensure system user exists (needed for foreign key on created_by)
	_, _ = db.Exec(`
		INSERT OR IGNORE INTO users (id, public_key, display_name, avatar_emoji)
		VALUES ('system', 'system', 'System', '🤖')
	`)

	now := time.Now().UTC()
	_, err = db.Exec(`
		INSERT INTO rooms (id, name, emoji, created_by, public, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, LobbyRoomID, "Lobby", "🏠", "system", true, now, now)
	return err
}

// EnsureLobbyAgent adds a default agent to the lobby if not already present.
// Also backfills openclaw_agent_id on existing rows.
func (db *DB) EnsureLobbyAgent(agentID, openclawURL, openclawToken, openclawAgentID, agentName, agentEmoji string) error {
	if err := db.AddAgentParticipant(LobbyRoomID, agentID, openclawURL, openclawToken, openclawAgentID, agentName, agentEmoji); err != nil {
		return err
	}
	// Backfill openclaw_agent_id on existing rows that predate the column
	if openclawAgentID != "" {
		db.Exec(`UPDATE participants SET openclaw_agent_id = ? WHERE room_id = ? AND agent_id = ? AND openclaw_url = ? AND (openclaw_agent_id IS NULL OR openclaw_agent_id = '')`,
			openclawAgentID, LobbyRoomID, agentID, openclawURL)
	}
	return nil
}

func (db *DB) CreateRoom(name, emoji, createdBy string, public bool) (*Room, error) {
	id := nanoid()
	now := time.Now().UTC()
	_, err := db.Exec(`
		INSERT INTO rooms (id, name, emoji, created_by, public, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, id, name, emoji, createdBy, public, now, now)
	if err != nil {
		return nil, err
	}

	// Add creator as owner participant
	_, err = db.Exec(`
		INSERT INTO participants (room_id, user_id, role) VALUES (?, ?, 'owner')
	`, id, createdBy)
	if err != nil {
		return nil, err
	}

	return &Room{
		ID:        id,
		Name:      name,
		Emoji:     emoji,
		CreatedBy: createdBy,
		Public:    public,
		CreatedAt: now,
		UpdatedAt: now,
	}, nil
}

func (db *DB) GetRoom(id string) (*Room, error) {
	r := &Room{}
	err := db.QueryRow(`
		SELECT id, name, emoji, created_by, public, created_at, updated_at
		FROM rooms WHERE id = ?
	`, id).Scan(&r.ID, &r.Name, &r.Emoji, &r.CreatedBy, &r.Public, &r.CreatedAt, &r.UpdatedAt)
	if err != nil {
		return nil, err
	}

	// Load participants
	participants, err := db.GetParticipants(id)
	if err != nil {
		return nil, err
	}
	r.Participants = participants
	r.ParticipantCount = len(participants)

	// Load last message
	r.LastMessage, _ = db.getLastMessage(id)

	return r, nil
}

func (db *DB) ListRoomsForUser(userID string) ([]Room, error) {
	rows, err := db.Query(`
		SELECT r.id, r.name, r.emoji, r.created_by, r.public, r.created_at, r.updated_at,
		       (SELECT COUNT(*) FROM participants WHERE room_id = r.id) as participant_count
		FROM rooms r
		JOIN participants p ON p.room_id = r.id AND p.user_id = ?
		ORDER BY r.updated_at DESC
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var rooms []Room
	for rows.Next() {
		var r Room
		if err := rows.Scan(&r.ID, &r.Name, &r.Emoji, &r.CreatedBy, &r.Public, &r.CreatedAt, &r.UpdatedAt, &r.ParticipantCount); err != nil {
			continue
		}
		r.LastMessage, _ = db.getLastMessage(r.ID)
		rooms = append(rooms, r)
	}
	return rooms, nil
}

func (db *DB) ListPublicRooms() ([]Room, error) {
	rows, err := db.Query(`
		SELECT r.id, r.name, r.emoji, r.created_by, r.public, r.created_at, r.updated_at,
		       (SELECT COUNT(*) FROM participants WHERE room_id = r.id) as participant_count
		FROM rooms r
		WHERE r.public = 1
		ORDER BY r.updated_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var rooms []Room
	for rows.Next() {
		var r Room
		if err := rows.Scan(&r.ID, &r.Name, &r.Emoji, &r.CreatedBy, &r.Public, &r.CreatedAt, &r.UpdatedAt, &r.ParticipantCount); err != nil {
			continue
		}
		r.LastMessage, _ = db.getLastMessage(r.ID)
		rooms = append(rooms, r)
	}
	return rooms, nil
}

func (db *DB) IsRoomPublic(roomID string) (bool, error) {
	var public bool
	err := db.QueryRow(`SELECT public FROM rooms WHERE id = ?`, roomID).Scan(&public)
	return public, err
}

func (db *DB) getLastMessage(roomID string) (*LastMessage, error) {
	lm := &LastMessage{}
	err := db.QueryRow(`
		SELECT content, sender_display_name, sender_emoji, created_at
		FROM messages WHERE room_id = ? ORDER BY created_at DESC LIMIT 1
	`, roomID).Scan(&lm.Content, &lm.SenderName, &lm.SenderEmoji, &lm.CreatedAt)
	if err != nil {
		return nil, err
	}
	// Truncate content for preview
	if len(lm.Content) > 100 {
		lm.Content = lm.Content[:100] + "…"
	}
	return lm, nil
}

func (db *DB) AddParticipant(roomID, userID, role string) error {
	_, err := db.Exec(`
		INSERT OR IGNORE INTO participants (room_id, user_id, role) VALUES (?, ?, ?)
	`, roomID, userID, role)
	return err
}

func (db *DB) RemoveParticipant(roomID, userID string) error {
	_, err := db.Exec(`
		DELETE FROM participants WHERE room_id = ? AND user_id = ?
	`, roomID, userID)
	return err
}

func (db *DB) AddAgentParticipant(roomID, agentID, openclawURL, openclawToken, openclawAgentID, agentName, agentEmoji string) error {
	_, err := db.Exec(`
		INSERT OR IGNORE INTO participants (room_id, agent_id, openclaw_url, openclaw_token, openclaw_agent_id, agent_name, agent_emoji, role)
		VALUES (?, ?, ?, ?, ?, ?, ?, 'member')
	`, roomID, agentID, openclawURL, openclawToken, openclawAgentID, agentName, agentEmoji)
	return err
}

func (db *DB) RemoveAgentParticipant(roomID, agentID, openclawURL string) error {
	_, err := db.Exec(`
		DELETE FROM participants WHERE room_id = ? AND agent_id = ? AND openclaw_url = ?
	`, roomID, agentID, openclawURL)
	return err
}

func (db *DB) GetAgentParticipant(roomID, agentID, openclawURL string) (*Participant, error) {
	var p Participant
	var openclawToken string
	err := db.QueryRow(`
		SELECT agent_id, openclaw_url, openclaw_token, agent_name, COALESCE(agent_emoji, ''), role
		FROM participants
		WHERE room_id = ? AND agent_id = ? AND openclaw_url = ?
	`, roomID, agentID, openclawURL).Scan(&p.AgentID, &p.OpenclawURL, &openclawToken, &p.DisplayName, &p.Emoji, &p.Role)
	if err != nil {
		return nil, err
	}
	p.ID = "agent:" + agentID + "@" + openclawURL
	p.IsAgent = true
	return &p, nil
}

func (db *DB) GetParticipants(roomID string) ([]Participant, error) {
	rows, err := db.Query(`
		SELECT p.user_id, p.agent_id, p.openclaw_url, p.openclaw_token, p.openclaw_agent_id, p.agent_name, p.agent_emoji, p.role,
		       COALESCE(u.display_name, ''), COALESCE(u.avatar_emoji, '')
		FROM participants p
		LEFT JOIN users u ON u.id = p.user_id
		WHERE p.room_id = ?
	`, roomID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var participants []Participant
	for rows.Next() {
		var userID, agentID, openclawURL, openclawToken, openclawAgentID, agentName, agentEmoji, role, userName, userEmoji *string
		if err := rows.Scan(&userID, &agentID, &openclawURL, &openclawToken, &openclawAgentID, &agentName, &agentEmoji, &role, &userName, &userEmoji); err != nil {
			continue
		}

		p := Participant{Role: deref(role)}
		if agentID != nil && *agentID != "" {
			p.ID = "agent:" + *agentID + "@" + deref(openclawURL)
			p.DisplayName = deref(agentName)
			p.Emoji = deref(agentEmoji)
			p.IsAgent = true
			p.AgentID = *agentID
			p.OpenclawURL = deref(openclawURL)
			p.OpenclawToken = deref(openclawToken)
			p.OpenclawAgentID = deref(openclawAgentID)
		} else if userID != nil {
			p.ID = *userID
			p.DisplayName = deref(userName)
			p.Emoji = deref(userEmoji)
			p.IsAgent = false
		}
		participants = append(participants, p)
	}
	return participants, nil
}

func (db *DB) IsParticipant(roomID, userID string) (bool, error) {
	var count int
	err := db.QueryRow(`
		SELECT COUNT(*) FROM participants WHERE room_id = ? AND user_id = ?
	`, roomID, userID).Scan(&count)
	return count > 0, err
}

func (db *DB) GetParticipantRole(roomID, userID string) (string, error) {
	var role string
	err := db.QueryRow(`
		SELECT role FROM participants WHERE room_id = ? AND user_id = ?
	`, roomID, userID).Scan(&role)
	return role, err
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
