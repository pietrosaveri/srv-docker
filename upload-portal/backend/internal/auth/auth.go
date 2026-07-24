// Package auth implements the single-admin password flow: first-run setup,
// PBKDF2-HMAC-SHA256 password hashing, cookie-backed sessions and a per-IP
// login rate limiter.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"errors"
	"net/http"
	"sync"
	"time"

	"golang.org/x/crypto/pbkdf2"
)

const (
	pbkdf2Iterations = 210_000
	pbkdf2KeyLen     = 32
	saltLen          = 16
	sessionTokenLen  = 32
	sessionTTL       = 30 * 24 * time.Hour
	CookieName       = "session"
)

var ErrAlreadySetUp = errors.New("admin password already set")
var ErrNotSetUp = errors.New("admin password not set")
var ErrWrongPassword = errors.New("wrong password")

type Service struct {
	db *sql.DB

	mu       sync.Mutex
	attempts map[string][]time.Time
}

func New(db *sql.DB) *Service {
	return &Service{db: db, attempts: make(map[string][]time.Time)}
}

func hashPassword(password string, salt []byte) []byte {
	return pbkdf2.Key([]byte(password), salt, pbkdf2Iterations, pbkdf2KeyLen, sha256.New)
}

// HashSecret salts and hashes an arbitrary secret (e.g. a per-link password)
// using the same PBKDF2-HMAC-SHA256 scheme as the admin password.
func HashSecret(secret string) (salt, hash []byte, err error) {
	salt, err = randomBytes(saltLen)
	if err != nil {
		return nil, nil, err
	}
	return salt, hashPassword(secret, salt), nil
}

// VerifySecret checks a candidate secret against a stored salt+hash pair.
func VerifySecret(secret string, salt, hash []byte) bool {
	if len(salt) == 0 || len(hash) == 0 {
		return false
	}
	return subtle.ConstantTimeCompare(hashPassword(secret, salt), hash) == 1
}

func randomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	return b, nil
}

// IsSetUp reports whether an admin password has already been configured.
func (s *Service) IsSetUp() (bool, error) {
	var id int
	err := s.db.QueryRow(`SELECT id FROM admin_auth WHERE id = 1`).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

// Setup stores the admin password. Fails if a password already exists.
func (s *Service) Setup(password string) error {
	setUp, err := s.IsSetUp()
	if err != nil {
		return err
	}
	if setUp {
		return ErrAlreadySetUp
	}
	salt, err := randomBytes(saltLen)
	if err != nil {
		return err
	}
	hash := hashPassword(password, salt)
	_, err = s.db.Exec(
		`INSERT INTO admin_auth (id, salt, hash, created_at) VALUES (1, ?, ?, ?)`,
		salt, hash, time.Now().UTC(),
	)
	return err
}

// checkRateLimit allows at most 5 attempts per IP per minute.
func (s *Service) checkRateLimit(ip string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-time.Minute)

	kept := s.attempts[ip][:0]
	for _, t := range s.attempts[ip] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	s.attempts[ip] = kept

	if len(s.attempts[ip]) >= 5 {
		return false
	}
	s.attempts[ip] = append(s.attempts[ip], now)
	return true
}

// Login verifies the password and, on success, creates a new session and
// returns its token. Returns an error if the IP is rate limited or the
// password is wrong.
func (s *Service) Login(ip, password string) (string, error) {
	if !s.checkRateLimit(ip) {
		return "", errors.New("too many login attempts, try again in a minute")
	}

	var salt, hash []byte
	err := s.db.QueryRow(`SELECT salt, hash FROM admin_auth WHERE id = 1`).Scan(&salt, &hash)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotSetUp
	}
	if err != nil {
		return "", err
	}

	candidate := hashPassword(password, salt)
	if subtle.ConstantTimeCompare(candidate, hash) != 1 {
		return "", ErrWrongPassword
	}

	tokenBytes, err := randomBytes(sessionTokenLen)
	if err != nil {
		return "", err
	}
	token := hex.EncodeToString(tokenBytes)
	now := time.Now().UTC()
	_, err = s.db.Exec(
		`INSERT INTO sessions (token, created_at, expires_at) VALUES (?, ?, ?)`,
		token, now, now.Add(sessionTTL),
	)
	if err != nil {
		return "", err
	}
	return token, nil
}

func (s *Service) Logout(token string) error {
	_, err := s.db.Exec(`DELETE FROM sessions WHERE token = ?`, token)
	return err
}

func (s *Service) isValidSession(token string) bool {
	if token == "" {
		return false
	}
	var expiresAt time.Time
	err := s.db.QueryRow(`SELECT expires_at FROM sessions WHERE token = ?`, token).Scan(&expiresAt)
	if err != nil {
		return false
	}
	return time.Now().UTC().Before(expiresAt)
}

func SetSessionCookie(w http.ResponseWriter, token string) {
	http.SetCookie(w, &http.Cookie{
		Name:     CookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(sessionTTL.Seconds()),
	})
}

func ClearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     CookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   -1,
	})
}

// IsAuthenticated reports whether the request carries a valid session cookie.
func (s *Service) IsAuthenticated(r *http.Request) bool {
	cookie, err := r.Cookie(CookieName)
	if err != nil {
		return false
	}
	return s.isValidSession(cookie.Value)
}

// RequireAdmin is middleware that rejects requests without a valid session.
func (s *Service) RequireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.IsAuthenticated(r) {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}
