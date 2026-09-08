package scripts

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const ReleaseManifestSchemaVersion = 1

var (
	digestPattern         = regexp.MustCompile(`^sha256:[0-9a-fA-F]{64}$`)
	workflowRunPattern    = regexp.MustCompile(`^[0-9]+$`)
	workflowRunURLPattern = regexp.MustCompile(`^https?://[^\s]+/actions/runs/[0-9]+$`)
)

// ReleaseManifestFile is the versioned on-disk release catalog. The loader also
// accepts the historical top-level array used by releases.json.
type ReleaseManifestFile struct {
	SchemaVersion int               `json:"schema_version"`
	Releases      []ReleaseManifest `json:"releases"`
}

// ReleaseManifest identifies the exact backend and frontend artifacts in a
// release. Component versions are intentionally independent.
type ReleaseManifest struct {
	ID         string                      `json:"id,omitempty"`
	Tag        string                      `json:"tag,omitempty"`
	Channel    string                      `json:"channel,omitempty"`
	Version    string                      `json:"version,omitempty"`
	Date       string                      `json:"date,omitempty"`
	Status     string                      `json:"status,omitempty"`
	Broken     bool                        `json:"broken,omitempty"`
	Title      string                      `json:"title,omitempty"`
	Notes      []string                    `json:"notes,omitempty"`
	Components map[string]ReleaseComponent `json:"components"`
	Validation ReleaseValidationSnapshot   `json:"validation,omitempty"`
}

// ReleaseComponent is the immutable build identity selected for one app.
type ReleaseComponent struct {
	Image          string              `json:"image"`
	Digest         string              `json:"digest"`
	Version        string              `json:"version"`
	SourceCommit   string              `json:"source_commit"`
	Repository     string              `json:"repository"`
	Channel        string              `json:"channel,omitempty"`
	WorkflowRun    string              `json:"workflow_run"`
	WorkflowRunURL string              `json:"workflow_run_url,omitempty"`
	Notes          []string            `json:"notes,omitempty"`
	Reused         bool                `json:"reused,omitempty"`
	Validation     ComponentValidation `json:"validation,omitempty"`
}

// ComponentValidation records the remote checks performed by the release
// generator. It prevents a static tag from being mistaken for a ready release.
type ComponentValidation struct {
	TagExists        bool   `json:"tag_exists"`
	OCIIdentityValid bool   `json:"oci_identity_valid"`
	CheckedAt        string `json:"checked_at,omitempty"`
}

type ReleaseValidationSnapshot struct {
	Ready  bool     `json:"ready"`
	Errors []string `json:"errors,omitempty"`
}

type ImageMetadata struct {
	Exists bool
	Digest string
	Labels map[string]string
}

type ImageResolver interface {
	ResolveImage(ctx context.Context, image string) (ImageMetadata, error)
}

type ValidationOptions struct {
	Resolver         ImageResolver
	RequireRemote    bool
	StoredValidation bool
}

type ValidationResult struct {
	Ready  bool
	Errors []string
}

// GenerateReleaseManifest fills unchanged components from the previous
// known-good release and normalizes the release identity.
func GenerateReleaseManifest(candidate ReleaseManifest, previous *ReleaseManifest) (ReleaseManifest, error) {
	if candidate.ID == "" {
		candidate.ID = candidate.Tag
	}
	if candidate.Tag == "" {
		candidate.Tag = candidate.ID
	}
	if candidate.ID == "" {
		return ReleaseManifest{}, errors.New("release id is required")
	}
	if candidate.Components == nil {
		candidate.Components = map[string]ReleaseComponent{}
	}
	if previous != nil {
		for _, name := range []string{"backend", "frontend"} {
			if _, ok := candidate.Components[name]; ok {
				continue
			}
			if component, ok := previous.Components[name]; ok {
				component.Reused = true
				candidate.Components[name] = component
			}
		}
	}
	for _, name := range []string{"backend", "frontend"} {
		component, ok := candidate.Components[name]
		if !ok {
			return ReleaseManifest{}, fmt.Errorf("missing %s component", name)
		}
		candidate.Components[name] = component
	}
	if candidate.Status == "" {
		candidate.Status = "not-ready"
	}
	candidate.Validation = ReleaseValidationSnapshot{}
	return candidate, nil
}

