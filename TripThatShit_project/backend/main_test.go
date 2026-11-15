package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const (
	tripID = "11111111-2222-4333-8444-555555555555"
	legA   = "AAAAAAAA-2222-4333-8444-555555555555"
	legB   = "BBBBBBBB-2222-4333-8444-555555555555"
	stayA  = "CCCCCCCC-2222-4333-8444-555555555555"
)

type client struct {
	t     *testing.T
	base  string
	token string
}

func (c *client) do(method, path string, body any, want int) map[string]any {
	c.t.Helper()
	var rd io.Reader
	switch b := body.(type) {
	case nil:
	case []byte:
		rd = bytes.NewReader(b)
	default:
		data, _ := json.Marshal(b)
		rd = bytes.NewReader(data)
	}
	req, _ := http.NewRequest(method, c.base+path, rd)
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(res.Body)
	if res.StatusCode != want {
		c.t.Fatalf("%s %s: got %d want %d: %s", method, path, res.StatusCode, want, data)
	}
	out := map[string]any{}
	_ = json.Unmarshal(data, &out)
	out["_raw"] = string(data)
	return out
}

func leg(id, file string) map[string]any {
	l := map[string]any{"id": id, "mode": "train", "departure": 1.0, "arrival": 2.0, "attachments": []any{}}
	if file != "" {
		l["attachments"] = []any{map[string]any{"id": id, "name": "ticket", "storedName": file}}
	}
	return l
}

