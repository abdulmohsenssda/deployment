package web

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"path"
	"regexp"
	"sort"
	"strings"
	"sync"

	"github.com/abdul-mohsen/deployment/dashboard/internal/buildinfo"
	"github.com/go-chi/chi/v5"
)

var (
	staticReferencePattern   = regexp.MustCompile(`/static/([A-Za-z0-9._-]+)`)
	templateReferencePattern = regexp.MustCompile(`{{\s*template\s+"([^"]+)"`)
	templateActionPattern    = regexp.MustCompile(`{{[^}]*}}`)
	htmlRoutePattern         = regexp.MustCompile(`(?:href|action|src|hx-(?:get|post|put|patch|delete))=["'](/[^"']*)["']`)
	jsRoutePattern           = regexp.MustCompile(`(?:fetch|EventSource)\(\s*['"](/[^'"]+)`)
)

var dashboardPageTemplates = []string{
	"index.html",
	"app.html",
	"tenant.html",
	"scripts.html",
	"script.html",
	"releases.html",
	"password.html",
}

type assetManifest struct {
	Digest    string            `json:"digest"`
	Files     map[string]string `json:"files"`
	Templates map[string]string `json:"templates"`
}

var (
	assetManifestOnce  sync.Once
	assetManifestValue assetManifest
	assetManifestErr   error
)

func embeddedAssetManifest() (assetManifest, error) {
	assetManifestOnce.Do(func() {
		files := map[string]string{}
		templates := map[string]string{}
		entries := map[string]string{}
		var names []string
		walk := func(root string, target map[string]string) error {
			return fs.WalkDir(webFS(), root, func(name string, entry fs.DirEntry, err error) error {
				if err != nil {
					return err
				}
				if entry.IsDir() {
					return nil
				}
				data, err := fs.ReadFile(webFS(), name)
				if err != nil {
					return err
				}
				sum := sha256.Sum256(data)
				relative := strings.TrimPrefix(name, root+"/")
				digest := hex.EncodeToString(sum[:])
				target[relative] = digest
				key := root + "/" + relative
				entries[key] = digest
				names = append(names, key)
				return nil
			})
		}
		assetManifestErr = walk("static", files)
		if assetManifestErr == nil {
			assetManifestErr = walk("templates", templates)
		}
		if assetManifestErr != nil {
			return
		}
		sort.Strings(names)
		hasher := sha256.New()
		for _, name := range names {
			_, _ = hasher.Write([]byte(name))
			_, _ = hasher.Write([]byte{0})
			_, _ = hasher.Write([]byte(entries[name]))
			_, _ = hasher.Write([]byte{0})
		}
		assetManifestValue = assetManifest{
			Digest:    hex.EncodeToString(hasher.Sum(nil)),
			Files:     files,
			Templates: templates,
		}
	})
	if assetManifestErr != nil {
		return assetManifest{}, assetManifestErr
	}
	return cloneAssetManifest(assetManifestValue), nil
}

func cloneAssetManifest(in assetManifest) assetManifest {
	out := assetManifest{
		Digest:    in.Digest,
		Files:     make(map[string]string, len(in.Files)),
		Templates: make(map[string]string, len(in.Templates)),
	}
	for name, digest := range in.Files {
		out.Files[name] = digest
	}
	for name, digest := range in.Templates {
		out.Templates[name] = digest
	}
	return out
}

