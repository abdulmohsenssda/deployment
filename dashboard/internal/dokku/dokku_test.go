package dokku

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestStreamLogsStripsControlsWhileStreaming(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable() error = %v", err)
	}
	t.Setenv("GO_WANT_HELPER_PROCESS", "1")

	client := New(executable, "dokku")
	var output flushBuffer
	var lines []string
	err = client.StreamLogs(context.Background(), "api", &output, func(line string) {
		lines = append(lines, line)
	})
	if err != nil {
		t.Fatalf("StreamLogs() error = %v", err)
	}

	if got, want := strings.Join(lines, "|"), "red|plain"; got != want {
		t.Fatalf("streamed callback lines = %q, want %q", got, want)
	}
	if got, want := output.String(), "data: red\n\ndata: plain\n\n"; got != want {
		t.Fatalf("streamed output = %q, want %q", got, want)
	}
	if output.flushes != 2 {
		t.Fatalf("flushes = %d, want 2", output.flushes)
	}
}

func TestMain(m *testing.M) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		os.Exit(m.Run())
	}
	fmt.Print("\x1b[31mred\x1b[0m\n\x1b[2Kplain\n")
	os.Exit(0)
}

type flushBuffer struct {
	bytes.Buffer
	flushes int
}

func (b *flushBuffer) Flush() {
	b.flushes++
}

func TestProbeStatusForHTTPCode(t *testing.T) {
	tests := []struct {
		name string
		code string
		want string
	}{
		{name: "success", code: "200", want: ProbeStatusHealthy},
		{name: "redirect", code: "302", want: ProbeStatusHealthy},
		{name: "not found", code: "404", want: ProbeStatusHTTPError},
		{name: "server error", code: "500", want: ProbeStatusHTTPError},
		{name: "transport sentinel", code: "000", want: ProbeStatusUnknown},
		{name: "invalid", code: "bad", want: ProbeStatusUnknown},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := probeStatusForHTTPCode(test.code); got != test.want {
				t.Fatalf("probeStatusForHTTPCode(%q) = %q, want %q", test.code, got, test.want)
			}
		})
	}
}

func TestAppSummaryWithoutContainerIsExplicitlyUnavailable(t *testing.T) {
	app := New("docker-that-is-not-called", "dokku").AppSummaryFrom(
		context.Background(),
		"acme-backend",
		"",
		nil,
	)

	if app.State != "not-deployed" || app.LifecycleState != "not-deployed" {
		t.Fatalf("lifecycle = %q/%q, want not-deployed", app.State, app.LifecycleState)
	}
	if app.HTTPCode != "000" || app.Probe.HTTPCode != "000" {
		t.Fatalf("HTTP code = %q/%q, want 000", app.HTTPCode, app.Probe.HTTPCode)
	}
	if app.Probe.Status != ProbeStatusUnavailable {
		t.Fatalf("probe status = %q, want %q", app.Probe.Status, ProbeStatusUnavailable)
	}
	if app.Probe.UnavailableReason == "" || app.Probe.CheckedAt.IsZero() {
		t.Fatalf("probe should include an unavailable reason and timestamp: %+v", app.Probe)
	}
}

func TestHTTPProbeSeparatesHTTPErrorAndCommandFailure(t *testing.T) {
	t.Run("404 is an HTTP result", func(t *testing.T) {
		client := New("fixture", "dokku")
		client.probeCommand = func(_ context.Context, _ ...string) (string, string, error) {
			return "404", "", nil
		}
		probe := client.httpProbeResult(context.Background(), "acme-backend", "/healthz")
		if probe.Status != ProbeStatusHTTPError || probe.HTTPCode != "404" {
			t.Fatalf("probe = %+v, want HTTP 404 result", probe)
		}
		if probe.Error != "" || probe.UnavailableReason != "" {
			t.Fatalf("HTTP result should not be reported as command failure: %+v", probe)
		}
	})

	t.Run("000 includes command error", func(t *testing.T) {
		client := New("fixture", "dokku")
		client.probeCommand = func(_ context.Context, _ ...string) (string, string, error) {
			return "000", "curl: connection refused", errors.New("exit status 1")
		}
		probe := client.httpProbeResult(context.Background(), "acme-backend", "/healthz")
		if probe.Status != ProbeStatusFailed || probe.HTTPCode != "000" {
			t.Fatalf("probe = %+v, want failed HTTP 000 result", probe)
		}
		if probe.Error == "" || probe.CheckedAt.IsZero() {
			t.Fatalf("failed probe should include error and timestamp: %+v", probe)
		}
	})
}

func TestParseContainerSummaryHandlesShortInspectOutput(t *testing.T) {
	got := parseContainerSummary("running\nssdawweq/ifritah-api:dev\n")
	if got.State != "running" {
		t.Fatalf("state = %q, want running", got.State)
	}
	if got.Image != "ssdawweq/ifritah-api:dev" {
		t.Fatalf("image = %q, want dev image", got.Image)
	}
}

func TestParseContainerSummaryReadsVersionFromInspectOutput(t *testing.T) {
	got := parseContainerSummary("running\nimage\n0\nAPP_IMAGE_VERSION=feature-test\n")
	if got.Version != "feature-test" {
		t.Fatalf("version = %q, want feature-test", got.Version)
	}
}

