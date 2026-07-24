// Package links manages upload links: creation, listing with stats, and the
// per-link security rules (expiry, upload/size caps, optional password).
package links

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"time"

	"uploadportal/internal/auth"
)

const tokenAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

var ErrNotFound = errors.New("link not found")

type Link struct {
	ID                      int64
	Token                   string
	Title                   string
	CreatedAt               time.Time
	ExpiresAt               *time.Time
	MaxFiles                *int64
	MaxSizeBytes            *int64
	DisableAfterFirstUpload bool
	HasPassword             bool
	PasswordSalt            []byte
	PasswordHash            []byte
	Active                  bool
}

type Stats struct {
	Link
	UploadCount int64
	TotalSize   int64
}

// GenerateToken returns a random 12-character token suitable for a public URL.
func GenerateToken() (string, error) {
	const length = 12
	buf := make([]byte, length)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	out := make([]byte, length)
	for i, b := range buf {
		out[i] = tokenAlphabet[int(b)%len(tokenAlphabet)]
	}
	return string(out), nil
}

func nullTime(t *time.Time) sql.NullTime {
	if t == nil {
		return sql.NullTime{}
	}
	return sql.NullTime{Time: *t, Valid: true}
}

func nullInt64(v *int64) sql.NullInt64 {
	if v == nil {
		return sql.NullInt64{}
	}
	return sql.NullInt64{Int64: *v, Valid: true}
}

type CreateParams struct {
	Title                   string
	ExpiresAt               *time.Time
	MaxFiles                *int64
	MaxSizeBytes            *int64
	DisableAfterFirstUpload bool
	Password                string // empty = no password
}

