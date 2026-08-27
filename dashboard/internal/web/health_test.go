package web

import (
	"bytes"
	"encoding/json"
	"html/template"
	"strings"
	"testing"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
)

func TestAppsJSONSeparatesLifecycleAndProbe(t *testing.T) {
	checkedAt := time.Date(2026, time.August, 27, 4, 47, 7, 903000000, time.UTC)
	data := appsJSON([]dokku.App{{
		Name:           "acme-backend",
		Role:           "backend",
		Tenant:         "acme",
		State:          "running",
		LifecycleState: "running",
		HTTPCode:       "404",
		Probe: dokku.HealthProbe{
			Status:    dokku.ProbeStatusHTTPError,
			HTTPCode:  "404",
			CheckedAt: checkedAt,
		},
	}})

	var apps []struct {
		State          string `json:"state"`
		LifecycleState string `json:"lifecycle_state"`
		HTTPCode       string `json:"http"`
		ProbeStatus    string `json:"probe_status"`
		ProbeAt        string `json:"probe_checked_at"`
		Probe          struct {
			Status   string `json:"status"`
			HTTPCode string `json:"http_code"`
		} `json:"probe"`
	}
	if err := json.Unmarshal([]byte(data), &apps); err != nil {
		t.Fatalf("appsJSON returned invalid JSON: %v", err)
	}
	if len(apps) != 1 {
		t.Fatalf("got %d apps, want 1", len(apps))
	}
	app := apps[0]
	if app.State != "running" || app.LifecycleState != "running" {
		t.Fatalf("lifecycle fields = %q/%q, want running", app.State, app.LifecycleState)
	}
	if app.HTTPCode != "404" || app.ProbeStatus != dokku.ProbeStatusHTTPError {
		t.Fatalf("legacy/new probe fields = %q/%q, want 404/http-error", app.HTTPCode, app.ProbeStatus)
	}
	if app.ProbeAt != checkedAt.Format(time.RFC3339Nano) {
		t.Fatalf("probe timestamp = %q, want %q", app.ProbeAt, checkedAt.Format(time.RFC3339Nano))
	}
	if app.Probe.Status != dokku.ProbeStatusHTTPError || app.Probe.HTTPCode != "404" {
		t.Fatalf("nested probe = %+v, want HTTP 404", app.Probe)
	}
}

func TestAppsJSONExplainsUnavailableAndFailedProbes(t *testing.T) {
	data := appsJSON([]dokku.App{
		{
			Name:     "stopped-backend",
			State:    "stopped",
			HTTPCode: "000",
			Probe: dokku.HealthProbe{
				Status:            dokku.ProbeStatusUnavailable,
				HTTPCode:          "000",
				UnavailableReason: "probe not attempted because lifecycle state is stopped",
			},
		},
		{
			Name:     "failed-backend",
			State:    "running",
			HTTPCode: "000",
			Probe: dokku.HealthProbe{
				Status:   dokku.ProbeStatusFailed,
				HTTPCode: "000",
				Error:    "curl: connection refused",
			},
		},
	})

	var apps []map[string]any
	if err := json.Unmarshal([]byte(data), &apps); err != nil {
		t.Fatalf("appsJSON returned invalid JSON: %v", err)
	}
	if got := apps[0]["probe_unavailable_reason"]; got != "probe not attempted because lifecycle state is stopped" {
		t.Fatalf("unavailable reason = %v", got)
	}
	if got := apps[1]["probe_error"]; got != "curl: connection refused" {
		t.Fatalf("probe error = %v", got)
	}
}

func TestSnapshotJSONIncludesDokkuStatusAndTimestamp(t *testing.T) {
	checkedAt := time.Date(2026, time.August, 27, 4, 47, 7, 903000000, time.UTC)
	data := snapshotJSON(appSnapshot{
		Healthy:        false,
		DokkuStatus:    "unavailable",
		DokkuCheckedAt: checkedAt,
		DokkuError:     "docker inspect failed",
		UpdatedAt:      checkedAt,
		Duration:       1500 * time.Millisecond,
		Error:          "unable to list apps",
	})

	var snapshot struct {
		Healthy        bool   `json:"healthy"`
		DokkuStatus    string `json:"dokku_status"`
		DokkuCheckedAt string `json:"dokku_checked_at"`
		DokkuError     string `json:"dokku_error"`
		UpdatedAt      string `json:"updated_at"`
		Error          string `json:"error"`
		Apps           []any  `json:"apps"`
	}
	if err := json.Unmarshal([]byte(data), &snapshot); err != nil {
		t.Fatalf("snapshotJSON returned invalid JSON: %v", err)
	}
	if snapshot.Healthy || snapshot.DokkuStatus != "unavailable" {
		t.Fatalf("snapshot status = healthy:%t dokku:%q", snapshot.Healthy, snapshot.DokkuStatus)
	}
	if snapshot.DokkuCheckedAt != checkedAt.Format(time.RFC3339Nano) {
		t.Fatalf("dokku timestamp = %q, want %q", snapshot.DokkuCheckedAt, checkedAt.Format(time.RFC3339Nano))
	}
	if snapshot.DokkuError != "docker inspect failed" || snapshot.Error != "unable to list apps" {
		t.Fatalf("snapshot errors = %q/%q", snapshot.DokkuError, snapshot.Error)
	}
	if len(snapshot.Apps) != 0 {
		t.Fatalf("apps = %v, want empty array", snapshot.Apps)
	}
}

