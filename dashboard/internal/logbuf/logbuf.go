// Package logbuf provides a per-app, in-memory ring buffer for log aggregation.
//
// Lines are appended as the SSE stream pushes them. The most recent N lines
// (configurable) are retained per app. Snapshots can be downloaded for
// offline analysis without standing up Loki/Promtail.
package logbuf

import (
	"strings"
	"sync"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/ansi"
)

// Entry is a single buffered log line with its capture timestamp.
type Entry struct {
	At   time.Time
	Line string
}

// Store retains the most recent N log lines for each app.
type Store struct {
	mu    sync.RWMutex
	cap   int
	bufs  map[string][]Entry
	heads map[string]int // index where the next entry will be written
	lens  map[string]int
}

// New returns a Store retaining capPerApp lines per app.
func New(capPerApp int) *Store {
	if capPerApp <= 0 {
		capPerApp = 1000
	}
	return &Store{
		cap:   capPerApp,
		bufs:  map[string][]Entry{},
		heads: map[string]int{},
		lens:  map[string]int{},
	}
}

// Append records a line for app after removing terminal controls. Safe for
// concurrent use.
func (s *Store) Append(app, line string) {
	line = ansi.Strip(line)
	s.mu.Lock()
	defer s.mu.Unlock()
	buf, ok := s.bufs[app]
	if !ok {
		buf = make([]Entry, s.cap)
		s.bufs[app] = buf
	}
	head := s.heads[app]
	buf[head] = Entry{At: time.Now(), Line: line}
	s.heads[app] = (head + 1) % s.cap
	if s.lens[app] < s.cap {
		s.lens[app]++
	}
}

// Snapshot returns all retained lines for app, oldest first.
func (s *Store) Snapshot(app string) []Entry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	buf, ok := s.bufs[app]
	if !ok || s.lens[app] == 0 {
		return nil
	}
	n := s.lens[app]
	out := make([]Entry, 0, n)
	start := (s.heads[app] - n + s.cap) % s.cap
	for i := 0; i < n; i++ {
		out = append(out, buf[(start+i)%s.cap])
	}
	return out
}

// Dump returns the snapshot as a single text blob (for download).
func (s *Store) Dump(app string) string {
	entries := s.Snapshot(app)
	var b strings.Builder
	for _, e := range entries {
		b.WriteString(e.At.UTC().Format(time.RFC3339))
		b.WriteByte(' ')
		b.WriteString(e.Line)
		b.WriteByte('\n')
	}
	return b.String()
}