func ValidateReleaseManifest(ctx context.Context, manifest ReleaseManifest, opts ValidationOptions) ValidationResult {
	result := ValidationResult{Ready: true}
	if manifest.ID == "" && manifest.Tag == "" {
		result.add("release id is missing")
	}
	if manifest.Components == nil {
		result.add("components are missing")
		return result
	}
	for _, name := range []string{"backend", "frontend"} {
		component, ok := manifest.Components[name]
		if !ok {
			result.add("missing " + name + " component")
			continue
		}
		result.validateComponent(ctx, name, component, opts)
	}
	return result
}

func (r *ValidationResult) add(message string) {
	r.Ready = false
	r.Errors = append(r.Errors, message)
}

func (r *ValidationResult) validateComponent(ctx context.Context, name string, component ReleaseComponent, opts ValidationOptions) {
	_, tag, ok := splitImageRef(component.Image)
	if !ok {
		r.add(name + " image must include a tag")
	} else if component.Version == "" {
		r.add(name + " version is missing")
	} else if tag != component.Version {
		r.add(fmt.Sprintf("%s image tag %q does not match version %q", name, tag, component.Version))
	}

	if !digestPattern.MatchString(component.Digest) {
		r.add(name + " digest must be an immutable sha256 digest")
	}
	if component.Version != "dev" && !IsImageVersionTag(component.Version) {
		r.add(name + " version must be semantic vMAJOR.MINOR.PATCH or dev")
	}
	if component.SourceCommit == "" {
		r.add(name + " source_commit is missing")
	}
	if component.Repository == "" {
		r.add(name + " repository is missing")
	}
	if component.Channel == "" && (opts.Resolver != nil || !opts.StoredValidation) {
		r.add(name + " channel is missing")
	}
	if !workflowRunPattern.MatchString(component.WorkflowRun) {
		r.add(name + " workflow_run must be numeric")
	}
	if component.WorkflowRunURL != "" && !workflowRunURLPattern.MatchString(component.WorkflowRunURL) {
		r.add(name + " workflow_run_url is invalid")
	}
	if opts.Resolver == nil {
		if opts.RequireRemote {
			if !opts.StoredValidation || !component.Validation.TagExists || !component.Validation.OCIIdentityValid {
				r.add(name + " remote image validation is unavailable")
			}
		}
		return
	}
	metadata, err := opts.Resolver.ResolveImage(ctx, component.Image)
	if err != nil {
		r.add(fmt.Sprintf("%s image lookup failed: %v", name, err))
		return
	}
	if !metadata.Exists {
		r.add(name + " image tag does not exist")
		return
	}
	if metadata.Digest == "" || !strings.EqualFold(metadata.Digest, component.Digest) {
		r.add(name + " image digest does not match the manifest")
	}
	if metadata.Labels == nil {
		r.add(name + " OCI identity labels are missing")
		return
	}
	if metadata.Labels["org.opencontainers.image.version"] != component.Version {
		r.add(name + " OCI version label is missing or mismatched")
	}
	if metadata.Labels["org.opencontainers.image.revision"] != component.SourceCommit {
		r.add(name + " OCI revision label is missing or mismatched")
	}
	if metadata.Labels["org.opencontainers.image.created"] == "" {
		r.add(name + " OCI created label is missing")
	}
	if source := strings.TrimSpace(metadata.Labels["org.opencontainers.image.source"]); source == "" {
		r.add(name + " OCI source label is missing")
	} else if !strings.Contains(source, component.Repository) {
		r.add(name + " OCI source label does not identify the repository")
	}
	if channel := firstLabel(metadata.Labels, "com.ifritah.build.channel", "org.ifritah.build.channel", "org.opencontainers.image.channel"); channel == "" {
		r.add(name + " BuildIdentity channel label is missing")
	} else if component.Channel != "" && channel != component.Channel {
		r.add(name + " BuildIdentity channel label is missing or mismatched")
	}
	if ref := firstLabel(metadata.Labels, "com.ifritah.build.image_ref", "com.ifritah.build.image-ref"); ref == "" {
		r.add(name + " BuildIdentity image ref label is missing")
	} else if ref != component.Image {
		r.add(name + " BuildIdentity image ref label is missing or mismatched")
	}
	if workflowID := workflowRunID(metadata.Labels); workflowID == "" || workflowID != component.WorkflowRun {
		r.add(name + " BuildIdentity workflow run id label is missing or mismatched")
	}
	if component.WorkflowRunURL != "" {
		if workflowURL := firstLabel(metadata.Labels, "com.ifritah.build.workflow_run_url", "com.ifritah.build.workflow-run-url"); workflowURL != component.WorkflowRunURL {
			r.add(name + " BuildIdentity workflow run URL label is missing or mismatched")
		}
	}
}

