-- Pacenote telemetry (0.9.4, rules/usage.yaml > telemetry). One row per batch an install chose to send.
-- No IP address, no user agent, no names or call text: the app sends only event names and small numbers.
CREATE TABLE IF NOT EXISTS batches (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  received_at TEXT NOT NULL,          -- UTC day and hour only
  install TEXT NOT NULL,              -- random id of one install (made on that Mac at opt-in), not linked to a person
  app_version TEXT, rules_version TEXT, ui_lang TEXT,
  period_from TEXT, period_to TEXT,   -- days
  events INTEGER NOT NULL,
  payload TEXT NOT NULL               -- the batch as sent (JSON)
);
CREATE INDEX IF NOT EXISTS batches_install ON batches(install, received_at);
CREATE TABLE IF NOT EXISTS event_counts (  -- the same data summed for a quick look in the D1 console
  day TEXT NOT NULL, event TEXT NOT NULL, params TEXT NOT NULL, app_version TEXT NOT NULL, n INTEGER NOT NULL,
  PRIMARY KEY (day, event, params, app_version)
);
