// Package tenantstate manages per-tenant persistent settings stored as a JSON
// file on disk at TENANT_STATE_DIR/<tenant>.json (default /opt/tenant-state/).
// It is safe for concurrent use.
package tenantstate

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// State holds operator-configurable per-tenant settings.
type State struct {
	// AutoRedeploy controls whether the auto-pull loop should automatically
	// deploy a new image for this tenant when the Docker Hub digest changes.
	// nil means "use default" which is true (enabled).
	AutoRedeploy *bool `json:"auto_redeploy,omitempty"`

	// BackupLabel is an optional human-readable label attached to the next
	// user-triggered backup. Cleared after being consumed.
	BackupLabel string `json:"backup_label,omitempty"`
}

// AutoRedeployEnabled returns true unless AutoRedeploy is explicitly false.
func (s State) AutoRedeployEnabled() bool {
	if s.AutoRedeploy == nil {
		return true // default: enabled
	}
	return *s.AutoRedeploy
}

// Store reads and writes per-tenant state files atomically.
type Store struct {
	dir string
	mu  sync.Mutex
}

// NewStore creates a Store that persists files under dir.
// dir defaults to /opt/tenant-state if empty.
func NewStore(dir string) *Store {
	if dir == "" {
		dir = "/opt/tenant-state"
	}
	return &Store{dir: dir}
}

func (s *Store) path(tenant string) string {
	return filepath.Join(s.dir, tenant+".json")
}

// Load reads a tenant's state. If the file doesn't exist, returns zero State
// (all defaults apply) without error.
func (s *Store) Load(tenant string) (State, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := os.ReadFile(s.path(tenant))
	if os.IsNotExist(err) {
		return State{}, nil
	}
	if err != nil {
		return State{}, err
	}
	var st State
	if err := json.Unmarshal(data, &st); err != nil {
		return State{}, err
	}
	return st, nil
}

// Save atomically writes a tenant's state using a write-then-rename strategy.
func (s *Store) Save(tenant string, st State) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.MkdirAll(s.dir, 0o750); err != nil {
		return err
	}
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path(tenant) + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path(tenant))
}

// SetAutoRedeploy updates only the AutoRedeploy field, preserving all other fields.
func (s *Store) SetAutoRedeploy(tenant string, enabled bool) error {
	st, err := s.Load(tenant)
	if err != nil {
		return err
	}
	b := enabled
	st.AutoRedeploy = &b
	return s.Save(tenant, st)
}

// IsAutoRedeployEnabled returns true unless the tenant has explicitly disabled it.
// Returns true (default) on read error.
func (s *Store) IsAutoRedeployEnabled(tenant string) bool {
	st, err := s.Load(tenant)
	if err != nil {
		return true
	}
	return st.AutoRedeployEnabled()
}

// SetBackupLabel stores a label that will be used for the next user backup.
func (s *Store) SetBackupLabel(tenant, label string) error {
	st, err := s.Load(tenant)
	if err != nil {
		return err
	}
	st.BackupLabel = label
	return s.Save(tenant, st)
}

// ConsumeBackupLabel reads and clears the pending backup label (returns "" if none).
func (s *Store) ConsumeBackupLabel(tenant string) (string, error) {
	st, err := s.Load(tenant)
	if err != nil {
		return "", err
	}
	label := st.BackupLabel
	if label != "" {
		st.BackupLabel = ""
		if err := s.Save(tenant, st); err != nil {
			return label, err
		}
	}
	return label, nil
}
