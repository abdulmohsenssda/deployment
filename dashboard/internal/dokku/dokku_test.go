package dokku

import (
	"bytes"
	"context"
	"fmt"
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
