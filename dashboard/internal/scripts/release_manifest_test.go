package scripts

import (
	"context"
	"testing"
)

type fakeImageResolver map[string]ImageMetadata

func (f fakeImageResolver) ResolveImage(_ context.Context, image string) (ImageMetadata, error) {
	return f[image], nil
}

func component(name, version, commit, run string) ReleaseComponent {
	return ReleaseComponent{
		Image:        "example/" + name + ":" + version,
		Digest:       "sha256:" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		Version:      version,
		SourceCommit: commit,
		Repository:   "example/" + name,
		Channel:      "release",
		WorkflowRun:  run,
	}
}

func resolverFor(components map[string]ReleaseComponent) fakeImageResolver {
	out := fakeImageResolver{}
	for _, value := range components {
		out[value.Image] = ImageMetadata{
			Exists: true,
			Digest: value.Digest,
			Labels: map[string]string{
				"org.opencontainers.image.version":  value.Version,
				"org.opencontainers.image.revision": value.SourceCommit,
				"org.opencontainers.image.source":   "https://github.com/" + value.Repository,
				"org.opencontainers.image.created":  "2026-09-07T10:00:00Z",
				"com.ifritah.build.channel":         value.Channel,
				"com.ifritah.build.image_ref":       value.Image,
				"com.ifritah.build.workflow_run_id": value.WorkflowRun,
			},
		}
	}
	return out
}

func TestGenerateReleaseManifestBackendOnlyReusesFrontend(t *testing.T) {
	previous := &ReleaseManifest{
		ID: "v0.0.1",
		Components: map[string]ReleaseComponent{
			"backend":  component("api", "v0.0.1", "backend-old", "10"),
			"frontend": component("web", "v0.0.1", "frontend-old", "11"),
		},
	}
	candidate := ReleaseManifest{
		ID: "v0.0.2",
		Components: map[string]ReleaseComponent{
			"backend": component("api", "v0.0.2", "backend-new", "12"),
		},
	}
	got, err := GenerateReleaseManifest(candidate, previous)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Components["frontend"].Reused || got.Components["frontend"].Digest != previous.Components["frontend"].Digest {
		t.Fatalf("frontend digest was not reused: %+v", got.Components["frontend"])
	}
	result := ValidateReleaseManifest(context.Background(), got, ValidationOptions{
		Resolver:      resolverFor(got.Components),
		RequireRemote: true,
	})
	if !result.Ready {
		t.Fatalf("backend-only release should validate: %v", result.Errors)
	}
}

func TestGenerateReleaseManifestFrontendOnlyReusesBackend(t *testing.T) {
	previous := &ReleaseManifest{
		ID: "v0.0.1",
		Components: map[string]ReleaseComponent{
			"backend":  component("api", "v0.0.1", "backend-old", "10"),
			"frontend": component("web", "v0.0.1", "frontend-old", "11"),
		},
	}
	got, err := GenerateReleaseManifest(ReleaseManifest{
		ID: "v0.0.2",
		Components: map[string]ReleaseComponent{
			"frontend": component("web", "v0.0.2", "frontend-new", "12"),
		},
	}, previous)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Components["backend"].Reused || got.Components["backend"].Digest != previous.Components["backend"].Digest {
		t.Fatalf("backend digest was not reused: %+v", got.Components["backend"])
	}
}

func TestValidateReleaseManifestPairedAndDifferingVersions(t *testing.T) {
	paired := ReleaseManifest{
		ID: "v0.0.2",
		Components: map[string]ReleaseComponent{
			"backend":  component("api", "v0.0.2", "backend", "20"),
			"frontend": component("web", "v0.0.2", "frontend", "21"),
		},
	}
	if result := ValidateReleaseManifest(context.Background(), paired, ValidationOptions{Resolver: resolverFor(paired.Components), RequireRemote: true}); !result.Ready {
		t.Fatalf("paired release should validate: %v", result.Errors)
	}
	validated, result := paired.Validated(context.Background(), ValidationOptions{Resolver: resolverFor(paired.Components), RequireRemote: true})
	if !result.Ready || !validated.Components["backend"].Validation.TagExists || !validated.Components["frontend"].Validation.OCIIdentityValid {
		t.Fatalf("validated component snapshots missing: %+v / %v", validated.Components, result.Errors)
	}
	differing := paired
	differing.ID = "v0.0.3"
	differing.Components = map[string]ReleaseComponent{
		"backend":  component("api", "v0.0.3", "backend", "22"),
		"frontend": component("web", "v0.0.2", "frontend", "21"),
	}
	if result := ValidateReleaseManifest(context.Background(), differing, ValidationOptions{Resolver: resolverFor(differing.Components), RequireRemote: true}); !result.Ready {
		t.Fatalf("independent component versions should validate: %v", result.Errors)
	}
}

func TestValidateReleaseManifestMissingTag(t *testing.T) {
	manifest := ReleaseManifest{
		ID: "v0.0.2",
		Components: map[string]ReleaseComponent{
			"backend":  component("api", "v0.0.2", "backend", "20"),
			"frontend": component("web", "v0.0.2", "frontend", "21"),
		},
	}
	resolver := resolverFor(manifest.Components)
	delete(resolver, manifest.Components["backend"].Image)
	result := ValidateReleaseManifest(context.Background(), manifest, ValidationOptions{Resolver: resolver, RequireRemote: true})
	if result.Ready || !containsError(result.Errors, "backend image tag does not exist") {
		t.Fatalf("missing tag should be not-ready: %v", result.Errors)
	}
}

func TestValidateReleaseManifestMissingLabel(t *testing.T) {
	manifest := ReleaseManifest{
		ID: "v0.0.2",
		Components: map[string]ReleaseComponent{
			"backend":  component("api", "v0.0.2", "backend", "20"),
			"frontend": component("web", "v0.0.2", "frontend", "21"),
		},
	}

	resolver := resolverFor(manifest.Components)
	resolver[manifest.Components["frontend"].Image] = ImageMetadata{
		Exists: true,
		Digest: manifest.Components["frontend"].Digest,
		Labels: map[string]string{"org.opencontainers.image.version": "v0.0.2"},
	}
	result := ValidateReleaseManifest(context.Background(), manifest, ValidationOptions{Resolver: resolver, RequireRemote: true})
	if result.Ready || !containsError(result.Errors, "frontend OCI revision label is missing or mismatched") {
		t.Fatalf("missing OCI label should be not-ready: %v", result.Errors)
	}
}

func TestValidateReleaseManifestRequiresCanonicalBuildIdentityLabels(t *testing.T) {
	manifest := ReleaseManifest{
		ID: "v0.0.2",
		Components: map[string]ReleaseComponent{
			"backend":  component("api", "v0.0.2", "backend", "20"),
			"frontend": component("web", "v0.0.2", "frontend", "21"),
		},
	}
	resolver := resolverFor(manifest.Components)
	delete(resolver[manifest.Components["backend"].Image].Labels, "com.ifritah.build.image_ref")
	result := ValidateReleaseManifest(context.Background(), manifest, ValidationOptions{
		Resolver: resolver, RequireRemote: true,
	})
	if result.Ready || !containsError(result.Errors, "backend BuildIdentity image ref label is missing") {
		t.Fatalf("missing canonical image ref label should be not-ready: %v", result.Errors)
	}
}

func containsError(errors []string, want string) bool {
	for _, value := range errors {
		if value == want {
			return true
		}
	}
	return false
}
