CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,           -- SHA256(public_key) hex
    public_key TEXT NOT NULL,      -- base64url-encoded Ed25519 public key
    display_name TEXT NOT NULL DEFAULT '',
    avatar_emoji TEXT NOT NULL DEFAULT '',
    created_at DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS rooms (
    id TEXT PRIMARY KEY,           -- nanoid
    name TEXT NOT NULL,
    emoji TEXT NOT NULL DEFAULT '',
    created_by TEXT NOT NULL REFERENCES users(id),
    public BOOLEAN NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS participants (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    room_id TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    -- For humans: user_id is set, agent fields are NULL
    user_id TEXT REFERENCES users(id),
    -- For agents: agent fields are set, user_id is NULL
    agent_id TEXT,
    openclaw_url TEXT,
    openclaw_token TEXT,
    openclaw_agent_id TEXT,    -- agent ID on the OpenClaw server (may differ from agent_id)
    agent_name TEXT,
    agent_emoji TEXT,
    role TEXT NOT NULL DEFAULT 'member',  -- owner, admin, member
    joined_at DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE(room_id, user_id),
    UNIQUE(room_id, agent_id, openclaw_url)
);

CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,           -- nanoid
    room_id TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    sender_user_id TEXT REFERENCES users(id),
    sender_agent_id TEXT,
    sender_display_name TEXT NOT NULL,
    sender_emoji TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL,
    mentions TEXT NOT NULL DEFAULT '[]',   -- JSON array of participant IDs
    reply_to TEXT,                          -- message id
    created_at DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_messages_room_created ON messages(room_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_participants_room ON participants(room_id);
CREATE INDEX IF NOT EXISTS idx_participants_user ON participants(user_id);

CREATE TABLE IF NOT EXISTS push_tokens (
    device_id TEXT NOT NULL,
    token     TEXT NOT NULL,
    bundle_id TEXT NOT NULL DEFAULT 'com.kochito.claudio',
    platform  TEXT NOT NULL DEFAULT 'ios',
    updated_at DATETIME NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (device_id, bundle_id)
);

CREATE TABLE IF NOT EXISTS push_watches (
    device_id    TEXT PRIMARY KEY,
    openclaw_url TEXT NOT NULL,
    openclaw_token TEXT NOT NULL,
    updated_at   DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS invite_codes (
    code TEXT PRIMARY KEY,         -- 8-char alphanumeric
    room_id TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    created_by TEXT NOT NULL REFERENCES users(id),
    expires_at DATETIME,
    max_uses INTEGER NOT NULL DEFAULT 0,   -- 0 = unlimited
    use_count INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT (datetime('now'))
);