// validateEmbeddedWebAssets verifies the files referenced by the operator UI
// are part of the same embedded bundle. It runs at startup and in CI tests so
// a partial lifecycle/activity change cannot be published silently.
func validateEmbeddedWebAssets() error {
	required := []string{"static/app.css", "static/app.js", "static/htmx.min.js", "templates/_layout.html", "templates/palette.html", "templates/login.html"}
	required = append(required, func() []string {
		out := make([]string, 0, len(dashboardPageTemplates))
		for _, name := range dashboardPageTemplates {
			out = append(out, "templates/"+name)
		}
		return out
	}()...)

	for _, name := range required {
		if _, err := fs.Stat(webFS(), name); err != nil {
			return fmt.Errorf("required embedded asset %q: %w", name, err)
		}
	}

	entries, err := fs.ReadDir(tplFS, "templates")
	if err != nil {
		return fmt.Errorf("read embedded templates: %w", err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".html") {
			continue
		}
		name := path.Join("templates", entry.Name())
		data, err := fs.ReadFile(tplFS, name)
		if err != nil {
			return fmt.Errorf("read embedded template %q: %w", name, err)
		}
		for _, match := range staticReferencePattern.FindAllSubmatch(data, -1) {
			staticName := "static/" + string(match[1])
			if _, err := fs.Stat(staticFS, staticName); err != nil {
				return fmt.Errorf("template %q references missing static asset %q", name, staticName)
			}
		}
		for _, match := range templateReferencePattern.FindAllSubmatch(data, -1) {
			templateName := string(match[1])
			if templateName == "content" {
				continue
			}
			if _, err := fs.Stat(tplFS, "templates/"+templateName); err != nil {
				return fmt.Errorf("template %q references missing template %q", name, templateName)
			}
		}
	}

	if err := fs.WalkDir(staticFS, "static", func(name string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		data, err := fs.ReadFile(staticFS, name)
		if err != nil {
			return fmt.Errorf("read embedded asset %q: %w", name, err)
		}
		for _, match := range staticReferencePattern.FindAllSubmatch(data, -1) {
			staticName := "static/" + string(match[1])
			if staticName == name {
				continue
			}
			if _, err := fs.Stat(staticFS, staticName); err != nil {
				return fmt.Errorf("asset %q references missing static asset %q", name, staticName)
			}
		}
		return nil
	}); err != nil {
		return err
	}

	_, err = embeddedAssetManifest()
	return err
}

// validateEmbeddedWebRoutes checks links and client-side endpoint prefixes
// against the router. Template actions are replaced with a placeholder so
// dynamic app and tenant names are still checked against registered patterns.
func validateEmbeddedWebRoutes(r chi.Routes) error {
	patterns := map[string]bool{}
	if err := chi.Walk(r, func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
		patterns[route] = true
		return nil
	}); err != nil {
		return fmt.Errorf("walk routes: %w", err)
	}

	check := func(source, reference string) error {
		reference = normalizeRouteReference(reference)
		if reference == "" {
			return nil
		}
		if strings.HasSuffix(reference, "/") && reference != "/" {
			for pattern := range patterns {
				if strings.HasPrefix(strings.TrimSuffix(pattern, "/*"), reference) {
					return nil
				}
			}
		}
		for pattern := range patterns {
			if routePatternMatches(reference, pattern) {
				return nil
			}
		}
		return fmt.Errorf("%s references unregistered route %q", source, reference)
	}

	entries, err := fs.ReadDir(tplFS, "templates")
	if err != nil {
		return fmt.Errorf("read embedded templates: %w", err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".html") {
			continue
		}
		name := path.Join("templates", entry.Name())
		data, err := fs.ReadFile(tplFS, name)
		if err != nil {
			return fmt.Errorf("read embedded template %q: %w", name, err)
		}
		for _, match := range htmlRoutePattern.FindAllSubmatch(data, -1) {
			if err := check(name, string(match[1])); err != nil {
				return err
			}
		}
		for _, match := range jsRoutePattern.FindAllSubmatch(data, -1) {
			if err := check(name, string(match[1])); err != nil {
				return err
			}
		}
	}

	return fs.WalkDir(staticFS, "static", func(name string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(name, ".js") {
			return nil
		}
		data, err := fs.ReadFile(staticFS, name)
		if err != nil {
			return fmt.Errorf("read embedded script %q: %w", name, err)
		}
		for _, match := range jsRoutePattern.FindAllSubmatch(data, -1) {
			if err := check(name, string(match[1])); err != nil {
				return err
			}
		}
		return nil
	})
}

func normalizeRouteReference(reference string) string {
	reference = strings.TrimSpace(reference)
	reference = templateActionPattern.ReplaceAllString(reference, "placeholder")
	if i := strings.IndexAny(reference, "?#"); i >= 0 {
		reference = reference[:i]
	}
	return strings.TrimSpace(reference)
}

