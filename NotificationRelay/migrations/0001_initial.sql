PRAGMA foreign_keys = ON;

CREATE TABLE installations (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  apns_token_ciphertext TEXT NOT NULL,
  apns_environment TEXT NOT NULL CHECK (apns_environment IN ('sandbox', 'production')),
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE channels (
  id TEXT PRIMARY KEY,
  installation_id TEXT NOT NULL REFERENCES installations(id) ON DELETE CASCADE,
  app_id TEXT NOT NULL,
  app_name TEXT,
  secret_ciphertext TEXT NOT NULL,
  apple_webhook_id TEXT,
  event_types_json TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(installation_id, app_id)
);

CREATE TABLE events (
  event_id TEXT NOT NULL,
  installation_id TEXT NOT NULL REFERENCES installations(id) ON DELETE CASCADE,
  channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  instance_id TEXT,
  old_state TEXT,
  new_state TEXT,
  authoritative_timestamp TEXT,
  received_at TEXT NOT NULL,
  enqueued INTEGER NOT NULL DEFAULT 0,
  enqueue_attempted_at TEXT,
  PRIMARY KEY(channel_id, event_id)
);

CREATE INDEX channels_installation_idx ON channels(installation_id);
CREATE INDEX events_installation_received_idx ON events(installation_id, received_at DESC);
CREATE INDEX events_pending_idx ON events(enqueued, received_at);