func firstLabel(labels map[string]string, keys ...string) string {
	for _, key := range keys {
		if value := strings.TrimSpace(labels[key]); value != "" {
			return value
		}
	}
	return ""
}

func workflowRunID(labels map[string]string) string {
	value := firstLabel(labels,
		"com.ifritah.build.workflow_run_id",
		"com.ifritah.build.workflow-run-id",
		"com.ifritah.build.workflow_run",
		"com.ifritah.build.workflow-run",
		"org.ifritah.build.workflow_run",
		"org.opencontainers.image.workflow.run",
	)
	if strings.HasPrefix(value, "http://") || strings.HasPrefix(value, "https://") {
		value = value[strings.LastIndex(value, "/")+1:]
	}
	return value
}

func componentIdentityLabelsValid(component ReleaseComponent, labels map[string]string) bool {
	if labels == nil ||
		labels["org.opencontainers.image.version"] != component.Version ||
		labels["org.opencontainers.image.revision"] != component.SourceCommit ||
		labels["org.opencontainers.image.created"] == "" ||
		!strings.Contains(labels["org.opencontainers.image.source"], component.Repository) ||
		firstLabel(labels, "com.ifritah.build.channel", "org.ifritah.build.channel", "org.opencontainers.image.channel") != component.Channel ||
		firstLabel(labels, "com.ifritah.build.image_ref", "com.ifritah.build.image-ref") != component.Image ||
		workflowRunID(labels) != component.WorkflowRun {
		return false
	}
	if component.WorkflowRunURL != "" &&
		firstLabel(labels, "com.ifritah.build.workflow_run_url", "com.ifritah.build.workflow-run-url") != component.WorkflowRunURL {
		return false
	}
	return true
}

func (r ValidationResult) Snapshot() ReleaseValidationSnapshot {
	return ReleaseValidationSnapshot{Ready: r.Ready, Errors: append([]string(nil), r.Errors...)}
}

type DockerHubResolver struct {
	Client      *http.Client
	BaseURL     string
	RegistryURL string
	TokenURL    string
}

