package db

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

const schema = `
CREATE TABLE IF NOT EXISTS admin_auth (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	salt BLOB NOT NULL,
	hash BLOB NOT NULL,
	created_at DATETIME NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
	token TEXT PRIMARY KEY,
	created_at DATETIME NOT NULL,
	expires_at DATETIME NOT NULL
);

CREATE TABLE IF NOT EXISTS upload_links (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	token TEXT UNIQUE NOT NULL,
	title TEXT NOT NULL,
	created_at DATETIME NOT NULL,
	expires_at DATETIME,
	max_files INTEGER,
	max_size_bytes INTEGER,
	disable_after_first_upload INTEGER NOT NULL DEFAULT 0,
	password_salt BLOB,
	password_hash BLOB,
	active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS uploads (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	link_id INTEGER NOT NULL REFERENCES upload_links(id) ON DELETE CASCADE,
	filename TEXT NOT NULL,
	relative_path TEXT NOT NULL,
	size INTEGER NOT NULL,
	mime TEXT,
	uploaded_at DATETIME NOT NULL,
	storage_path TEXT NOT NULL,
	thumbnail_status TEXT NOT NULL DEFAULT 'none'
);

CREATE INDEX IF NOT EXISTS idx_uploads_link_id ON uploads(link_id);
`

func Open(path string) (*sql.DB, error) {
	dsn := fmt.Sprintf("file:%s?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)", path)
	sqlDB, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	sqlDB.SetMaxOpenConns(1)

	if _, err := sqlDB.Exec(schema); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("applying schema: %w", err)
	}
	return sqlDB, nil
}