func TestHealthTemplatesExplainRepresentativeProbeStates(t *testing.T) {
	checkedAt := time.Date(2026, time.August, 27, 4, 47, 7, 0, time.UTC)
	tests := []struct {
		name  string
		app   dokku.App
		wants []string
	}{
		{
			name: "HTTP 404",
			app: dokku.App{
				Name:  "acme-backend",
				Role:  "backend",
				State: "running",
				Probe: dokku.HealthProbe{
					Status:    dokku.ProbeStatusHTTPError,
					HTTPCode:  "404",
					CheckedAt: checkedAt,
				},
			},
			wants: []string{"Lifecycle: running", "Health: HTTP 404", "HTTP 404", "Endpoint returned HTTP 404", "Checked 2026-08-27T04:47:07Z"},
		},
		{
			name: "failed HTTP 000",
			app: dokku.App{
				Name:  "acme-backend",
				Role:  "backend",
				State: "running",
				Probe: dokku.HealthProbe{
					Status:    dokku.ProbeStatusFailed,
					HTTPCode:  "000",
					CheckedAt: checkedAt,
					Error:     "curl: connection refused",
				},
			},
			wants: []string{"Health: Probe failed", "HTTP 000", "curl: connection refused"},
		},
		{
			name: "unavailable",
			app: dokku.App{
				Name:  "acme-backend",
				Role:  "backend",
				State: "stopped",
				Probe: dokku.HealthProbe{
					Status:            dokku.ProbeStatusUnavailable,
					HTTPCode:          "000",
					CheckedAt:         checkedAt,
					UnavailableReason: "probe not attempted because lifecycle state is stopped",
				},
			},
			wants: []string{"Lifecycle: stopped", "Health: Unavailable", "HTTP 000", "probe not attempted because lifecycle state is stopped"},
		},
		{
			name: "unknown lifecycle",
			app: dokku.App{
				Name:           "acme-backend",
				Role:           "backend",
				State:          "unknown",
				LifecycleError: "Dokku ps:report failed",
				Probe: dokku.HealthProbe{
					Status:    dokku.ProbeStatusUnknown,
					HTTPCode:  "000",
					CheckedAt: checkedAt,
					Error:     "Dokku ps:report failed",
				},
			},
			wants: []string{"Lifecycle: unknown", "Health: Unknown", "HTTP 000", "Dokku ps:report failed"},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			rendered := renderHealthTemplate(t, "app.html", map[string]any{
				"Env": "dev",
				"App": test.app,
			})
			for _, want := range test.wants {
				if !strings.Contains(rendered, want) {
					t.Errorf("rendered app page missing %q\n%s", want, rendered)
				}
			}
		})
	}
}

func TestTenantHealthTemplateKeepsLifecycleAndProbeSeparate(t *testing.T) {
	checkedAt := time.Date(2026, time.August, 27, 4, 47, 7, 0, time.UTC)
	rendered := renderHealthTemplate(t, "tenant.html", map[string]any{
		"Env":    "dev",
		"Tenant": "acme",
		"Backend": &dokku.App{
			Name:  "acme-backend",
			Role:  "backend",
			State: "running",
			Probe: dokku.HealthProbe{
				Status:    dokku.ProbeStatusHTTPError,
				HTTPCode:  "404",
				CheckedAt: checkedAt,
			},
		},
	})
	for _, want := range []string{"Lifecycle: running", "Health:", "HTTP 404", "Endpoint returned HTTP 404", "Checked 2026-08-27T04:47:07Z"} {
		if !strings.Contains(rendered, want) {
			t.Errorf("rendered tenant page missing %q\n%s", want, rendered)
		}
	}
}

func renderHealthTemplate(t *testing.T, name string, data any) string {
	t.Helper()
	funcs := template.FuncMap{
		"join":         strings.Join,
		"now":          func() string { return time.Now().Format("2006-01-02 15:04:05") },
		"stateClr":     stateClass,
		"httpClr":      httpClass,
		"probeClr":     probeClass,
		"probeLabel":   probeLabel,
		"probeMessage": probeMessage,
		"probeTime":    probeTime,
		"json":         templateJSON,
		"appDetailURL": appDetailURL,
	}
	tmpl, err := template.New("").Funcs(funcs).ParseFS(
		tplFS,
		"templates/_layout.html",
		"templates/palette.html",
		"templates/"+name,
	)
	if err != nil {
		t.Fatalf("parse %s: %v", name, err)
	}
	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, name, data); err != nil {
		t.Fatalf("execute %s: %v", name, err)
	}
	return buf.String()
}