func Create(db *sql.DB, p CreateParams) (*Link, error) {
	token, err := GenerateToken()
	if err != nil {
		return nil, err
	}

	var salt, hash []byte
	if p.Password != "" {
		salt, hash, err = auth.HashSecret(p.Password)
		if err != nil {
			return nil, err
		}
	}

	now := time.Now().UTC()
	res, err := db.Exec(
		`INSERT INTO upload_links
			(token, title, created_at, expires_at, max_files, max_size_bytes, disable_after_first_upload, password_salt, password_hash, active)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)`,
		token, p.Title, now, nullTime(p.ExpiresAt), nullInt64(p.MaxFiles), nullInt64(p.MaxSizeBytes), p.DisableAfterFirstUpload, salt, hash,
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

func scanLink(row interface {
	Scan(dest ...any) error
}) (*Link, error) {
	var l Link
	var expiresAt sql.NullTime
	var maxFiles, maxSizeBytes sql.NullInt64
	var passwordSalt, passwordHash []byte
	var disableAfterFirstUpload, active int
	err := row.Scan(
		&l.ID, &l.Token, &l.Title, &l.CreatedAt, &expiresAt, &maxFiles, &maxSizeBytes,
		&disableAfterFirstUpload, &passwordSalt, &passwordHash, &active,
	)
	if err != nil {
		return nil, err
	}
	if expiresAt.Valid {
		l.ExpiresAt = &expiresAt.Time
	}
	if maxFiles.Valid {
		l.MaxFiles = &maxFiles.Int64
	}
	if maxSizeBytes.Valid {
		l.MaxSizeBytes = &maxSizeBytes.Int64
	}
	l.DisableAfterFirstUpload = disableAfterFirstUpload != 0
	l.Active = active != 0
	l.PasswordSalt = passwordSalt
	l.PasswordHash = passwordHash
	l.HasPassword = len(passwordHash) > 0
	return &l, nil
}

const selectCols = `id, token, title, created_at, expires_at, max_files, max_size_bytes, disable_after_first_upload, password_salt, password_hash, active`

func GetByID(db *sql.DB, id int64) (*Link, error) {
	row := db.QueryRow(`SELECT `+selectCols+` FROM upload_links WHERE id = ?`, id)
	l, err := scanLink(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return l, err
}

func GetByToken(db *sql.DB, token string) (*Link, error) {
	row := db.QueryRow(`SELECT `+selectCols+` FROM upload_links WHERE token = ?`, token)
	l, err := scanLink(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return l, err
}

func List(db *sql.DB) ([]Stats, error) {
	rows, err := db.Query(`
		SELECT l.id, l.token, l.title, l.created_at, l.expires_at, l.max_files, l.max_size_bytes,
			l.disable_after_first_upload, l.password_salt, l.password_hash, l.active,
			COALESCE(COUNT(u.id), 0), COALESCE(SUM(u.size), 0)
		FROM upload_links l
		LEFT JOIN uploads u ON u.link_id = l.id
		GROUP BY l.id
		ORDER BY l.created_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Stats
	for rows.Next() {
		var l Link
		var expiresAt sql.NullTime
		var maxFiles, maxSizeBytes sql.NullInt64
		var passwordSalt, passwordHash []byte
		var disableAfterFirstUpload, active int
		var uploadCount, totalSize int64
		err := rows.Scan(
			&l.ID, &l.Token, &l.Title, &l.CreatedAt, &expiresAt, &maxFiles, &maxSizeBytes,
			&disableAfterFirstUpload, &passwordSalt, &passwordHash, &active,
			&uploadCount, &totalSize,
		)
		if err != nil {
			return nil, err
		}
		if expiresAt.Valid {
			l.ExpiresAt = &expiresAt.Time
		}
		if maxFiles.Valid {
			l.MaxFiles = &maxFiles.Int64
		}
		if maxSizeBytes.Valid {
			l.MaxSizeBytes = &maxSizeBytes.Int64
		}
		l.DisableAfterFirstUpload = disableAfterFirstUpload != 0
		l.Active = active != 0
		l.HasPassword = len(passwordHash) > 0
		out = append(out, Stats{Link: l, UploadCount: uploadCount, TotalSize: totalSize})
	}
	return out, rows.Err()
}

func SetActive(db *sql.DB, id int64, active bool) error {
	res, err := db.Exec(`UPDATE upload_links SET active = ? WHERE id = ?`, active, id)
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

// DisableAfterUpload marks a link inactive; used when
// disable_after_first_upload fires following a successful upload.
func DisableAfterUpload(db *sql.DB, id int64) error {
	_, err := db.Exec(`UPDATE upload_links SET active = 0 WHERE id = ?`, id)
	return err
}

func Delete(db *sql.DB, id int64) error {
	res, err := db.Exec(`DELETE FROM upload_links WHERE id = ?`, id)
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

// State describes why a link is or isn't currently accepting uploads.
type State struct {
	Active           bool
	Expired          bool
	FilesRemaining   *int64 // nil = unlimited
	BytesRemaining   *int64 // nil = unlimited
	RequiresPassword bool
}

func (l *Link) EvaluateState(uploadCount, totalSize int64) State {
	s := State{Active: l.Active, RequiresPassword: l.HasPassword}
	if l.ExpiresAt != nil && time.Now().UTC().After(*l.ExpiresAt) {
		s.Expired = true
	}
	if l.MaxFiles != nil {
		remaining := *l.MaxFiles - uploadCount
		s.FilesRemaining = &remaining
	}
	if l.MaxSizeBytes != nil {
		remaining := *l.MaxSizeBytes - totalSize
		s.BytesRemaining = &remaining
	}
	return s
}

// CanAcceptUpload reports whether the link can currently take one more file
// of the given size, given its current upload count/total size.
func (s State) CanAcceptUpload(fileSize int64) (bool, string) {
	if !s.Active {
		return false, "this link is no longer active"
	}
	if s.Expired {
		return false, "this link has expired"
	}
	if s.FilesRemaining != nil && *s.FilesRemaining <= 0 {
		return false, "this link has reached its file limit"
	}
	if s.BytesRemaining != nil && fileSize > *s.BytesRemaining {
		return false, "this upload would exceed the link's size limit"
	}
	return true, ""
}
