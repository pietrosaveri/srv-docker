package uploads

import (
	"database/sql"
	"errors"
	"time"
)

var ErrNotFound = errors.New("upload not found")

const (
	ThumbnailNone        = "none"
	ThumbnailPending     = "pending"
	ThumbnailReady       = "ready"
	ThumbnailFailed      = "failed"
	ThumbnailUnsupported = "unsupported"
)

type Upload struct {
	ID              int64
	LinkID          int64
	Filename        string
	RelativePath    string
	Size            int64
	Mime            string
	UploadedAt      time.Time
	StoragePath     string
	ThumbnailStatus string
}

func Insert(db *sql.DB, linkID int64, filename, relativePath string, size int64, mimeType, storagePath, thumbnailStatus string) (*Upload, error) {
	now := time.Now().UTC()
	res, err := db.Exec(
		`INSERT INTO uploads (link_id, filename, relative_path, size, mime, uploaded_at, storage_path, thumbnail_status)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		linkID, filename, relativePath, size, mimeType, now, storagePath, thumbnailStatus,
	)
	if err != nil {
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return GetByID(db, id)
}

const selectCols = `id, link_id, filename, relative_path, size, mime, uploaded_at, storage_path, thumbnail_status`

func scan(row interface{ Scan(dest ...any) error }) (*Upload, error) {
	var u Upload
	err := row.Scan(&u.ID, &u.LinkID, &u.Filename, &u.RelativePath, &u.Size, &u.Mime, &u.UploadedAt, &u.StoragePath, &u.ThumbnailStatus)
	if err != nil {
		return nil, err
	}
	return &u, nil
}

func GetByID(db *sql.DB, id int64) (*Upload, error) {
	row := db.QueryRow(`SELECT `+selectCols+` FROM uploads WHERE id = ?`, id)
	u, err := scan(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return u, err
}

func ListByLink(db *sql.DB, linkID int64) ([]Upload, error) {
	rows, err := db.Query(`SELECT `+selectCols+` FROM uploads WHERE link_id = ? ORDER BY uploaded_at ASC`, linkID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return collect(rows)
}

// ListRecent returns uploads across all links (linkID == nil) or scoped to
// one link, newest first.
func ListRecent(db *sql.DB, linkID *int64, limit, offset int) ([]Upload, error) {
	var rows *sql.Rows
	var err error
	if linkID != nil {
		rows, err = db.Query(
			`SELECT `+selectCols+` FROM uploads WHERE link_id = ? ORDER BY uploaded_at DESC LIMIT ? OFFSET ?`,
			*linkID, limit, offset,
		)
	} else {
		rows, err = db.Query(
			`SELECT `+selectCols+` FROM uploads ORDER BY uploaded_at DESC LIMIT ? OFFSET ?`,
			limit, offset,
		)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return collect(rows)
}

func collect(rows *sql.Rows) ([]Upload, error) {
	var out []Upload
	for rows.Next() {
		u, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *u)
	}
	return out, rows.Err()
}

// Stats returns the current upload count and total byte size for a link.
func Stats(db *sql.DB, linkID int64) (count int64, totalSize int64, err error) {
	err = db.QueryRow(
		`SELECT COUNT(*), COALESCE(SUM(size), 0) FROM uploads WHERE link_id = ?`, linkID,
	).Scan(&count, &totalSize)
	return
}

func Delete(db *sql.DB, id int64) error {
	res, err := db.Exec(`DELETE FROM uploads WHERE id = ?`, id)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func SetThumbnailStatus(db *sql.DB, id int64, status string) error {
	_, err := db.Exec(`UPDATE uploads SET thumbnail_status = ? WHERE id = ?`, status, id)
	return err
}
