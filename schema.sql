-- SQLite schema for My Notes. Safe to run repeatedly (server.ps1 runs it at start-up).
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS notes (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  title   TEXT    NOT NULL DEFAULT '',
  html    TEXT    NOT NULL DEFAULT '',   -- sanitized rich text
  text    TEXT    NOT NULL DEFAULT '',   -- plain text of html, used for search snippets
  nb      INTEGER NOT NULL DEFAULT 1,    -- notebook id (notebooks live in meta)
  pinned  INTEGER NOT NULL DEFAULT 0,
  trashed INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL,              -- ms since epoch
  updated INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated);
CREATE INDEX IF NOT EXISTS idx_notes_created ON notes(created);
CREATE INDEX IF NOT EXISTS idx_notes_title   ON notes(title COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_notes_nb      ON notes(nb);

CREATE TABLE IF NOT EXISTS note_tags (
  note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  tag     TEXT    NOT NULL COLLATE NOCASE,
  PRIMARY KEY (note_id, tag)
);
CREATE INDEX IF NOT EXISTS idx_tags_tag ON note_tags(tag);

CREATE TABLE IF NOT EXISTS attachments (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  name    TEXT, type TEXT, size INTEGER,
  data    TEXT                           -- data: URL
);
CREATE INDEX IF NOT EXISTS idx_att_note ON attachments(note_id);

-- small JSON documents: notebooks, tasks, templates, nextId, legacyDone
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

-- full-text index, rowid = notes.id; maintained by the server on every note write
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(title, text, tags, tokenize='unicode61 remove_diacritics 2');