func (r DockerHubResolver) ResolveImage(ctx context.Context, image string) (ImageMetadata, error) {
	repo, tag, ok := splitImageRef(image)
	if !ok {
		return ImageMetadata{}, errors.New("image must include a tag")
	}
	base := strings.TrimRight(r.BaseURL, "/")
	if base == "" {
		base = "https://hub.docker.com"
	}
	endpoint := base + "/v2/repositories/" + repo + "/tags/" + url.PathEscape(tag)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return ImageMetadata{}, err
	}
	client := r.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return ImageMetadata{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return ImageMetadata{Exists: false}, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return ImageMetadata{}, fmt.Errorf("Docker Hub returned %s", resp.Status)
	}
	var payload struct {
		Images []struct {
			Digest string `json:"digest"`
		} `json:"images"`
		Digest string `json:"digest"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return ImageMetadata{}, err
	}
	digest := payload.Digest
	if digest == "" && len(payload.Images) > 0 {
		digest = payload.Images[0].Digest
	}
	metadata := ImageMetadata{Exists: true, Digest: digest}
	registryMetadata, err := r.resolveOCI(ctx, repo, tag)
	if err == nil {
		if registryMetadata.Digest != "" {
			metadata.Digest = registryMetadata.Digest
		}
		metadata.Labels = registryMetadata.Labels
	}
	return metadata, nil
}

func (r DockerHubResolver) resolveOCI(ctx context.Context, repo, tag string) (ImageMetadata, error) {
	client := r.Client
	if client == nil {
		client = http.DefaultClient
	}
	tokenURL := r.TokenURL
	if tokenURL == "" {
		tokenURL = "https://auth.docker.io/token"
	}
	tokenRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, tokenURL+"?service=registry.docker.io&scope=repository:"+url.QueryEscape(repo)+":pull", nil)
	if err != nil {
		return ImageMetadata{}, err
	}
	tokenResponse, err := client.Do(tokenRequest)
	if err != nil {
		return ImageMetadata{}, err
	}
	defer tokenResponse.Body.Close()
	if tokenResponse.StatusCode < 200 || tokenResponse.StatusCode >= 300 {
		return ImageMetadata{}, fmt.Errorf("Docker Hub token endpoint returned %s", tokenResponse.Status)
	}
	var tokenPayload struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(tokenResponse.Body).Decode(&tokenPayload); err != nil {
		return ImageMetadata{}, err
	}
	if tokenPayload.Token == "" {
		return ImageMetadata{}, errors.New("Docker Hub token is empty")
	}
	registry := strings.TrimRight(r.RegistryURL, "/")
	if registry == "" {
		registry = "https://registry-1.docker.io"
	}
	manifestURL := registry + "/v2/" + repo + "/manifests/" + url.PathEscape(tag)
	manifestRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, manifestURL, nil)
	if err != nil {
		return ImageMetadata{}, err
	}
	manifestRequest.Header.Set("Authorization", "Bearer "+tokenPayload.Token)
	manifestRequest.Header.Set("Accept", "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json")
	manifestResponse, err := client.Do(manifestRequest)
	if err != nil {
		return ImageMetadata{}, err
	}
	defer manifestResponse.Body.Close()
	if manifestResponse.StatusCode < 200 || manifestResponse.StatusCode >= 300 {
		return ImageMetadata{}, fmt.Errorf("Docker Registry returned %s", manifestResponse.Status)
	}
	var manifest struct {
		SchemaVersion int    `json:"schemaVersion"`
		MediaType     string `json:"mediaType"`
		Config        struct {
			Digest string `json:"digest"`
		} `json:"config"`
		Manifests []struct {
			Digest string `json:"digest"`
		} `json:"manifests"`
	}
	if err := json.NewDecoder(manifestResponse.Body).Decode(&manifest); err != nil {
		return ImageMetadata{}, err
	}
	if len(manifest.Manifests) > 0 {
		manifestURL = registry + "/v2/" + repo + "/manifests/" + url.PathEscape(manifest.Manifests[0].Digest)
		manifestRequest, err = http.NewRequestWithContext(ctx, http.MethodGet, manifestURL, nil)
		if err != nil {
			return ImageMetadata{}, err
		}
		manifestRequest.Header.Set("Authorization", "Bearer "+tokenPayload.Token)
		manifestRequest.Header.Set("Accept", "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json")
		manifestResponse, err = client.Do(manifestRequest)
		if err != nil {
			return ImageMetadata{}, err
		}
		defer manifestResponse.Body.Close()
		if manifestResponse.StatusCode < 200 || manifestResponse.StatusCode >= 300 {
			return ImageMetadata{}, fmt.Errorf("Docker Registry image manifest returned %s", manifestResponse.Status)
		}
		manifest = struct {
			SchemaVersion int    `json:"schemaVersion"`
			MediaType     string `json:"mediaType"`
			Config        struct {
				Digest string `json:"digest"`
			} `json:"config"`
			Manifests []struct {
				Digest string `json:"digest"`
			} `json:"manifests"`
		}{}
		if err := json.NewDecoder(manifestResponse.Body).Decode(&manifest); err != nil {
			return ImageMetadata{}, err
		}
	}
	configDigest := manifest.Config.Digest
	if configDigest == "" {
		return ImageMetadata{}, errors.New("OCI config digest is missing")
	}
	blobURL := registry + "/v2/" + repo + "/blobs/" + url.PathEscape(configDigest)
	blobRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, blobURL, nil)
	if err != nil {
		return ImageMetadata{}, err
	}
	blobRequest.Header.Set("Authorization", "Bearer "+tokenPayload.Token)
	blobResponse, err := client.Do(blobRequest)
	if err != nil {
		return ImageMetadata{}, err
	}
	defer blobResponse.Body.Close()
	if blobResponse.StatusCode < 200 || blobResponse.StatusCode >= 300 {
		return ImageMetadata{}, fmt.Errorf("Docker Registry config returned %s", blobResponse.Status)
	}
	var config struct {
		Config struct {
			Labels map[string]string `json:"Labels"`
		} `json:"config"`
		ContainerConfig struct {
			Labels map[string]string `json:"Labels"`
		} `json:"container_config"`
	}
	if err := json.NewDecoder(blobResponse.Body).Decode(&config); err != nil {
		return ImageMetadata{}, err
	}
	labels := config.Config.Labels
	if len(labels) == 0 {
		labels = config.ContainerConfig.Labels
	}
	return ImageMetadata{Exists: true, Labels: labels}, nil
}

func splitImageRef(image string) (repo, tag string, ok bool) {
	image = strings.TrimSpace(image)
	if image == "" || strings.Contains(image, "@") {
		return "", "", false
	}
	slash := strings.LastIndex(image, "/")
	colon := strings.LastIndex(image, ":")
	if colon <= slash || colon == len(image)-1 {
		return "", "", false
	}
	return image[:colon], image[colon+1:], true
}

func (m ReleaseManifest) Validated(ctx context.Context, opts ValidationOptions) (ReleaseManifest, ValidationResult) {
	result := ValidateReleaseManifest(ctx, m, opts)
	checkedAt := time.Now().UTC().Format(time.RFC3339)
	for name, component := range m.Components {
		component.Validation = ComponentValidation{CheckedAt: checkedAt}
		if opts.Resolver != nil {
			metadata, err := opts.Resolver.ResolveImage(ctx, component.Image)
			component.Validation.TagExists = err == nil && metadata.Exists
			component.Validation.OCIIdentityValid = component.Validation.TagExists &&
				strings.EqualFold(metadata.Digest, component.Digest) &&
				componentIdentityLabelsValid(component, metadata.Labels)
		}

		m.Components[name] = component
	}
	m.Validation = result.Snapshot()
	m.Status = "not-ready"
	if result.Ready {
		m.Status = "ready"
	}
	return m, result
}

func (m ReleaseManifest) MarshalJSON() ([]byte, error) {
	type alias ReleaseManifest
	if m.Status == "" {
		m.Status = "not-ready"
	}
	return json.Marshal(alias(m))
}

func (m ReleaseManifest) CheckedAt() string {
	return time.Now().UTC().Format(time.RFC3339)
}