func routePatternMatches(reference, pattern string) bool {
	if reference == pattern {
		return true
	}
	patternSegments := strings.Split(strings.Trim(pattern, "/"), "/")
	referenceSegments := strings.Split(strings.Trim(reference, "/"), "/")
	if reference == "/" {
		referenceSegments = nil
	}
	if len(referenceSegments) == 0 {
		return pattern == "/"
	}
	if len(referenceSegments) > len(patternSegments) && !strings.HasSuffix(pattern, "/*") {
		return false
	}
	for i, segment := range referenceSegments {
		if i >= len(patternSegments) {
			return strings.HasSuffix(pattern, "/*")
		}
		patternSegment := patternSegments[i]
		if patternSegment == "*" || (strings.HasPrefix(patternSegment, "{") && strings.HasSuffix(patternSegment, "}")) {
			continue
		}
		if segment != patternSegment {
			return false
		}
	}
	if len(referenceSegments) == len(patternSegments) {
		return true
	}
	return strings.HasSuffix(pattern, "/*")
}

func webFS() fs.FS {
	return structFS{FS: tplFS, static: staticFS}
}

// structFS exposes both embedded trees to validation without allowing a
// template reference to accidentally resolve to a static asset (or vice
// versa).
type structFS struct {
	fs.FS
	static fs.FS
}

func (f structFS) Open(name string) (fs.File, error) {
	if name == "static" || strings.HasPrefix(name, "static/") {
		return f.static.Open(name)
	}
	return f.FS.Open(name)
}

type buildResponse struct {
	Service        string            `json:"service"`
	Version        string            `json:"version"`
	Commit         string            `json:"commit"`
	CommitShort    string            `json:"commit_short,omitempty"`
	Channel        string            `json:"channel,omitempty"`
	Tag            string            `json:"tag,omitempty"`
	Ref            string            `json:"ref,omitempty"`
	ImageRef       string            `json:"image_ref,omitempty"`
	Digest         string            `json:"digest,omitempty"`
	WorkflowRunID  string            `json:"workflow_run_id,omitempty"`
	WorkflowRunURL string            `json:"workflow_run_url,omitempty"`
	Source         string            `json:"source,omitempty"`
	BuiltAt        string            `json:"built_at,omitempty"`
	Build          string            `json:"build"`
	AssetDigest    string            `json:"asset_digest"`
	Assets         map[string]string `json:"assets"`
	Templates      map[string]string `json:"templates"`
}

func currentBuildResponse() buildResponse {
	info := buildinfo.Current()
	manifest, err := embeddedAssetManifest()
	if err != nil {
		return buildResponse{
			Service:        "dokku-dashboard",
			Version:        info.Version,
			Commit:         info.Commit,
			Build:          info.String(),
			Channel:        info.Channel,
			Tag:            info.Tag,
			Ref:            info.Ref,
			ImageRef:       info.ImageRef,
			Digest:         info.Digest,
			CommitShort:    info.CommitShort,
			WorkflowRunID:  info.WorkflowRunID,
			WorkflowRunURL: info.WorkflowRunURL,
			Source:         info.Source,
			BuiltAt:        info.BuiltAt,
		}
	}
	return buildResponse{
		Service:        "dokku-dashboard",
		Version:        info.Version,
		Commit:         info.Commit,
		CommitShort:    info.CommitShort,
		Channel:        info.Channel,
		Tag:            info.Tag,
		Ref:            info.Ref,
		ImageRef:       info.ImageRef,
		Digest:         info.Digest,
		WorkflowRunID:  info.WorkflowRunID,
		WorkflowRunURL: info.WorkflowRunURL,
		Source:         info.Source,
		BuiltAt:        info.BuiltAt,
		Build:          info.String(),
		AssetDigest:    manifest.Digest,
		Assets:         manifest.Files,
		Templates:      manifest.Templates,
	}
}

func setBuildHeaders(w http.ResponseWriter) {
	info := buildinfo.Current()
	w.Header().Set("X-Dashboard-Version", info.Version)
	w.Header().Set("X-Dashboard-Commit", info.Commit)
	if manifest, err := embeddedAssetManifest(); err == nil {
		w.Header().Set("X-Dashboard-Asset-Digest", manifest.Digest)
	}
}

func (s *server) handleBuildInfo(w http.ResponseWriter, _ *http.Request) {
	setBuildHeaders(w)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(currentBuildResponse())
}
