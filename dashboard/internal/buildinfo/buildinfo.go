// Package buildinfo carries the small, non-secret identity embedded in a
// published dashboard binary.
package buildinfo

import (
	"fmt"
	"os"
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
	Version         string `json:"version"`
	SemanticVersion string `json:"semantic_version"`
	Commit          string `json:"commit"`
	ShortCommit     string `json:"short_commit,omitempty"`
	CommitShort     string `json:"commit_short,omitempty"`
	Channel         string `json:"channel,omitempty"`
	Tag             string `json:"tag,omitempty"`
	Ref             string `json:"ref,omitempty"`
	ImageRef        string `json:"image_ref,omitempty"`
	Digest          string `json:"digest,omitempty"`
	WorkflowRunID   string `json:"workflow_run_id,omitempty"`
	WorkflowRunURL  string `json:"workflow_run_url,omitempty"`
	Source          string `json:"source,omitempty"`
	BuiltAt         string `json:"built_at,omitempty"`
}

// Current returns a sanitized copy of the embedded build identity. Build
// metadata is public by design, but control characters must never reach an
// HTTP header or operator-facing page.
func Current() Info {
	commit := commitFromEnv(publicValue(Commit, "unknown"))
	ref := metadataValue(firstEnv("APP_IMAGE_REF", "APP_IMAGE_REFERENCE"), "")
	tag := publicValue(firstEnv("APP_IMAGE_TAG", "APP_IMAGE_VERSION_TAG"), "")
	if tag == "" {
		tag = imageTag(ref)
	}
	shortCommit := publicValue(firstEnv("APP_IMAGE_COMMIT_SHORT", "APP_COMMIT_SHORT"), "")
	if shortCommit == "" && len(commit) >= 7 && commit != "unknown" {
		shortCommit = commit[:7]
	}
	version := publicValue(firstOrDefault("APP_IMAGE_VERSION", "APP_VERSION", Version), "dev")
	return Info{
		Version:         version,
		SemanticVersion: version,
		Commit:          commit,
		ShortCommit:     shortCommit,
		CommitShort:     shortCommit,
		Channel:         publicValue(firstEnv("APP_IMAGE_CHANNEL", "APP_BUILD_CHANNEL"), "dev"),
		Tag:             tag,
		Ref:             ref,
		ImageRef:        ref,
		Digest:          metadataValue(firstEnv("APP_IMAGE_DIGEST", "APP_IMAGE_RESOLVED_DIGEST"), ""),
		WorkflowRunID:   publicValue(firstEnv("APP_WORKFLOW_RUN_ID", "APP_BUILD_WORKFLOW_RUN", "APP_WORKFLOW_RUN"), ""),
		WorkflowRunURL:  metadataValue(firstEnv("APP_WORKFLOW_RUN_URL"), ""),
		Source:          metadataValue(firstEnv("APP_SOURCE", "APP_IMAGE_SOURCE"), ""),
		BuiltAt:         metadataValue(firstEnv("APP_BUILT_AT", "APP_BUILD_AT", "APP_CREATED"), ""),
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

func metadataValue(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 512 {
		return fallback
	}
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return fallback
		}
	}
	return value
}

func firstEnv(names ...string) string {
	for _, name := range names {
		if value := strings.TrimSpace(os.Getenv(name)); value != "" {
			return value
		}
	}
	return ""
}

func firstOrDefault(names ...string) string {
	for _, name := range names[:len(names)-1] {
		if value := firstEnv(name); value != "" {
			return value
		}
	}
	return names[len(names)-1]
}

func commitFromEnv(fallback string) string {
	if value := publicValue(firstEnv("APP_IMAGE_COMMIT", "APP_COMMIT"), ""); value != "" {
		return value
	}
	return fallback
}

func imageTag(ref string) string {
	ref = strings.TrimSpace(ref)
	if at := strings.IndexByte(ref, '@'); at >= 0 {
		ref = ref[:at]
	}
	slash := strings.LastIndexByte(ref, '/')
	colon := strings.LastIndexByte(ref, ':')
	if colon <= slash || colon == len(ref)-1 {
		return ""
	}
	return publicValue(ref[colon+1:], "")
}

func isSafeRune(r rune) bool {
	return (r >= 'a' && r <= 'z') ||
		(r >= 'A' && r <= 'Z') ||
		(r >= '0' && r <= '9') ||
		strings.ContainsRune("._-", r)
}
