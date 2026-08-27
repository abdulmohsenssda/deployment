// Package buildinfo carries the small, non-secret identity embedded in a
// published dashboard binary.
package buildinfo

import (
	"fmt"
	"strings"
)

// These values are replaced by the dashboard image build with -ldflags.
// Keeping useful defaults makes local binaries and unit tests identifiable.
var (
	Version = "dev"
	Commit  = "unknown"
)

// Info is the public build identity returned by the dashboard.
type Info struct {
	Version string `json:"version"`
	Commit  string `json:"commit"`
}

// Current returns a sanitized copy of the embedded build identity. Build
// metadata is public by design, but control characters must never reach an
// HTTP header or operator-facing page.
func Current() Info {
	return Info{
		Version: publicValue(Version, "dev"),
		Commit:  publicValue(Commit, "unknown"),
	}
}

// String formats the identity for logs and compact operator-facing labels.
func (i Info) String() string {
	return fmt.Sprintf("%s (%s)", i.Version, i.Commit)
}

// AssetVersion returns a stable cache key for static assets. A commit is
// preferred because it changes for every published source revision.
func (i Info) AssetVersion() string {
	if i.Commit != "" && i.Commit != "unknown" {
		return i.Commit
	}
	return i.Version
}

func publicValue(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	for _, r := range value {
		if !isSafeRune(r) {
			return fallback
		}
	}
	if len(value) > 128 {
		return fallback
	}
	return value
}

func isSafeRune(r rune) bool {
	return (r >= 'a' && r <= 'z') ||
		(r >= 'A' && r <= 'Z') ||
		(r >= '0' && r <= '9') ||
		strings.ContainsRune("._-", r)
}
