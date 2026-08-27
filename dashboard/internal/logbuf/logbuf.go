// Package logbuf provides a per-key ring buffer for log aggregation.
//
// Lines are appended as the SSE stream pushes them. The most recent N lines
// (configurable) are retained per key. When a directory is configured, entries
// are also stored as JSONL so a dashboard restart does not erase the history.
package logbuf

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Entry is a single buffered log line with its capture timestamp.
type Entry struct {
	At   time.Time `json:"at"`
	Line string    `json:"line"`
}

// Store retains the most recent N log lines for each key.
type Store struct {
	mu        sync.RWMutex
	cap       int
	dir       string
	bufs      map[string][]Entry
	heads     map[string]int // index where the next entry will be written
	lens      map[string]int
	persisted map[string]int
}

// New returns a memory-only Store retaining capPerKey lines per key.
func New(capPerKey int) *Store {
	return newStore(capPerKey, "")
}

// NewPersistent returns a Store that loads and persists entries under dir.
// Files are private JSONL files keyed by an opaque, URL-safe filename.
func NewPersistent(capPerKey int, dir string) (*Store, error) {
	if strings.TrimSpace(dir) == "" {
		return nil, fmt.Errorf("log directory is empty")
	}
	s := newStore(capPerKey, filepath.Clean(dir))
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return nil, fmt.Errorf("create log directory: %w", err)
	}
	if err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

func newStore(capPerKey int, dir string) *Store {
	if capPerKey <= 0 {
		capPerKey = 1000
	}
	return &Store{
		cap:       capPerKey,
		dir:       dir,
		bufs:      map[string][]Entry{},
		heads:     map[string]int{},
		lens:      map[string]int{},
		persisted: map[string]int{},
	}
}

// Append records a line for key. Safe for concurrent use. If the store is
// persistent, the returned error means the line could not be written to disk.
func (s *Store) Append(key, line string) error {
	entry := Entry{At: time.Now().UTC(), Line: line}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.appendMemoryLocked(key, entry)
	if s.dir == "" {
		return nil
	}

	path := s.filePath(key)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("open log file: %w", err)
	}
	encErr := json.NewEncoder(f).Encode(entry)
	if encErr == nil {
		encErr = f.Sync()
	}
	closeErr := f.Close()
	if encErr != nil {
		return fmt.Errorf("write log file: %w", encErr)
	}
	if closeErr != nil {
		return fmt.Errorf("close log file: %w", closeErr)
	}
	s.persisted[key]++
	if s.persisted[key] > s.cap*2 {
		if err := s.compactLocked(key); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) appendMemoryLocked(key string, entry Entry) {
	buf, ok := s.bufs[key]
	if !ok {
		buf = make([]Entry, s.cap)
		s.bufs[key] = buf
	}
	head := s.heads[key]
	buf[head] = entry
	s.heads[key] = (head + 1) % s.cap
	if s.lens[key] < s.cap {
		s.lens[key]++
	}
}

func (s *Store) load() error {
	files, err := os.ReadDir(s.dir)
	if err != nil {
		return fmt.Errorf("read log directory: %w", err)
	}
	for _, file := range files {
		if file.IsDir() || !strings.HasSuffix(file.Name(), ".jsonl") {
			continue
		}
		encoded := strings.TrimSuffix(file.Name(), ".jsonl")
		keyBytes, err := base64.RawURLEncoding.DecodeString(encoded)
		if err != nil {
			return fmt.Errorf("decode log filename %q: %w", file.Name(), err)
		}
		key := string(keyBytes)
		f, err := os.Open(filepath.Join(s.dir, file.Name()))
		if err != nil {
			return fmt.Errorf("open log file %q: %w", file.Name(), err)
		}
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 1024), 1024*1024)
		count := 0
		for scanner.Scan() {
			var entry Entry
			if err := json.Unmarshal(scanner.Bytes(), &entry); err != nil {
				_ = f.Close()
				return fmt.Errorf("decode log file %q: %w", file.Name(), err)
			}
			s.appendMemoryLocked(key, entry)
			count++
		}
		scanErr := scanner.Err()
		closeErr := f.Close()
		if scanErr != nil {
			return fmt.Errorf("read log file %q: %w", file.Name(), scanErr)
		}
		if closeErr != nil {
			return fmt.Errorf("close log file %q: %w", file.Name(), closeErr)
		}
		s.persisted[key] = count
		if count > s.cap*2 {
			if err := s.compactLocked(key); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Store) compactLocked(key string) error {
	path := s.filePath(key)
	tmp, err := os.CreateTemp(s.dir, ".log-*.tmp")
	if err != nil {
		return fmt.Errorf("create compacted log: %w", err)
	}
	tmpPath := tmp.Name()
	enc := json.NewEncoder(tmp)
	for _, entry := range s.snapshotLocked(key) {
		if err := enc.Encode(entry); err != nil {
			_ = tmp.Close()
			_ = os.Remove(tmpPath)
			return fmt.Errorf("write compacted log: %w", err)
		}
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return fmt.Errorf("sync compacted log: %w", err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("close compacted log: %w", err)
	}
	if err := os.Chmod(tmpPath, 0o600); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("protect compacted log: %w", err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		// Windows does not replace an existing destination with Rename.
		if removeErr := os.Remove(path); removeErr != nil {
			_ = os.Remove(tmpPath)
			return fmt.Errorf("replace compacted log: %w (remove old file: %v)", err, removeErr)
		}
		if retryErr := os.Rename(tmpPath, path); retryErr != nil {
			_ = os.Remove(tmpPath)
			return fmt.Errorf("replace compacted log: %w", retryErr)
		}
	}
	s.persisted[key] = s.lens[key]
	return nil
}

func (s *Store) filePath(key string) string {
	encoded := base64.RawURLEncoding.EncodeToString([]byte(key))
	return filepath.Join(s.dir, encoded+".jsonl")
}

func (s *Store) snapshotLocked(key string) []Entry {
	buf, ok := s.bufs[key]
	if !ok || s.lens[key] == 0 {
		return nil
	}
	n := s.lens[key]
	out := make([]Entry, 0, n)
	start := (s.heads[key] - n + s.cap) % s.cap
	for i := 0; i < n; i++ {
		out = append(out, buf[(start+i)%s.cap])
	}
	return out
}

// Snapshot returns all retained lines for key, oldest first.
func (s *Store) Snapshot(key string) []Entry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.snapshotLocked(key)
}

// Dump returns the snapshot as a single text blob (for download).
func (s *Store) Dump(key string) string {
	entries := s.Snapshot(key)
	var b strings.Builder
	for _, e := range entries {
		b.WriteString(e.At.UTC().Format(time.RFC3339))
		b.WriteByte(' ')
		b.WriteString(e.Line)
		b.WriteByte('\n')
	}
	return b.String()
}
