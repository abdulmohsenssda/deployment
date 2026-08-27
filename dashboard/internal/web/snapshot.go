package web

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
)

type appSnapshot struct {
	Apps       []dokku.App
	Healthy    bool
	UpdatedAt  time.Time
	Duration   time.Duration
	Refreshing bool
	Error      string
}

type snapshotCache struct {
	mu       sync.RWMutex
	seq      uint64
	snap     appSnapshot
	updated  chan struct{}
	trigger  chan struct{}
	interval time.Duration
	refresh  func(context.Context) appSnapshot
}

func newSnapshotCache(interval time.Duration, refresh func(context.Context) appSnapshot) *snapshotCache {
	return &snapshotCache{
		snap:     appSnapshot{Refreshing: true},
		updated:  make(chan struct{}),
		trigger:  make(chan struct{}, 1),
		interval: interval,
		refresh:  refresh,
	}
}

func (c *snapshotCache) Start(ctx context.Context) {
	go func() {
		for {
			c.runRefresh(ctx)
			select {
			case <-ctx.Done():
				return
			case <-time.After(c.interval):
			case <-c.trigger:
			}
		}
	}()
}

func (c *snapshotCache) RefreshSoon() {
	select {
	case c.trigger <- struct{}{}:
	default:
	}
}

func (c *snapshotCache) Snapshot() (appSnapshot, uint64) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return cloneSnapshot(c.snap), c.seq
}

func (c *snapshotCache) Wait(ctx context.Context, after uint64) (appSnapshot, uint64, bool) {
	for {
		c.mu.RLock()
		if c.seq > after {
			snap := cloneSnapshot(c.snap)
			seq := c.seq
			c.mu.RUnlock()
			return snap, seq, true
		}
		updated := c.updated
		c.mu.RUnlock()

		select {
		case <-ctx.Done():
			return appSnapshot{}, 0, false
		case <-updated:
		}
	}
}

func (c *snapshotCache) runRefresh(parent context.Context) {
	ctx, cancel := context.WithTimeout(parent, 2*time.Minute)
	defer cancel()

	started := time.Now()
	snap := c.refresh(ctx)
	snap.UpdatedAt = time.Now()
	snap.Duration = time.Since(started)
	snap.Refreshing = false
	c.store(snap)
}

func (c *snapshotCache) store(snap appSnapshot) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.seq++
	c.snap = cloneSnapshot(snap)
	close(c.updated)
	c.updated = make(chan struct{})
}

func cloneSnapshot(s appSnapshot) appSnapshot {
	s.Apps = cloneApps(s.Apps)
	return s
}

func cloneApps(apps []dokku.App) []dokku.App {
	if len(apps) == 0 {
		return nil
	}
	out := make([]dokku.App, len(apps))
	copy(out, apps)
	for i := range out {
		out[i].Procs = append([]string(nil), out[i].Procs...)
		out[i].Domains = append([]string(nil), out[i].Domains...)
	}
	return out
}

func appsJSON(apps []dokku.App) string {
	var b strings.Builder
	writeAppsJSONArray(&b, apps)
	return b.String()
}

func snapshotJSON(s appSnapshot) string {
	var b strings.Builder
	b.WriteByte('{')
	fmt.Fprintf(&b, `"healthy":%t,"refreshing":%t,"updated_at":%q,"duration_ms":%d,"error":%q,"apps":`,
		s.Healthy, s.Refreshing, s.UpdatedAt.UTC().Format(time.RFC3339), s.Duration.Milliseconds(), s.Error)
	writeAppsJSONArray(&b, s.Apps)
	b.WriteString(`,"open":`)
	writeFleetOpenJSON(&b, s.Apps)
	b.WriteByte('}')
	return b.String()
}

func writeAppsJSONArray(b *strings.Builder, apps []dokku.App) {
	b.WriteByte('[')
	for i, a := range apps {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(b,
			`{"name":%q,"role":%q,"tenant":%q,"state":%q,"image":%q,"version":%q,"http":%q,"int_port":%q,"host_ports":%q,"procs":%q,"domains":%q}`,
			a.Name, a.Role, a.Tenant, a.State, a.Image, a.Version, a.HTTPCode, a.IntPort, a.HostPorts,
			strings.Join(a.Procs, ","), strings.Join(a.Domains, ","))
	}
	b.WriteByte(']')
}
