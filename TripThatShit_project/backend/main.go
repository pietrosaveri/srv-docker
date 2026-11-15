// TripThatShit sync server: shared trips, legs and files for the iOS app.
//
// Users have no password: a phone gets a random token when it registers (with the
// server key) or joins a trip (with an invite code). Every trip endpoint checks that
// the caller is a member of that trip.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maxItemBytes = 1 << 20   // one leg or stay as JSON
	maxTripBytes = 16 << 20  // a whole trip on first share
	maxFileBytes = 100 << 20 // one attachment
	inviteTTL    = 14 * 24 * time.Hour
)

var (
	reUUID = regexp.MustCompile(`^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$`)
	reFile = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}(\.[A-Za-z0-9]{1,10})?$`)
)

type server struct {
	store   *Store
	appKey  string
	limiter *limiter
}

func main() {
	dataDir := envOr("DATA_DIR", "/data")
	addr := envOr("LISTEN_ADDR", ":8080")
	appKey := os.Getenv("TRIP_APP_KEY")
	if len(appKey) < 12 {
		log.Fatal("TRIP_APP_KEY must be set (at least 12 characters)")
	}
	store, err := openStore(dataDir)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	s := &server{store: store, appKey: appKey, limiter: newLimiter(20, time.Hour)}

	httpServer := &http.Server{
		Addr:              addr,
		Handler:           s.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       10 * time.Minute, // slow uploads on roaming data
		WriteTimeout:      10 * time.Minute,
		IdleTimeout:       2 * time.Minute,
	}
	go func() {
		log.Printf("listening on %s, data in %s", addr, dataDir)
		if err := httpServer.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(ctx)
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") })

	mux.HandleFunc("POST /api/register", s.register)
	mux.HandleFunc("POST /api/join", s.join)
	mux.HandleFunc("GET /api/me", s.auth(s.me))
	mux.HandleFunc("PATCH /api/me", s.auth(s.renameMe))

	mux.HandleFunc("PUT /api/trips/{trip}", s.auth(s.createTrip))
	mux.HandleFunc("GET /api/trips/{trip}", s.member(s.getTrip))
	mux.HandleFunc("PATCH /api/trips/{trip}", s.member(s.patchTrip))
	mux.HandleFunc("PUT /api/trips/{trip}/legs/{item}", s.member(s.putItem("legs")))
	mux.HandleFunc("DELETE /api/trips/{trip}/legs/{item}", s.member(s.deleteItem("legs")))
	mux.HandleFunc("PUT /api/trips/{trip}/stays/{item}", s.member(s.putItem("stays")))
	mux.HandleFunc("DELETE /api/trips/{trip}/stays/{item}", s.member(s.deleteItem("stays")))
	mux.HandleFunc("PUT /api/trips/{trip}/files/{name}", s.member(s.putFile))
	mux.HandleFunc("GET /api/trips/{trip}/files/{name}", s.member(s.getFile))
	mux.HandleFunc("POST /api/trips/{trip}/invites", s.member(s.createInvite))
	mux.HandleFunc("DELETE /api/trips/{trip}/members/me", s.member(s.leave))

	mux.HandleFunc("GET /join/{code}", s.joinPage)
	return logRequests(mux)
}

// ---------------------------------------------------------------- auth

type userKey struct{}

func currentUser(r *http.Request) *User { return r.Context().Value(userKey{}).(*User) }

func (s *server) userFromHeader(r *http.Request) *User {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || token == "" {
		return nil
	}
	return s.store.UserByToken(token)
}

func (s *server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u := s.userFromHeader(r)
		if u == nil {
			httpError(w, http.StatusUnauthorized, "login required")
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), userKey{}, u)))
	}
}

// member also checks the {trip} path value and that the caller belongs to that trip.
func (s *server) member(next http.HandlerFunc) http.HandlerFunc {
	return s.auth(func(w http.ResponseWriter, r *http.Request) {
		id := strings.ToUpper(r.PathValue("trip"))
		if !reUUID.MatchString(id) {
			httpError(w, http.StatusBadRequest, "bad trip id")
			return
		}
		ok, err := s.store.IsMember(id, currentUser(r).ID)
		if errors.Is(err, errNotFound) {
			httpError(w, http.StatusNotFound, "trip not found")
			return
		}
		if !ok {
			httpError(w, http.StatusForbidden, "not a member of this trip")
			return
		}
		r.SetPathValue("trip", id)
		next(w, r)
	})
}

// ---------------------------------------------------------------- users

type sessionResponse struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Token string `json:"token,omitempty"`
}

func (s *server) register(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if s.limiter.blocked(ip) {
		httpError(w, http.StatusTooManyRequests, "too many attempts, try again later")
		return
	}
	var body struct{ Name, Key string }
	if !readBody(w, r, &body, 4096) {
		return
	}
	if subtle.ConstantTimeCompare([]byte(body.Key), []byte(s.appKey)) != 1 {
		s.limiter.fail(ip)
		httpError(w, http.StatusForbidden, "wrong server key")
		return
	}
	name, ok := cleanName(body.Name)
	if !ok {
		httpError(w, http.StatusBadRequest, "name required")
		return
	}
	u, token, err := s.store.CreateUser(name)
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, sessionResponse{u.ID, u.Name, token})
}

func (s *server) me(w http.ResponseWriter, r *http.Request) {
	u := currentUser(r)
	writeJSON(w, http.StatusOK, map[string]any{"id": u.ID, "name": u.Name, "trips": s.store.TripsOf(u.ID)})
}

func (s *server) renameMe(w http.ResponseWriter, r *http.Request) {
	var body struct{ Name string }
	if !readBody(w, r, &body, 4096) {
		return
	}
	name, ok := cleanName(body.Name)
	if !ok {
		httpError(w, http.StatusBadRequest, "name required")
		return
	}
	u := currentUser(r)
	if err := s.store.RenameUser(u.ID, name); err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sessionResponse{ID: u.ID, Name: name})
}

// ---------------------------------------------------------------- trips

func (s *server) createTrip(w http.ResponseWriter, r *http.Request) {
	id := strings.ToUpper(r.PathValue("trip"))
	if !reUUID.MatchString(id) {
		httpError(w, http.StatusBadRequest, "bad trip id")
		return
	}
	var body struct {
		Title string            `json:"title"`
		Legs  []json.RawMessage `json:"legs"`
		Stays []json.RawMessage `json:"stays"`
	}
	if !readBody(w, r, &body, maxTripBytes) {
		return
	}
	byID := func(list []json.RawMessage) (map[string]json.RawMessage, bool) {
		m := map[string]json.RawMessage{}
		for _, raw := range list {
			itemID, ok := itemIDOf(raw)
			if !ok {
				return nil, false
			}
			m[itemID] = raw
		}
		return m, true
	}
	legs, okLegs := byID(body.Legs)
	stays, okStays := byID(body.Stays)
	if !okLegs || !okStays {
		httpError(w, http.StatusBadRequest, "every leg and stay needs an id")
		return
	}
	view, err := s.store.CreateTrip(id, currentUser(r).ID, cleanTitle(body.Title), legs, stays)
	if errors.Is(err, errExists) {
		httpError(w, http.StatusConflict, "trip already shared")
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, view)
}

func (s *server) getTrip(w http.ResponseWriter, r *http.Request) {
	view, err := s.store.Trip(r.PathValue("trip"))
	if err != nil {
		storeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s *server) patchTrip(w http.ResponseWriter, r *http.Request) {
	var body struct{ Title string }
	if !readBody(w, r, &body, 4096) {
		return
	}
	v, err := s.store.SetTitle(r.PathValue("trip"), cleanTitle(body.Title))
	if err != nil {
		storeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int64{"version": v})
}

// putItem stores one leg or stay (kind "legs" or "stays") as the app sent it.
func (s *server) putItem(kind string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		itemID := strings.ToUpper(r.PathValue("item"))
		var raw json.RawMessage
		if !readBody(w, r, &raw, maxItemBytes) {
			return
		}
		if id, ok := itemIDOf(raw); !ok || id != itemID {
			httpError(w, http.StatusBadRequest, "id does not match the URL")
			return
		}
		v, err := s.store.PutItem(r.PathValue("trip"), kind, itemID, raw)
		if err != nil {
			storeError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]int64{"version": v})
	}
}

func (s *server) deleteItem(kind string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		v, err := s.store.DeleteItem(r.PathValue("trip"), kind, strings.ToUpper(r.PathValue("item")))
		if err != nil {
			storeError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]int64{"version": v})
	}
}

func (s *server) leave(w http.ResponseWriter, r *http.Request) {
	if err := s.store.Leave(r.PathValue("trip"), currentUser(r).ID); err != nil {
		storeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------------------------------------------------------------- files

func (s *server) putFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !reFile.MatchString(name) {
		httpError(w, http.StatusBadRequest, "bad file name")
		return
	}
	path := s.store.FilePath(r.PathValue("trip"), name)
	tmp, err := os.CreateTemp(s.store.filesDir(r.PathValue("trip")), ".upload-*")
	if err != nil {
		serverError(w, err)
		return
	}
	defer os.Remove(tmp.Name())
	_, err = io.Copy(tmp, http.MaxBytesReader(w, r.Body, maxFileBytes))
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			httpError(w, http.StatusRequestEntityTooLarge, "file too large (max 100 MB)")
			return
		}
		httpError(w, http.StatusBadRequest, "upload interrupted")
		return
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		serverError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) getFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !reFile.MatchString(name) {
		httpError(w, http.StatusBadRequest, "bad file name")
		return
	}
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable") // names are UUIDs
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Disposition", "attachment")
	http.ServeFile(w, r, s.store.FilePath(r.PathValue("trip"), name))
}

// ---------------------------------------------------------------- invites

func (s *server) createInvite(w http.ResponseWriter, r *http.Request) {
	inv, err := s.store.CreateInvite(r.PathValue("trip"), currentUser(r).ID, inviteTTL)
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"code": inv.Code, "expires": inv.Expires})
}

func (s *server) join(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if s.limiter.blocked(ip) {
		httpError(w, http.StatusTooManyRequests, "too many attempts, try again later")
		return
	}
	var body struct{ Code, Name string }
	if !readBody(w, r, &body, 4096) {
		return
	}
	user := s.userFromHeader(r)
	name, okName := cleanName(body.Name)
	if user == nil && !okName {
		httpError(w, http.StatusBadRequest, "name required")
		return
	}
	view, u, token, err := s.store.Join(normalizeCode(body.Code), user, name)
	if errors.Is(err, errNotFound) {
		s.limiter.fail(ip)
		httpError(w, http.StatusNotFound, "invite code not valid or expired")
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"user": sessionResponse{u.ID, u.Name, token},
		"trip": view,
	})
}

// joinPage is where an invite link lands when opened in a browser.
func (s *server) joinPage(w http.ResponseWriter, r *http.Request) {
	code := normalizeCode(r.PathValue("code"))
	if len(code) == 8 {
		code = code[:4] + "-" + code[4:]
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, joinHTML, html.EscapeString(code))
}

const joinHTML = `<!doctype html><html lang="it"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>TripThatShit</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#000;color:#fff;font:16px/1.5 -apple-system,system-ui,sans-serif;padding:24px;box-sizing:border-box}
main{max-width:420px}h1{font-size:34px;font-weight:500;letter-spacing:-.6px;margin:0 0 8px}p{color:rgba(255,255,255,.72)}
code{display:block;margin:24px 0;padding:18px;border-radius:20px;background:#16181a;font:600 32px ui-monospace,monospace;letter-spacing:4px;text-align:center}</style></head>
<body><main><h1>Sei stato invitato a un viaggio</h1>
<p>Apri TripThatShit, tocca <b>&middot;&middot;&middot;</b> &rarr; <b>Unisciti con codice</b> e inserisci:</p>
<code>%s</code><p>Il codice vale 14 giorni.</p></main></body></html>`

// ---------------------------------------------------------------- helpers

func itemIDOf(raw json.RawMessage) (string, bool) {
	var item struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(raw, &item) != nil {
		return "", false
	}
	id := strings.ToUpper(item.ID)
	return id, reUUID.MatchString(id)
}

func normalizeCode(s string) string {
	var b strings.Builder
	for _, c := range strings.ToUpper(s) {
		if (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			b.WriteRune(c)
		}
	}
	return b.String()
}

func cleanName(s string) (string, bool) {
	s = strings.TrimSpace(s)
	if r := []rune(s); len(r) > 40 {
		s = string(r[:40])
	}
	return s, s != ""
}

func cleanTitle(s string) string {
	s = strings.TrimSpace(s)
	if r := []rune(s); len(r) > 120 {
		s = string(r[:120])
	}
	if s == "" {
		return "Viaggio"
	}
	return s
}

func readBody(w http.ResponseWriter, r *http.Request, v any, limit int64) bool {
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	if err != nil {
		httpError(w, http.StatusRequestEntityTooLarge, "body too large")
		return false
	}
	if err := json.Unmarshal(data, v); err != nil {
		httpError(w, http.StatusBadRequest, "invalid JSON")
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func serverError(w http.ResponseWriter, err error) {
	log.Printf("error: %v", err)
	httpError(w, http.StatusInternalServerError, "server error")
}

func storeError(w http.ResponseWriter, err error) {
	if errors.Is(err, errNotFound) {
		httpError(w, http.StatusNotFound, "not found")
		return
	}
	serverError(w, err)
}

// clientIP trusts X-Forwarded-For because only Caddy can reach this container.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return strings.TrimSpace(strings.Split(xff, ",")[0])
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	return host
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		if r.URL.Path != "/healthz" {
			log.Printf("%s %s %d %s", r.Method, r.URL.Path, rec.status, time.Since(start).Round(time.Millisecond))
		}
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) { r.status = code; r.ResponseWriter.WriteHeader(code) }

// limiter blocks an IP after too many wrong server keys or invite codes.
type limiter struct {
	mu     sync.Mutex
	max    int
	window time.Duration
	hits   map[string][]time.Time
}

func newLimiter(max int, window time.Duration) *limiter {
	return &limiter{max: max, window: window, hits: map[string][]time.Time{}}
}

func (l *limiter) recent(ip string) []time.Time {
	cut := time.Now().Add(-l.window)
	h := l.hits[ip]
	i := 0
	for i < len(h) && h[i].Before(cut) {
		i++
	}
	h = h[i:]
	if len(h) == 0 {
		delete(l.hits, ip)
	} else {
		l.hits[ip] = h
	}
	return h
}

func (l *limiter) blocked(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.recent(ip)) >= l.max
}

func (l *limiter) fail(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.hits[ip] = append(l.recent(ip), time.Now())
}
