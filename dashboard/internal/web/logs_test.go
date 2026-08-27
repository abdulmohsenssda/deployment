package web

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
	"github.com/abdul-mohsen/deployment/dashboard/internal/logbuf"
	"github.com/go-chi/chi/v5"
)

func TestWriteSSEDataStripsControlsAndFramesMultilineText(t *testing.T) {
	var out strings.Builder
	if err := writeSSEData(&out, "2026-08-27T00:00:00Z \x1b[31mred\x1b[0m\nnext"); err != nil {
		t.Fatalf("writeSSEData() error = %v", err)
	}

	const want = "data: 2026-08-27T00:00:00Z red\ndata: next\n\n"
	if got := out.String(); got != want {
		t.Fatalf("writeSSEData() = %q, want %q", got, want)
	}
}

func TestAppLogHandlersStripControls(t *testing.T) {
	logs := logbuf.New(10)
	logs.Append("api", "\x1b[31mfirst\x1b[0m\nsecond")
	server := &server{
		dokku: dokku.New("__missing-docker-for-test__", "dokku"),
		logs:  logs,
	}

	t.Run("live stream", func(t *testing.T) {
		req := appLogRequest(t, "/apps/api/logs")
		ctx, cancel := context.WithCancel(req.Context())
		cancel()
		req = req.WithContext(ctx)

		rr := httptest.NewRecorder()
		server.handleLogStream(rr, req)

		body := rr.Body.String()
		if strings.ContainsAny(body, "\x1b\x00\x07") {
			t.Fatalf("live stream contains terminal controls: %q", body)
		}
		if !strings.Contains(body, "data: ") || !strings.Contains(body, "first") || !strings.Contains(body, "data: second\n\n") {
			t.Fatalf("live stream lost multiline log text: %q", body)
		}
	})

	t.Run("download", func(t *testing.T) {
		req := appLogRequest(t, "/apps/api/logs.txt")
		rr := httptest.NewRecorder()
		server.handleLogDump(rr, req)

		body := rr.Body.String()
		if strings.ContainsAny(body, "\x1b\x00\x07") {
			t.Fatalf("download contains terminal controls: %q", body)
		}
		if !strings.Contains(body, " first\nsecond\n") {
			t.Fatalf("download lost multiline log text: %q", body)
		}
	})
}

func appLogRequest(t *testing.T, target string) *http.Request {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, target, nil)
	routeCtx := chi.NewRouteContext()
	routeCtx.URLParams.Add("name", "api")
	return req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, routeCtx))
}