func TestProbeResultInternalHealthy(t *testing.T) {
	got := probeResult("http://dev-backend.web/healthz", "200\t", nil, "internal service")
	if got.Status != "healthy" || got.HTTPCode != "200" || got.Reason != "" {
		t.Fatalf("unexpected internal health: %+v", got)
	}
}

func TestProbeResultHTTP000HasActionableReason(t *testing.T) {
	got := probeResult("http://dev-backend.web/healthz", "000\tCould not resolve host", errors.New("exit status 6"), "internal service")
	if got.Status != "unavailable" || got.HTTPCode != "000" {
		t.Fatalf("unexpected unavailable probe: %+v", got)
	}
	if !strings.Contains(got.Reason, "Could not resolve host") {
		t.Fatalf("probe reason is not actionable: %q", got.Reason)
	}
	got = probeResult("http://dev-backend.web/healthz", "curl: (6) Could not resolve host\n000\tCould not resolve host", errors.New("exit status 6"), "internal service")
	if got.Status != "unavailable" || got.HTTPCode != "000" {
		t.Fatalf("prefixed curl output was not parsed: %+v", got)
	}
}

func TestExternalProbeHealthyRouting(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/healthz" {
			t.Fatalf("path = %q, want /healthz", r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	got := (New("docker", "dokku")).externalProbe(context.Background(), []string{server.URL}, "/healthz")
	if got.Status != "healthy" || got.HTTPCode != "200" {
		t.Fatalf("unexpected external probe: %+v", got)
	}
}

func TestExternalProbeUnavailableIncludesReason(t *testing.T) {
	got := (New("docker", "dokku")).externalProbe(context.Background(), []string{"http://127.0.0.1:1"}, "/")
	if got.Status != "unavailable" || got.HTTPCode != "000" {
		t.Fatalf("unexpected external probe: %+v", got)
	}
	if !strings.Contains(got.Reason, "external route unavailable") {
		t.Fatalf("external probe reason is not actionable: %q", got.Reason)
	}
}

func TestBuildIdentityMissingAndLocalImageAreNotVerified(t *testing.T) {
	missing := buildIdentity(map[string]string{}, "dokku/dev-backend:latest", "", "latest")
	if missing.Status != "missing" || !strings.Contains(missing.Reason, "channel") {
		t.Fatalf("unexpected missing identity: %+v", missing)
	}

	verified := buildIdentity(map[string]string{
		"APP_IMAGE_CHANNEL":    "stable",
		"APP_IMAGE_VERSION":    "v1.2.3",
		"APP_IMAGE_COMMIT":     "0123456789abcdef",
		"APP_SOURCE":           "https://github.com/example/api",
		"APP_IMAGE_REF":        "registry.example/api:v1.2.3",
		"APP_IMAGE_DIGEST":     "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"APP_WORKFLOW_RUN_ID":  "42",
		"APP_WORKFLOW_RUN_URL": "https://github.com/example/api/actions/runs/42",
		"APP_BUILT_AT":         "2026-09-07T10:00:00Z",
	}, "registry.example/api:v1.2.3", "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "v1.2.3")
	if verified.Status != "verified" || verified.ImageRef == "dokku/dev-backend:latest" {
		t.Fatalf("unexpected verified identity: %+v", verified)
	}
	mismatch := buildIdentity(map[string]string{
		"APP_IMAGE_CHANNEL": "stable", "APP_IMAGE_VERSION": "v1.2.3",
		"APP_IMAGE_COMMIT": "0123456789abcdef", "APP_IMAGE_REF": "registry.example/api:v1.2.3",
		"APP_SOURCE":          "https://github.com/example/api",
		"APP_IMAGE_DIGEST":    "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"APP_WORKFLOW_RUN_ID": "42", "APP_BUILT_AT": "2026-09-07T10:00:00Z",
	}, "registry.example/api:v1.2.3", "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "v1.2.3")
	if mismatch.Status != "mismatch" {
		t.Fatalf("expected digest mismatch, got %+v", mismatch)
	}
}

func TestBuildIdentityAcceptsLegacyAliasesOnlyForMigration(t *testing.T) {
	got := buildIdentity(map[string]string{
		"APP_BUILD_CHANNEL": "release",
		"APP_VERSION":       "v1.2.3",
		"APP_COMMIT":        "0123456789abcdef",
		"APP_SOURCE":        "https://github.com/example/api",
		"APP_IMAGE_REF":     "registry.example/api:v1.2.3",
		"APP_IMAGE_DIGEST":  "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"APP_WORKFLOW_RUN":  "42",
		"APP_CREATED":       "2026-09-07T10:00:00Z",
	}, "registry.example/api:v1.2.3", "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "v1.2.3")
	if got.Status != "verified" || got.WorkflowRunID != "42" || got.BuiltAt == "" {
		t.Fatalf("legacy aliases were not migrated: %+v", got)
	}
}

func TestAppLivenessStates(t *testing.T) {
	if got := livenessForState("running"); got.Status != "healthy" {
		t.Fatalf("running liveness = %+v", got)
	}
	if got := livenessForState("stopped"); got.Status != "unhealthy" {
		t.Fatalf("stopped liveness = %+v", got)
	}
}
