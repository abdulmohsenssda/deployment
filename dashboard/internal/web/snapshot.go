package web

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
)

type appSnapshot struct {
	Apps           []dokku.App
	Healthy        bool
	DokkuStatus    string
	DokkuCheckedAt time.Time
	DokkuError     string
	UpdatedAt      time.Time
	Duration       time.Duration
	Refreshing     bool
	Error          string
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
		snap:     appSnapshot{Refreshing: true, DokkuStatus: "checking"},
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
	payload := snapshotAPI{
		Healthy:        s.Healthy,
		DokkuStatus:    s.DokkuStatus,
		DokkuCheckedAt: apiTime(s.DokkuCheckedAt),
		DokkuError:     s.DokkuError,
		Refreshing:     s.Refreshing,
		UpdatedAt:      s.UpdatedAt.UTC().Format(time.RFC3339),
		DurationMS:     s.Duration.Milliseconds(),
		Error:          s.Error,
		Apps:           appAPIs(s.Apps),
		Open:           fleetOpenStates(s.Apps),
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return `{"apps":[]}`
	}
	return string(data)
}

func writeAppsJSONArray(b *strings.Builder, apps []dokku.App) {
	data, err := json.Marshal(appAPIs(apps))
	if err != nil {
		b.WriteString("[]")
		return
	}
	b.Write(data)
}

type snapshotAPI struct {
	Healthy        bool                      `json:"healthy"`
	DokkuStatus    string                    `json:"dokku_status"`
	DokkuCheckedAt string                    `json:"dokku_checked_at"`
	DokkuError     string                    `json:"dokku_error"`
	Refreshing     bool                      `json:"refreshing"`
	UpdatedAt      string                    `json:"updated_at"`
	DurationMS     int64                     `json:"duration_ms"`
	Error          string                    `json:"error"`
	Apps           []appAPI                  `json:"apps"`
	Open           map[string]fleetOpenState `json:"open"`
}

type appAPI struct {
	Name                   string   `json:"name"`
	Role                   string   `json:"role"`
	Tenant                 string   `json:"tenant"`
	State                  string   `json:"state"`
	LifecycleState         string   `json:"lifecycle_state"`
	LifecycleError         string   `json:"lifecycle_error"`
	Image                  string   `json:"image"`
	Version                string   `json:"version"`
	HTTPCode               string   `json:"http"`
	ProbeStatus            string   `json:"probe_status"`
	ProbeCheckedAt         string   `json:"probe_checked_at"`
	ProbeError             string   `json:"probe_error"`
	ProbeUnavailableReason string   `json:"probe_unavailable_reason"`
	Probe                  probeAPI `json:"probe"`
	IntPort                string   `json:"int_port"`
	HostPorts              string   `json:"host_ports"`
	Procs                  string   `json:"procs"`
	Domains                string   `json:"domains"`
}

type probeAPI struct {
	Status            string `json:"status"`
	HTTPCode          string `json:"http_code"`
	CheckedAt         string `json:"checked_at"`
	Error             string `json:"error"`
	UnavailableReason string `json:"unavailable_reason"`
}

func appAPIs(apps []dokku.App) []appAPI {
	if len(apps) == 0 {
		return []appAPI{}
	}
	out := make([]appAPI, 0, len(apps))
	for _, app := range apps {
		out = append(out, appAPIFrom(app))
	}
	return out
}

func appAPIFrom(app dokku.App) appAPI {
	lifecycle := app.LifecycleState
	if lifecycle == "" {
		lifecycle = app.State
	}
	state := app.State
	if state == "" {
		state = lifecycle
	}
	probe := app.Probe
	if probe.HTTPCode == "" {
		probe.HTTPCode = app.HTTPCode
	}
	if probe.Status == "" {
		probe.Status = legacyProbeStatus(lifecycle, probe.HTTPCode)
	}
	probe.Status = normalizeProbeStatus(probe.Status)
	return appAPI{
		Name:                   app.Name,
		Role:                   app.Role,
		Tenant:                 app.Tenant,
		State:                  state,
		LifecycleState:         lifecycle,
		LifecycleError:         app.LifecycleError,
		Image:                  app.Image,
		Version:                app.Version,
		HTTPCode:               probe.HTTPCode,
		ProbeStatus:            probe.Status,
		ProbeCheckedAt:         apiTime(probe.CheckedAt),
		ProbeError:             probe.Error,
		ProbeUnavailableReason: probe.UnavailableReason,
		Probe: probeAPI{
			Status:            probe.Status,
			HTTPCode:          probe.HTTPCode,
			CheckedAt:         apiTime(probe.CheckedAt),
			Error:             probe.Error,
			UnavailableReason: probe.UnavailableReason,
		},
		IntPort:   app.IntPort,
		HostPorts: app.HostPorts,
		Procs:     strings.Join(app.Procs, ","),
		Domains:   strings.Join(app.Domains, ","),
	}
}

func legacyProbeStatus(lifecycle, code string) string {
	switch {
	case strings.HasPrefix(code, "2"), strings.HasPrefix(code, "3"):
		return dokku.ProbeStatusHealthy
	case strings.HasPrefix(code, "4"), strings.HasPrefix(code, "5"):
		return dokku.ProbeStatusHTTPError
	case lifecycle == "not-deployed", lifecycle == "stopped", lifecycle == "exited",
		lifecycle == "dead", lifecycle == "paused", lifecycle == "restarting":
		return dokku.ProbeStatusUnavailable
	default:
		return dokku.ProbeStatusUnknown
	}
}

func apiTime(value time.Time) string {
	if value.IsZero() {
		return ""
	}
	return value.UTC().Format(time.RFC3339Nano)
}
