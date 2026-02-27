package db

import "time"

type Message struct {
	ID              string    `json:"id"`
	RoomID          string    `json:"roomId"`
	SenderUserID    *string   `json:"senderUserId,omitempty"`
	SenderAgentID   *string   `json:"senderAgentId,omitempty"`
	SenderDisplayName string  `json:"senderDisplayName"`
	SenderEmoji     string    `json:"senderEmoji"`
	Content         string    `json:"content"`
	Mentions        string    `json:"mentions"`  // JSON array
	ReplyTo         *string   `json:"replyTo,omitempty"`
	CreatedAt       time.Time `json:"createdAt"`
}

func (db *DB) InsertMessage(id, roomID string, senderUserID, senderAgentID *string, senderDisplayName, senderEmoji, content, mentions string, replyTo *string) (*Message, error) {
	now := time.Now().UTC()
	_, err := db.Exec(`
		INSERT INTO messages (id, room_id, sender_user_id, sender_agent_id, sender_display_name, sender_emoji, content, mentions, reply_to, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, id, roomID, senderUserID, senderAgentID, senderDisplayName, senderEmoji, content, mentions, replyTo, now)
	if err != nil {
		return nil, err
	}

	// Update room updated_at
	db.Exec("UPDATE rooms SET updated_at = ? WHERE id = ?", now, roomID)

	return &Message{
		ID:                id,
		RoomID:            roomID,
		SenderUserID:      senderUserID,
		SenderAgentID:     senderAgentID,
		SenderDisplayName: senderDisplayName,
		SenderEmoji:       senderEmoji,
		Content:           content,
		Mentions:          mentions,
		ReplyTo:           replyTo,
		CreatedAt:         now,
	}, nil
}

func (db *DB) GetMessages(roomID string, before *time.Time, limit int) ([]Message, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}

	var rows interface{ Scan(...any) error }
	var query string
	var args []any

	if before != nil {
		query = `
			SELECT id, room_id, sender_user_id, sender_agent_id, sender_display_name, sender_emoji, content, mentions, reply_to, created_at
			FROM messages WHERE room_id = ? AND created_at < ?
			ORDER BY created_at DESC LIMIT ?
		`
		args = []any{roomID, *before, limit}
	} else {
		query = `
			SELECT id, room_id, sender_user_id, sender_agent_id, sender_display_name, sender_emoji, content, mentions, reply_to, created_at
			FROM messages WHERE room_id = ?
			ORDER BY created_at DESC LIMIT ?
		`
		args = []any{roomID, limit}
	}

	_ = rows // unused, using db.Query instead
	dbRows, err := db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer dbRows.Close()

	var messages []Message
	for dbRows.Next() {
		var m Message
		if err := dbRows.Scan(&m.ID, &m.RoomID, &m.SenderUserID, &m.SenderAgentID, &m.SenderDisplayName, &m.SenderEmoji, &m.Content, &m.Mentions, &m.ReplyTo, &m.CreatedAt); err != nil {
			continue
		}
		messages = append(messages, m)
	}

	// Reverse to chronological order
	for i, j := 0, len(messages)-1; i < j; i, j = i+1, j-1 {
		messages[i], messages[j] = messages[j], messages[i]
	}
	return messages, nil
}
