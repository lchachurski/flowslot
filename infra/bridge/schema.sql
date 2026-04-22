-- flowslot voice bridge — event store.
-- Claude Code hooks write here; the bridge HTTP server reads here to answer
-- "how's it going?" state queries from the ElevenLabs CAI agent.

CREATE TABLE IF NOT EXISTS events (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  ts       INTEGER NOT NULL,       -- unix epoch seconds
  type     TEXT    NOT NULL,       -- pre_tool | post_tool | stop | notification
  tool     TEXT,                    -- tool name, for pre_tool/post_tool
  args     TEXT,                    -- JSON, tool inputs
  result   TEXT,                    -- JSON, tool outputs (post_tool only)
  message  TEXT,                    -- text, for notification events
  session_id TEXT                  -- claude session id, when available
);

CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_type_ts ON events(type, ts DESC);

-- Scratch space for bridge-local state: last_stop_at, active_slot, etc.
CREATE TABLE IF NOT EXISTS bridge_state (
  key   TEXT PRIMARY KEY,
  value TEXT
);