func TestSharingFlow(t *testing.T) {
	dir := t.TempDir()
	store, err := openStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	s := &server{store: store, appKey: "super-secret-key", limiter: newLimiter(20, time.Hour)}
	ts := httptest.NewServer(s.routes())
	defer ts.Close()

	anon := &client{t: t, base: ts.URL}
	anon.do("POST", "/api/register", map[string]string{"name": "Pietro", "key": "wrong"}, 403)
	reg := anon.do("POST", "/api/register", map[string]string{"name": "Pietro", "key": "super-secret-key"}, 201)
	pietro := &client{t: t, base: ts.URL, token: reg["token"].(string)}

	// Share a trip with one leg, then upload its ticket.
	pietro.do("PUT", "/api/trips/"+tripID, map[string]any{"title": "Nord", "legs": []any{leg(legA, "T1.pdf")}}, 201)
	pietro.do("PUT", "/api/trips/"+tripID, map[string]any{"title": "Nord"}, 409)
	pietro.do("PUT", "/api/trips/"+tripID+"/files/T1.pdf", []byte("%PDF ticket"), 204)
	pietro.do("PUT", "/api/trips/"+tripID+"/files/..%2Fx", []byte("x"), 400)

	// A friend joins with an invite code and no account.
	inv := pietro.do("POST", "/api/trips/"+tripID+"/invites", nil, 201)
	code := inv["code"].(string)
	anon.do("POST", "/api/join", map[string]string{"code": "NOPE1234", "name": "Giulia"}, 404)
	joined := anon.do("POST", "/api/join", map[string]string{"code": code[:4] + "-" + code[4:], "name": "Giulia"}, 200)
	giulia := &client{t: t, base: ts.URL, token: joined["user"].(map[string]any)["token"].(string)}

	// The friend sees everything, including the file, and can edit.
	trip := giulia.do("GET", "/api/trips/"+tripID, nil, 200)
	if len(trip["members"].([]any)) != 2 || len(trip["legs"].([]any)) != 1 || trip["title"] != "Nord" {
		t.Fatalf("unexpected trip: %s", trip["_raw"])
	}
	req, _ := http.NewRequest("GET", ts.URL+"/api/trips/"+tripID+"/files/T1.pdf", nil)
	req.Header.Set("Authorization", "Bearer "+giulia.token)
	res, _ := http.DefaultClient.Do(req)
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if string(body) != "%PDF ticket" {
		t.Fatalf("file: %q", body)
	}
	giulia.do("PUT", "/api/trips/"+tripID+"/legs/"+legB, leg(legB, ""), 200)
	giulia.do("PUT", "/api/trips/"+tripID+"/legs/"+legB, leg(legA, ""), 400) // id mismatch
	giulia.do("PATCH", "/api/trips/"+tripID, map[string]string{"title": "Nord 2027"}, 200)

	// Stays work like legs, and their files are kept.
	giulia.do("PUT", "/api/trips/"+tripID+"/files/HOTEL.pdf", []byte("booking"), 204)
	giulia.do("PUT", "/api/trips/"+tripID+"/stays/"+stayA, leg(stayA, "HOTEL.pdf"), 200)
	giulia.do("PUT", "/api/trips/"+tripID+"/stays/"+stayA, leg(legA, ""), 400)

	trip = pietro.do("GET", "/api/trips/"+tripID, nil, 200)
	if len(trip["legs"].([]any)) != 2 || len(trip["stays"].([]any)) != 1 || trip["title"] != "Nord 2027" {
		t.Fatalf("pietro does not see giulia's edits: %s", trip["_raw"])
	}

	// Strangers get nothing.
	reg2 := anon.do("POST", "/api/register", map[string]string{"name": "Eve", "key": "super-secret-key"}, 201)
	eve := &client{t: t, base: ts.URL, token: reg2["token"].(string)}
	eve.do("GET", "/api/trips/"+tripID, nil, 403)
	eve.do("GET", "/api/trips/"+tripID+"/files/T1.pdf", nil, 403)
	anon.do("GET", "/api/trips/"+tripID, nil, 401)

	// Old unreferenced files are collected when legs change.
	pietro.do("PUT", "/api/trips/"+tripID+"/files/OLD.jpg", []byte("x"), 204)
	old := time.Now().Add(-2 * time.Hour)
	_ = os.Chtimes(filepath.Join(dir, "trips", tripID, "files", "OLD.jpg"), old, old)
	pietro.do("DELETE", "/api/trips/"+tripID+"/legs/"+legB, nil, 200)
	if _, err := os.Stat(filepath.Join(dir, "trips", tripID, "files", "OLD.jpg")); !os.IsNotExist(err) {
		t.Fatal("unreferenced file was not collected")
	}
	for _, f := range []string{"T1.pdf", "HOTEL.pdf"} {
		if _, err := os.Stat(filepath.Join(dir, "trips", tripID, "files", f)); err != nil {
			t.Fatalf("referenced file %s was collected", f)
		}
	}
	_ = os.Chtimes(filepath.Join(dir, "trips", tripID, "files", "HOTEL.pdf"), old, old)
	giulia.do("DELETE", "/api/trips/"+tripID+"/stays/"+stayA, nil, 200)
	if _, err := os.Stat(filepath.Join(dir, "trips", tripID, "files", "HOTEL.pdf")); !os.IsNotExist(err) {
		t.Fatal("deleted stay's file was not collected")
	}

	// State survives a restart.
	store2, err := openStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := store2.Trip(tripID); len(v.Members) != 2 || len(v.Legs) != 1 {
		t.Fatalf("after reload: %+v", v)
	}

	// /api/me lists the trip; leaving removes it; the last one out deletes it.
	me := giulia.do("GET", "/api/me", nil, 200)
	if len(me["trips"].([]any)) != 1 {
		t.Fatalf("me: %s", me["_raw"])
	}
	giulia.do("DELETE", "/api/trips/"+tripID+"/members/me", nil, 204)
	giulia.do("GET", "/api/trips/"+tripID, nil, 403)
	pietro.do("DELETE", "/api/trips/"+tripID+"/members/me", nil, 204)
	pietro.do("GET", "/api/trips/"+tripID, nil, 404)
	if _, err := os.Stat(filepath.Join(dir, "trips", tripID)); !os.IsNotExist(err) {
		t.Fatal("trip folder not removed")
	}
}
