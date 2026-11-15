package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

// Everything lives in a few JSON files under DATA_DIR. Two to ten people on a trip
// produce a handful of writes a minute, so one mutex and atomic file writes are plenty.
//
//	users.json                    users and their hashed tokens
//	invites.json                  invite codes
//	trips/<id>/trip.json          title, members, legs and stays
//	trips/<id>/files/<storedName> tickets, PDFs and photos

type User struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	TokenHash string    `json:"tokenHash"`
	Created   time.Time `json:"created"`
}

type Invite struct {
	Code    string    `json:"code"`
	TripID  string    `json:"tripId"`
	By      string    `json:"by"`
	Expires time.Time `json:"expires"`
}

type Trip struct {
	ID      string                     `json:"id"`
	Title   string                     `json:"title"`
	Owner   string                     `json:"owner"`
	Members []string                   `json:"members"`
	Legs    map[string]json.RawMessage `json:"legs"`
	Stays   map[string]json.RawMessage `json:"stays"`
	Version int64                      `json:"version"`
	Updated time.Time                  `json:"updated"`
}

// items returns the legs or stays map; kind is "legs" or "stays".
func (t *Trip) items(kind string) map[string]json.RawMessage {
	if kind == "stays" {
		return t.Stays
	}
	return t.Legs
}

var (
	errNotFound = errors.New("not found")
	errExists   = errors.New("already exists")
)

type Store struct {
	mu      sync.Mutex
	dir     string
	users   map[string]*User // by id
	byToken map[string]string
	invites map[string]*Invite
	trips   map[string]*Trip
}

func openStore(dir string) (*Store, error) {
	s := &Store{
		dir:     dir,
		users:   map[string]*User{},
		byToken: map[string]string{},
		invites: map[string]*Invite{},
		trips:   map[string]*Trip{},
	}
	if err := os.MkdirAll(filepath.Join(dir, "trips"), 0o755); err != nil {
		return nil, err
	}
	var users []*User
	if err := loadFile(filepath.Join(dir, "users.json"), &users); err != nil {
		return nil, err
	}
	for _, u := range users {
		s.users[u.ID] = u
		s.byToken[u.TokenHash] = u.ID
	}
	var invites []*Invite
	if err := loadFile(filepath.Join(dir, "invites.json"), &invites); err != nil {
		return nil, err
	}
	for _, inv := range invites {
		s.invites[inv.Code] = inv
	}
	entries, err := os.ReadDir(filepath.Join(dir, "trips"))
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		var t Trip
		if err := loadFile(filepath.Join(dir, "trips", e.Name(), "trip.json"), &t); err != nil {
			return nil, err
		}
		if t.ID == "" {
			continue
		}
		if t.Legs == nil {
			t.Legs = map[string]json.RawMessage{}
		}
		if t.Stays == nil {
			t.Stays = map[string]json.RawMessage{}
		}
		s.trips[t.ID] = &t
	}
	return s, nil
}

// ---------------------------------------------------------------- users

func (s *Store) CreateUser(name string) (*User, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.createUserLocked(name)
}

func (s *Store) createUserLocked(name string) (*User, string, error) {
	token := randomToken(32)
	u := &User{ID: newUUID(), Name: name, TokenHash: hashToken(token), Created: time.Now().UTC()}
	s.users[u.ID] = u
	s.byToken[u.TokenHash] = u.ID
	if err := s.saveUsers(); err != nil {
		delete(s.users, u.ID)
		delete(s.byToken, u.TokenHash)
		return nil, "", err
	}
	return u, token, nil
}

func (s *Store) UserByToken(token string) *User {
	s.mu.Lock()
	defer s.mu.Unlock()
	if id, ok := s.byToken[hashToken(token)]; ok {
		u := *s.users[id]
		return &u
	}
	return nil
}

func (s *Store) RenameUser(id, name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[id]
	if !ok {
		return errNotFound
	}
	u.Name = name
	return s.saveUsers()
}

type TripRef struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Version int64  `json:"version"`
}

