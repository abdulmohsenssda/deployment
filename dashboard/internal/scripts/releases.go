package scripts

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var imageVersionTagPattern = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)

type releaseMetadata struct {
	ReleaseManifest
}

func versionOptions() []string {
	if raw := strings.TrimSpace(os.Getenv("APP_IMAGE_VERSIONS")); raw != "" {
		return versionTagsOnly(splitUnique(raw))
	}

	entries := loadReleaseMetadata()
	versions := make([]string, 0, len(entries)+1)
	versions = append(versions, strings.TrimSpace(os.Getenv("APP_IMAGE_VERSION_DEFAULT")))
	for _, entry := range entries {
		tag := strings.TrimSpace(entry.Tag)
		if tag == "" {
			tag = strings.TrimSpace(entry.ID)
		}
		versions = append(versions, tag)
	}
	if out := versionTagsOnly(uniqueNonEmpty(versions)); len(out) > 0 {
		return out
	}

	return []string{"v0.0.1"}
}

func releaseMetadataByTag() map[string]releaseMetadata {
	out := map[string]releaseMetadata{}
	for _, entry := range loadReleaseMetadata() {
		entry.ID = strings.TrimSpace(entry.ID)
		entry.Tag = strings.TrimSpace(entry.Tag)
		tag := entry.ID
		if tag == "" {
			tag = entry.Tag
		}
		if !IsImageVersionTag(tag) {
			continue
		}
		if entry.ID == "" {
			entry.ID = tag
		}
		if entry.Tag == "" {
			entry.Tag = tag
		}
		entry.Status = strings.TrimSpace(entry.Status)
		out[tag] = entry
	}
	return out
}

func IsImageVersionTag(tag string) bool {
	return imageVersionTagPattern.MatchString(strings.TrimSpace(tag))
}

func versionTagsOnly(in []string) []string {
	out := []string{}
	for _, tag := range in {
		if IsImageVersionTag(tag) {
			out = append(out, strings.TrimSpace(tag))
		}
	}
	return out
}

func loadReleaseMetadata() []releaseMetadata {
	for _, path := range releaseFileCandidates() {
		path = strings.TrimSpace(path)
		if path == "" {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var legacy []releaseManifestJSON
		if err := json.Unmarshal(data, &legacy); err == nil {
			out := make([]releaseMetadata, 0, len(legacy))
			for _, entry := range legacy {
				out = append(out, releaseMetadata{ReleaseManifest: entry.ReleaseManifest})
			}
			return out
		}
		var file ReleaseManifestFile
		if err := json.Unmarshal(data, &file); err == nil && file.Releases != nil {
			out := make([]releaseMetadata, 0, len(file.Releases))
			for _, entry := range file.Releases {
				out = append(out, releaseMetadata{ReleaseManifest: entry})
			}
			return out
		}
	}
	return nil
}

type releaseManifestJSON struct {
	ReleaseManifest
}

func releaseFileCandidates() []string {
	out := []string{}
	if v := strings.TrimSpace(os.Getenv("APP_IMAGE_RELEASES_FILE")); v != "" {
		out = append(out, v)
	}
	if deploymentDir := strings.TrimSpace(os.Getenv("DEPLOYMENT_DIR")); deploymentDir != "" {
		out = append(out,
			filepath.Join(deploymentDir, "dashboard", "releases.json"),
			filepath.Join(deploymentDir, "releases.json"),
		)
	}
	return append(out,
		"releases.json",
		filepath.Join("dashboard", "releases.json"),
		filepath.Join("..", "releases.json"),
	)
}

func splitUnique(raw string) []string {
	parts := strings.FieldsFunc(raw, func(r rune) bool { return r == ',' || r == '\n' || r == ' ' || r == '\t' })
	return uniqueNonEmpty(parts)
}

func uniqueNonEmpty(in []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, v := range in {
		v = strings.TrimSpace(v)
		if v == "" || seen[v] {
			continue
		}
		seen[v] = true
		out = append(out, v)
	}
	return out
}
