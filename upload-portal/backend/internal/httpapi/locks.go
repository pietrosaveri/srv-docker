package httpapi

import "sync"

// linkLocker hands out a per-link mutex so the "re-check limits → insert"
// critical section for a given link runs serially. Without it, uploads that
// arrive concurrently (the client sends several at once) each read the same
// pre-insert count and all slip past the max-files / max-size caps — a
// time-of-check/time-of-use race.
//
// Per-link mutexes are never removed from the map; for a personal file-drop
// with a handful of links that unbounded growth is not a concern.
type linkLocker struct {
	mu    sync.Mutex
	locks map[int64]*sync.Mutex
}

func newLinkLocker() *linkLocker {
	return &linkLocker{locks: make(map[int64]*sync.Mutex)}
}

// lock acquires the mutex for linkID and returns its unlock function.
func (l *linkLocker) lock(linkID int64) func() {
	l.mu.Lock()
	m := l.locks[linkID]
	if m == nil {
		m = &sync.Mutex{}
		l.locks[linkID] = m
	}
	l.mu.Unlock()

	m.Lock()
	return m.Unlock
}