func (s *Store) TripsOf(userID string) []TripRef {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []TripRef{}
	for _, t := range s.trips {
		if slices.Contains(t.Members, userID) {
			out = append(out, TripRef{t.ID, t.Title, t.Version})
		}
	}
	return out
}

// ---------------------------------------------------------------- trips

type Member struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type TripView struct {
	ID      string            `json:"id"`
	Title   string            `json:"title"`
	Owner   string            `json:"owner"`
	Version int64             `json:"version"`
	Members []Member          `json:"members"`
	Legs    []json.RawMessage `json:"legs"`
	Stays   []json.RawMessage `json:"stays"`
}

func (s *Store) viewLocked(t *Trip) TripView {
	v := TripView{ID: t.ID, Title: t.Title, Owner: t.Owner, Version: t.Version, Members: []Member{}, Legs: []json.RawMessage{}, Stays: []json.RawMessage{}}
	for _, id := range t.Members {
		name := "?"
		if u, ok := s.users[id]; ok {
			name = u.Name
		}
		v.Members = append(v.Members, Member{id, name})
	}
	for _, l := range t.Legs {
		v.Legs = append(v.Legs, l)
	}
	for _, st := range t.Stays {
		v.Stays = append(v.Stays, st)
	}
	return v
}

func (s *Store) IsMember(tripID, userID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.trips[tripID]
	if !ok {
		return false, errNotFound
	}
	return slices.Contains(t.Members, userID), nil
}

func (s *Store) CreateTrip(id, owner, title string, legs, stays map[string]json.RawMessage) (TripView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.trips[id]; ok {
		return TripView{}, errExists
	}
	t := &Trip{ID: id, Title: title, Owner: owner, Members: []string{owner}, Legs: legs, Stays: stays, Version: 1, Updated: time.Now().UTC()}
	if err := os.MkdirAll(s.filesDir(id), 0o755); err != nil {
		return TripView{}, err
	}
	s.trips[id] = t
	if err := s.saveTrip(t); err != nil {
		delete(s.trips, id)
		return TripView{}, err
	}
	return s.viewLocked(t), nil
}

func (s *Store) Trip(id string) (TripView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.trips[id]
	if !ok {
		return TripView{}, errNotFound
	}
	return s.viewLocked(t), nil
}

// mutate applies f to a trip, bumps its version and saves it.
func (s *Store) mutate(id string, f func(t *Trip)) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.trips[id]
	if !ok {
		return 0, errNotFound
	}
	f(t)
	t.Version++
	t.Updated = time.Now().UTC()
	return t.Version, s.saveTrip(t)
}

func (s *Store) SetTitle(id, title string) (int64, error) {
	return s.mutate(id, func(t *Trip) { t.Title = title })
}

// PutItem stores a leg or a stay (kind "legs" or "stays").
func (s *Store) PutItem(id, kind, itemID string, item json.RawMessage) (int64, error) {
	v, err := s.mutate(id, func(t *Trip) { t.items(kind)[itemID] = item })
	if err == nil {
		s.collectFiles(id)
	}
	return v, err
}

func (s *Store) DeleteItem(id, kind, itemID string) (int64, error) {
	v, err := s.mutate(id, func(t *Trip) { delete(t.items(kind), itemID) })
	if err == nil {
		s.collectFiles(id)
	}
	return v, err
}

// Leave removes a member. The last one out deletes the trip and its files.
func (s *Store) Leave(id, userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.trips[id]
	if !ok {
		return errNotFound
	}
	t.Members = slices.DeleteFunc(t.Members, func(m string) bool { return m == userID })
	if len(t.Members) > 0 {
		t.Version++
		return s.saveTrip(t)
	}
	delete(s.trips, id)
	for code, inv := range s.invites {
		if inv.TripID == id {
			delete(s.invites, code)
		}
	}
	_ = s.saveInvites()
	return os.RemoveAll(filepath.Join(s.dir, "trips", id))
}

// ---------------------------------------------------------------- invites

func (s *Store) CreateInvite(tripID, by string, ttl time.Duration) (*Invite, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now().UTC()
	for code, inv := range s.invites {
		if now.After(inv.Expires) {
			delete(s.invites, code)
		}
	}
	inv := &Invite{Code: inviteCode(), TripID: tripID, By: by, Expires: now.Add(ttl)}
	s.invites[inv.Code] = inv
	return inv, s.saveInvites()
}

// Join adds the user to the invite's trip. With no user, a new one called name is created first.
func (s *Store) Join(code string, user *User, name string) (TripView, *User, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	inv, ok := s.invites[code]
	if !ok || time.Now().After(inv.Expires) {
		return TripView{}, nil, "", errNotFound
	}
	t, ok := s.trips[inv.TripID]
	if !ok {
		return TripView{}, nil, "", errNotFound
	}
	var token string
	if user == nil {
		u, tok, err := s.createUserLocked(name)
		if err != nil {
			return TripView{}, nil, "", err
		}
		user, token = u, tok
	}
	if !slices.Contains(t.Members, user.ID) {
		t.Members = append(t.Members, user.ID)
		t.Version++
		if err := s.saveTrip(t); err != nil {
			return TripView{}, nil, "", err
		}
	}
	return s.viewLocked(t), user, token, nil
}

// ---------------------------------------------------------------- files

func (s *Store) filesDir(tripID string) string {
	return filepath.Join(s.dir, "trips", tripID, "files")
}

func (s *Store) FilePath(tripID, name string) string {
	return filepath.Join(s.filesDir(tripID), name)
}

// collectFiles removes files no leg or stay points to any more. Recent files are kept: a phone
// uploads a ticket just before the leg that references it.
func (s *Store) collectFiles(tripID string) {
	s.mu.Lock()
	t, ok := s.trips[tripID]
	keep := map[string]bool{}
	if ok {
		for _, m := range []map[string]json.RawMessage{t.Legs, t.Stays} {
			for _, raw := range m {
				var item struct {
					Attachments []struct {
						StoredName string `json:"storedName"`
					} `json:"attachments"`
				}
				if json.Unmarshal(raw, &item) == nil {
					for _, a := range item.Attachments {
						keep[a.StoredName] = true
					}
				}
			}
		}
	}
	s.mu.Unlock()
	if !ok {
		return
	}
	entries, _ := os.ReadDir(s.filesDir(tripID))
	for _, e := range entries {
		if keep[e.Name()] {
			continue
		}
		if info, err := e.Info(); err == nil && time.Since(info.ModTime()) > time.Hour {
			_ = os.Remove(filepath.Join(s.filesDir(tripID), e.Name()))
		}
	}
}

// ---------------------------------------------------------------- persistence

func (s *Store) saveUsers() error {
	list := make([]*User, 0, len(s.users))
	for _, u := range s.users {
		list = append(list, u)
	}
	return saveFile(filepath.Join(s.dir, "users.json"), list)
}

func (s *Store) saveInvites() error {
	list := make([]*Invite, 0, len(s.invites))
	for _, inv := range s.invites {
		list = append(list, inv)
	}
	return saveFile(filepath.Join(s.dir, "invites.json"), list)
}

func (s *Store) saveTrip(t *Trip) error {
	dir := filepath.Join(s.dir, "trips", t.ID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return saveFile(filepath.Join(dir, "trip.json"), t)
}

func loadFile(path string, v any) error {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

// saveFile writes to a temp file and renames it, so a crash never leaves half a file.
func saveFile(path string, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ---------------------------------------------------------------- ids

func randomToken(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// newUUID returns an upper-case v4 UUID, the same format Swift's uuidString uses.
func newUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b)
	return upper(h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32])
}

// Invite codes avoid look-alike characters (0/O, 1/I/L) so they survive being read aloud.
const codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

func inviteCode() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	out := make([]byte, 8)
	for i := range b {
		out[i] = codeAlphabet[int(b[i])%len(codeAlphabet)]
	}
	return string(out)
}

func upper(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 32
		}
	}
	return string(b)
}
