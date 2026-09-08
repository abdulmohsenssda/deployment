// Package scripts knows about the deployment shell scripts and how to invoke
// them safely.
//
// Scripts are not executed inside the dashboard container directly: instead
// the dashboard spawns a one-shot `docker run` of the BASH_RUNNER_IMAGE with
// the scripts directory mounted in. This avoids having to install bash, the
// mysql client, and friends into the dashboard image (which is impossible
// behind some corporate TLS proxies). The spawned container talks to the
// host's Docker daemon via the same socket the dashboard uses.
package scripts

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/abdul-mohsen/deployment/dashboard/internal/ansi"
)

// Field describes one input on a script's form.
type Field struct {
	Name        string // form field name (also used in argv synthesis when --arg-style)
	Label       string
	Help        string
	Type        string // "text" | "password" | "hidden" | "select" | "checkbox" | "kv" (KEY=VALUE list)
	Placeholder string
	Required    bool
	Options     []string // for type=select
	Flag        string   // CLI flag, e.g. "--type"; empty -> positional
	Boolean     bool     // when true, presence appends Flag (no value)
	Suggest     []string // optional datalist values rendered next to the input for auto-suggest
	Secret      bool     // when true, value is masked in the echoed command line and excluded from auto-fill persistence
	Default     string   // default value pre-filled into the input on render (and used as the hidden value)
	ImageScope  string   // image tag compatibility scope: "both", "backend", "frontend", or "role"
}

// ImageVersion describes one compatible backend/frontend image pair. The tag is
// shared by both images so operators choose a version instead of pasting image
// names into forms.
type ImageVersion struct {
	Tag                    string   `json:"tag"`
	Channel                string   `json:"channel,omitempty"`
	BackendImage           string   `json:"backend_image"`
	FrontendImage          string   `json:"frontend_image"`
	BackendVersion         string   `json:"backend_version"`
	FrontendVersion        string   `json:"frontend_version"`
	BackendDigest          string   `json:"backend_digest,omitempty"`
	FrontendDigest         string   `json:"frontend_digest,omitempty"`
	BackendSourceCommit    string   `json:"backend_source_commit,omitempty"`
	FrontendSourceCommit   string   `json:"frontend_source_commit,omitempty"`
	BackendRepository      string   `json:"backend_repository,omitempty"`
	FrontendRepository     string   `json:"frontend_repository,omitempty"`
	BackendWorkflowRun     string   `json:"backend_workflow_run,omitempty"`
	FrontendWorkflowRun    string   `json:"frontend_workflow_run,omitempty"`
	BackendWorkflowRunURL  string   `json:"backend_workflow_run_url,omitempty"`
	FrontendWorkflowRunURL string   `json:"frontend_workflow_run_url,omitempty"`
	Date                   string   `json:"date,omitempty"`
	Status                 string   `json:"status"`
	Broken                 bool     `json:"broken"`
	Ready                  bool     `json:"ready"`
	ValidationErrors       []string `json:"validation_errors,omitempty"`
	Title                  string   `json:"title"`
	Notes                  []string `json:"notes,omitempty"`
}

func ReleaseCatalog() []ImageVersion {
	return VersionCatalog()
}

func VersionCatalog() []ImageVersion {
	backendRepo := imageRepo("BACKEND_IMAGE", "ifritah-api", "ssdawweq/ifritah-api")
	frontendRepo := imageRepo("FRONTEND_IMAGE", "ifritah-web", "ssdawweq/ifritah-web")
	versions := versionOptions()
	metadata := releaseMetadataByTag()
	out := make([]ImageVersion, 0, len(versions))
	for _, tag := range versions {
		meta := metadata[tag]
		if meta.Status == "" {
			meta.Status = "not-ready"
		}
		if meta.Title == "" {
			meta.Title = tag
		}
		backendImage := backendRepo + ":" + tag
		frontendImage := frontendRepo + ":" + tag
		backendVersion, frontendVersion := tag, tag
		backendDigest, frontendDigest := "", ""
		backendSourceCommit, frontendSourceCommit := "", ""
		backendRepository, frontendRepository := "", ""
		backendWorkflowRun, frontendWorkflowRun := "", ""
		backendWorkflowRunURL, frontendWorkflowRunURL := "", ""
		ready := false
		validationErrors := []string{"release manifest metadata is missing"}
		if len(meta.Components) > 0 {
			backend, backendOK := meta.Components["backend"]
			frontend, frontendOK := meta.Components["frontend"]
			if backendOK {
				backendImage = backend.Image
				backendVersion = backend.Version
				backendDigest = backend.Digest
				backendSourceCommit = backend.SourceCommit
				backendRepository = backend.Repository
				backendWorkflowRun = backend.WorkflowRun
				backendWorkflowRunURL = backend.WorkflowRunURL
			}
			if frontendOK {
				frontendImage = frontend.Image
				frontendVersion = frontend.Version
				frontendDigest = frontend.Digest
				frontendSourceCommit = frontend.SourceCommit
				frontendRepository = frontend.Repository
				frontendWorkflowRun = frontend.WorkflowRun
				frontendWorkflowRunURL = frontend.WorkflowRunURL
			}
			validation := ValidateReleaseManifest(context.Background(), meta.ReleaseManifest, ValidationOptions{
				RequireRemote:    true,
				StoredValidation: true,
			})
			ready = meta.Status == "ready" && validation.Ready && meta.Validation.Ready
			validationErrors = append([]string(nil), validation.Errors...)
			validationErrors = append(validationErrors, meta.Validation.Errors...)
			validationErrors = uniqueNonEmpty(validationErrors)
			if len(validationErrors) == 0 && !ready {
				validationErrors = []string{"release manifest has not passed validation"}
			}
		} else {
			validationErrors = []string{"release manifest metadata is missing"}
			componentMetadataErrors(nil, &validationErrors)
		}
		if !ready && meta.Status == "ready" {
			meta.Status = "not-ready"
		}
		out = append(out, ImageVersion{
			Tag:                    tag,
			Channel:                meta.Channel,
			BackendImage:           backendImage,
			FrontendImage:          frontendImage,
			BackendVersion:         backendVersion,
			FrontendVersion:        frontendVersion,
			BackendDigest:          backendDigest,
			FrontendDigest:         frontendDigest,
			BackendSourceCommit:    backendSourceCommit,
			FrontendSourceCommit:   frontendSourceCommit,
			BackendRepository:      backendRepository,
			FrontendRepository:     frontendRepository,
			BackendWorkflowRun:     backendWorkflowRun,
			FrontendWorkflowRun:    frontendWorkflowRun,
			BackendWorkflowRunURL:  backendWorkflowRunURL,
			FrontendWorkflowRunURL: frontendWorkflowRunURL,
			Date:                   meta.Date,
			Status:                 meta.Status,
			Broken:                 meta.Broken,
			Ready:                  ready,
			ValidationErrors:       validationErrors,
			Title:                  meta.Title,
			Notes:                  meta.Notes,
		})
	}
	return out
}

func componentMetadataReady(name string, component ReleaseComponent, present bool, errors *[]string) bool {
	if !present {
		return false
	}
	ok := true
	if strings.TrimSpace(component.Image) == "" {
		*errors = append(*errors, name+" image ref is missing")
		ok = false
	}
	if strings.TrimSpace(component.Digest) == "" {
		*errors = append(*errors, name+" image digest is missing")
		ok = false
	}
	if strings.TrimSpace(component.Version) == "" {
		*errors = append(*errors, name+" version is missing")
		ok = false
	}
	if strings.TrimSpace(component.SourceCommit) == "" {
		*errors = append(*errors, name+" source commit is missing")
		ok = false
	}
	if !component.Validation.TagExists {
		*errors = append(*errors, name+" image tag has not been validated")
		ok = false
	}
	if !component.Validation.OCIIdentityValid {
		*errors = append(*errors, name+" OCI identity metadata has not been validated")
		ok = false
	}
	return ok
}

func componentMetadataErrors(components map[string]ReleaseComponent, errors *[]string) {
	for _, name := range []string{"backend", "frontend"} {
		component, ok := components[name]
		if !ok {
			*errors = append(*errors, "missing "+name+" component")
			continue
		}
		// A manifest can carry a ready validation snapshot from an older
		// generator. Keep the dashboard honest when the component identity
		// fields are absent from that snapshot.
		if strings.TrimSpace(component.Image) == "" {
			*errors = append(*errors, name+" image ref is missing")
		}
		if strings.TrimSpace(component.Digest) == "" {
			*errors = append(*errors, name+" image digest is missing")
		}
		if strings.TrimSpace(component.Version) == "" {
			*errors = append(*errors, name+" version is missing")
		}
		if strings.TrimSpace(component.SourceCommit) == "" {
			*errors = append(*errors, name+" source commit is missing")
		}
		if !component.Validation.TagExists {
			*errors = append(*errors, name+" image tag has not been validated")
		}
		if !component.Validation.OCIIdentityValid {
			*errors = append(*errors, name+" OCI identity metadata has not been validated")
		}
	}
}

func VersionOptions() []string {
	versions := versionOptions()
	out := make([]string, len(versions))
	copy(out, versions)
	return out
}

func DefaultImageVersion() string {
	// Explicit override always wins.
	if v := strings.TrimSpace(os.Getenv("APP_IMAGE_VERSION_DEFAULT")); v != "" {
		return v
	}
	// The rolling dev tag is the only safe default when the release catalog
	// does not carry repository coverage metadata. The web layer still
	// replaces it with the newest compatible tag when metadata is available.
	// Component channels default to the rolling dev images. Production
	// operators can still opt into a pinned release explicitly.
	return "dev"
}

func ResolveImageVersion(tag string) (ImageVersion, bool) {
	tag = strings.TrimSpace(tag)
	if !IsImageVersionTag(tag) {
		return ImageVersion{}, false
	}
	for _, v := range VersionCatalog() {
		if v.Tag == tag {
			return v, true
		}
	}
	return ImageVersion{}, false
}

func imageVersionField(required bool) Field {
	return imageVersionFieldForScope(required, "both")
}

func imageVersionFieldForScope(required bool, scope string) Field {
	help := "Tag applied to both BACKEND_IMAGE and FRONTEND_IMAGE. Type to search available tags from Docker Hub."
	switch scope {
	case "backend":
		help = "Tag applied to the backend image. Branch and PR tags are supported."
	case "frontend":
		help = "Tag applied to the frontend image. Branch and PR tags are supported."
	case "role":
		help = "Tag applied to the selected app type. Branch and PR tags are supported."
	}
	return Field{
		Name:        "image_version",
		Label:       "Image tag",
		Type:        "text",
		Required:    required,
		Placeholder: "e.g. dev, v1.2.3, or feature-my-branch",
		Suggest:     []string{}, // populated client-side from /api/image-tags via datalist
		Default:     DefaultImageVersion(),
		ImageScope:  scope,
		Help:        help,
	}
}

func componentImageVersionField(name, label string) Field {
	return Field{
		Name:        name,
		Label:       label,
		Type:        "text",
		Required:    true,
		Placeholder: "e.g. dev or v1.2.3",
		Default:     "dev",
		Help:        "Select this component's image channel or semantic release tag independently.",
	}
}

func optionalComponentImageVersionField(name, label string) Field {
	field := componentImageVersionField(name, label)
	field.Required = false
	field.Help = "Optional. Set this component's channel or semantic release tag when changing its image."
	return field
}

func imageRepo(envKey, suffix, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(envKey)); v != "" {
		return trimImageTag(v)
	}
	if user := strings.TrimSpace(os.Getenv("DOCKERHUB_USERNAME")); user != "" {
		return user + "/" + suffix
	}
	return fallback
}

// BackendRepo returns the backend image repository name (no tag).
func BackendRepo() string { return imageRepo("BACKEND_IMAGE", "ifritah-api", "ssdawweq/ifritah-api") }

// FrontendRepo returns the frontend image repository name (no tag).
func FrontendRepo() string {
	return imageRepo("FRONTEND_IMAGE", "ifritah-web", "ssdawweq/ifritah-web")
}

func trimImageTag(image string) string {
	lastSlash := strings.LastIndex(image, "/")
	lastColon := strings.LastIndex(image, ":")
	if lastColon > lastSlash {
		return image[:lastColon]
	}
	return image
}

// Script is a registered orchestration script the UI can invoke.
type Script struct {
	Name    string // script file name in scripts/ (e.g. "create-tenant.sh")
	Title   string
	Summary string
	Danger  bool    // confirmation required in UI
	Image   string  // override runner image; empty -> Runner.runnerImage default
	Fields  []Field // ordered
}

// Slug returns the URL-safe identifier for the script (file name without
// the .sh suffix). Used so dashboard URLs don't end in .sh, which some
// nginx setups treat as suspicious / try to execute via fastcgi.
func (s Script) Slug() string {
	return strings.TrimSuffix(s.Name, ".sh")
}

// ControlCommand returns the equivalent deployctl command shown in the UI.
func (s Script) ControlCommand() string {
	switch s.Slug() {
	case "status":
		return "fleet status"
	case "list-tenants":
		return "tenant list"
	case "create-tenant":
		return "tenant create"
	case "init-tenant-db":
		return "tenant init-db"
	case "remove-tenant":
		return "tenant remove"
	case "cleanup-broken-tenant":
		return "tenant cleanup"
	case "deploy-all":
		return "fleet sync"
	case "rollback-tenant":
		return "tenant rollback"
	case "set-tenant-image":
		return "tenant pin"
	case "update-tenant":
		return "tenant update"
	case "backup-tenant":
		return "tenant backup"
	case "manage-backups":
		return "tenant backups"
	case "restore-tenant":
		return "tenant restore"
	case "tail-logs":
		return "tenant logs"
	case "verify-mysql":
		return "db verify"
	case "fix-dokku-hostname":
		return "dokku fix-hostname"
	case "setup-nats":
		return "setup nats"
	case "discover-dokku-nginx":
		return "dokku discover-nginx"
	case "watch-dokku-traffic":
		return "dokku traffic"
	case "auto-pull":
		return "fleet auto-pull"
	case "setup-dev-tenant":
		return "setup dev-tenant"
	case "cleanup-old-files":
		return "cleanup old-files"
	default:
		return "script " + s.Name
	}
}

const (
	commandGroupReadOnlyStatus  = "read-only-status"
	commandGroupDeployment      = "deployment-lifecycle"
	commandGroupBackupRestore   = "backup-restore"
	commandGroupCleanupDeletion = "cleanup-deletion"
)

// CommandGroup is a scan-friendly section of the command index.
type CommandGroup struct {
	ID          string
	Title       string
	Description string
	Scripts     []Script
}

// GroupID returns the stable command-index group identifier for a script.
func (s Script) GroupID() string {
	switch s.Slug() {
	case "status", "list-tenants", "tail-logs", "verify-mysql",
		"discover-dokku-nginx", "watch-dokku-traffic":
		return commandGroupReadOnlyStatus
	case "backup-tenant", "manage-backups", "restore-tenant":
		return commandGroupBackupRestore
	case "remove-tenant", "cleanup-broken-tenant", "cleanup-old-files":
		return commandGroupCleanupDeletion
	default:
		return commandGroupDeployment
	}
}

// Group returns the human-readable operation group used by command-index
// templates and other callers that render an individual script.
func (s Script) Group() string {
	for _, group := range commandGroupDefinitions() {
		if group.ID == s.GroupID() {
			return group.Title
		}
	}
	return "Deployment / lifecycle"
}

// ImpactClass returns the CSS/data classification used to signal command
// impact before an operator opens the command.
func (s Script) ImpactClass() string {
	switch s.Slug() {
	case "status", "list-tenants", "tail-logs", "verify-mysql",
		"discover-dokku-nginx", "watch-dokku-traffic":
		return "read-only"
	case "remove-tenant", "cleanup-broken-tenant", "cleanup-old-files", "restore-tenant":
		return "destructive"
	default:
		if s.Danger {
			return "high-impact"
		}
		return "state-changing"
	}
}

// ImpactLabel returns the short, visible impact cue shown on command cards.
func (s Script) ImpactLabel() string {
	switch s.ImpactClass() {
	case "read-only":
		return "Read-only"
	case "destructive":
		return "Destructive"
	case "high-impact":
		return "High impact"
	default:
		return "Changes state"
	}
}

// ImpactDescription returns the longer impact cue used for accessibility and
// hover text in the command index.
func (s Script) ImpactDescription() string {
	switch s.ImpactClass() {
	case "read-only":
		return "Read-only; does not change tenant state."
	case "destructive":
		return "May overwrite or delete tenant data; confirmation is required."
	case "high-impact":
		return "Changes live deployment state; confirmation is required."
	default:
		return "Changes deployment or stored state."
	}
}

func commandGroupDefinitions() []CommandGroup {
	return []CommandGroup{
		{
			ID:          commandGroupReadOnlyStatus,
			Title:       "Read-only / status",
			Description: "Inspect tenant health, logs, connectivity, and routing without changing workloads.",
		},
		{
			ID:          commandGroupDeployment,
			Title:       "Deployment / lifecycle",
			Description: "Provision tenants, roll out images, tune services, and run platform setup.",
		},
		{
			ID:          commandGroupBackupRestore,
			Title:       "Backup / restore",
			Description: "Protect, inspect, and recover tenant data. Restore can replace the current state.",
		},
		{
			ID:          commandGroupCleanupDeletion,
			Title:       "Cleanup / deletion",
			Description: "Remove tenants or retired files. Destructive commands require extra review.",
		},
	}
}

// CommandGroups returns the complete catalog arranged in the command index's
// stable, risk-aware section order. Every catalog entry appears exactly once.
func CommandGroups() []CommandGroup {
	groups := commandGroupDefinitions()
	index := make(map[string]int, len(groups))
	for i := range groups {
		index[groups[i].ID] = i
	}
	for _, script := range Catalog() {
		i, ok := index[script.GroupID()]
		if !ok {
			i = index[commandGroupDeployment]
		}
		groups[i].Scripts = append(groups[i].Scripts, script)
	}
	return groups
}

// Catalog returns the curated list of deployctl-backed operations the dashboard exposes.
//
// Adding a new script: drop it into ./scripts/ and add an entry here. Only
// scripts in this list are executable; anything else is rejected.
func Catalog() []Script {
	return []Script{
		{
			Name: "status.sh", Title: "Status", Summary: "Live tenant health overview.",
			Fields: []Field{
				{Name: "tenant", Label: "Tenant filter", Flag: "--tenant", Type: "text", Placeholder: "(all)"},
				{Name: "json", Label: "JSON output", Flag: "--json", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "list-tenants.sh", Title: "List tenants", Summary: "Tenant pairs and their status.",
		},
		{
			Name: "create-tenant.sh", Title: "Create tenant",
			Summary: "Provision a new tenant (backend + frontend + storage + DB).",
			Danger:  true,
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Required: true, Placeholder: "acme",
					Suggest: []string{"acme", "demo", "dev", "staging", "test"}},
				{Name: "admin_user", Label: "Admin username", Flag: "--env", Type: "text", Required: true, Placeholder: "admin",
					Default: "admin", Suggest: []string{"admin"}},
				{Name: "admin_password", Label: "Admin password", Flag: "--env", Type: "password", Required: true, Secret: true,
					Placeholder: "Strong password for the admin user (min 8 characters)",
					Help:        "Minimum 8 characters required by the backend. Sent as ADMIN_PASSWORD to seed the initial admin account."},
				{Name: "manager_user", Label: "Manager username", Flag: "--env", Type: "text", Placeholder: "manager",
					Suggest: []string{"manager"},
					Help:    "Optional. Leave blank to skip seeding a manager account."},
				{Name: "manager_password", Label: "Manager password", Flag: "--env", Type: "password", Secret: true,
					Placeholder: "Strong password for the manager user (min 8 characters)",
					Help:        "Optional. Minimum 8 characters. Sent as MANAGER_PASSWORD."},
				{Name: "company_name", Label: "Company name", Flag: "--env", Type: "text", Required: true, Placeholder: "ACME Corp"},
				imageVersionField(true),
				componentImageVersionField("backend_image_version", "Backend image channel/tag"),
				componentImageVersionField("frontend_image_version", "Frontend image channel/tag"),
				{Name: "backend_image", Flag: "--backend-image", Type: "hidden"},
				{Name: "frontend_image", Flag: "--frontend-image", Type: "hidden"},
				// Ports are intentionally hidden — operators should not change container ports
				// from the UI; defaults match the upstream images.
				{Name: "backend_port", Flag: "--backend-port", Type: "hidden", Default: "8090"},
				{Name: "frontend_port", Flag: "--frontend-port", Type: "hidden", Default: "8000"},
				{Name: "update", Label: "Update existing tenant", Flag: "--update", Type: "checkbox", Boolean: true,
					Help: "Check this if the tenant already exists and you want to re-deploy or re-seed it. Safe to use after a partial failure."},
				{Name: "no_database", Label: "Skip database", Flag: "--no-database", Type: "checkbox", Boolean: true,
					Help: "Only use this if the backend can boot without a DB, or if you provide DATABASE_URL/DB_* in Env vars."},
				{Name: "dry_run", Label: "Dry run", Flag: "--dry-run", Type: "checkbox", Boolean: true},
				{Name: "envs", Label: "Env vars", Flag: "--env", Type: "kv",
					Help: "One KEY=VALUE per line; each becomes a separate --env flag. Use this for DATABASE_URL or DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD when not provisioning MySQL from this script."},
			},
		},
		{
			Name: "init-tenant-db.sh", Title: "Initialize tenant DB",
			Summary: "Apply schema/migrations from the backend image and seed tenant users.",
			Danger:  true,
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Required: true, Placeholder: "acme"},
				imageVersionFieldForScope(true, "backend"),
				componentImageVersionField("backend_image_version", "Backend image channel/tag"),
				{Name: "backend_image", Flag: "--backend-image", Type: "hidden"},
				{Name: "admin_user", Label: "Admin username", Flag: "--env", Type: "text", Placeholder: "admin",
					Default: "admin", Suggest: []string{"admin"}},
				{Name: "admin_password", Label: "Admin password", Flag: "--env", Type: "password", Secret: true,
					Placeholder: "Strong password for the admin user"},
				{Name: "manager_user", Label: "Manager username", Flag: "--env", Type: "text", Placeholder: "manager",
					Suggest: []string{"manager"}},
				{Name: "manager_password", Label: "Manager password", Flag: "--env", Type: "password", Secret: true,
					Placeholder: "Strong password for the manager user"},
				{Name: "company_name", Label: "Company name", Flag: "--env", Type: "text", Placeholder: "ACME Corp"},
				{Name: "schema_only", Label: "Schema only", Flag: "--schema-only", Type: "checkbox", Boolean: true},
				{Name: "seed_only", Label: "Seed only", Flag: "--seed-only", Type: "checkbox", Boolean: true},
				{Name: "dry_run", Label: "Dry run", Flag: "--dry-run", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "remove-tenant.sh", Title: "Remove tenant", Summary: "Tear down a tenant.", Danger: true,
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Required: true},
				{Name: "keep_data", Label: "Keep data", Flag: "--keep-data", Type: "checkbox", Boolean: true,
					Help: "Preserve persistent tenant files under STORAGE_ROOT/<tenant>. Default: delete."},
				{Name: "keep_backups", Label: "Keep backups", Flag: "--keep-backups", Type: "checkbox", Boolean: true,
					Help: "Preserve backup archives under BACKUP_DIR. Default: delete."},
				{Name: "force", Label: "Force", Flag: "--force", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name:    "cleanup-broken-tenant.sh",
			Title:   "Cleanup broken tenant",
			Summary: "Repair Dokku storage registry permissions and force-remove a half-created tenant.",
			Danger:  true,
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Required: true, Placeholder: "test5"},
				{Name: "delete_data", Label: "Delete data", Flag: "--delete-data", Type: "checkbox", Boolean: true,
					Help: "Deletes persistent tenant files under STORAGE_ROOT/<tenant>."},
				{Name: "force", Label: "Force", Flag: "--force", Type: "checkbox", Boolean: true,
					Help: "Required for unattended dashboard cleanup."},
				{Name: "skip_storage_repair", Label: "Skip storage registry repair", Flag: "--skip-storage-repair", Type: "checkbox", Boolean: true},
				{Name: "dry_run", Label: "Dry run", Flag: "--dry-run", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "deploy-all.sh", Title: "Deploy version image",
			Summary: "Roll one versioned backend or frontend image to all tenants (canary-first), or a single tenant.",
			Danger:  true,
			Fields: []Field{
				imageVersionFieldForScope(true, "role"),
				componentImageVersionField("backend_image_version", "Backend image channel/tag"),
				componentImageVersionField("frontend_image_version", "Frontend image channel/tag"),
				{Name: "_pos_image", Type: "hidden"},
				{Name: "type", Label: "App type", Flag: "--type", Type: "select", Options: []string{"backend", "frontend"}, Default: "backend"},
				{Name: "tenant", Label: "Single tenant", Flag: "--tenant", Type: "text"},
				{Name: "skip_canary", Label: "Skip canary", Flag: "--skip-canary", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "rollback-tenant.sh", Title: "Rollback tenant",
			Summary: "Roll a tenant back to a previous image.", Danger: true,
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Required: true},
				{Name: "type", Label: "App type", Flag: "--type", Type: "select", Options: []string{"backend", "frontend"}, Default: "backend"},
				imageVersionFieldForScope(false, "role"),
				{Name: "to", Flag: "--to", Type: "hidden"},
				{Name: "list", Label: "List recent deploys", Flag: "--list", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "set-tenant-image.sh", Title: "Pin image",
			Summary: "Pin (or unpin) a tenant to a specific image.",
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Placeholder: "(omit with --list)"},
				{Name: "type", Label: "App type", Type: "select", Options: []string{"both", "backend", "frontend"}, Default: "both",
					Help: "Choose both only when the tag is published in both repositories."},
				imageVersionFieldForScope(false, "role"),
				{Name: "backend", Flag: "--backend", Type: "hidden"},
				{Name: "frontend", Flag: "--frontend", Type: "hidden"},
				{Name: "unpin", Label: "Unpin", Flag: "--unpin", Type: "checkbox", Boolean: true},
				{Name: "list", Label: "List pins", Flag: "--list", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "update-tenant.sh", Title: "Update tenant", Summary: "Update version, env, scale, restart.",
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Required: true},
				imageVersionField(false),
				optionalComponentImageVersionField("backend_image_version", "Backend image channel/tag"),
				optionalComponentImageVersionField("frontend_image_version", "Frontend image channel/tag"),
				{Name: "backend_image", Flag: "--backend-image", Type: "hidden"},
				{Name: "frontend_image", Flag: "--frontend-image", Type: "hidden"},
				{Name: "scale", Label: "Backend scale", Flag: "--scale", Type: "text", Placeholder: "1"},
				{Name: "restart", Label: "Restart", Flag: "--restart", Type: "checkbox", Boolean: true},
				{Name: "envs", Label: "Env vars", Flag: "--env", Type: "kv"},
			},
		},
		{
			Name: "backup-tenant.sh", Title: "Backup tenant", Summary: "Dump a tenant's data + DB.",
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant (or leave blank with --all)", Type: "text"},
				{Name: "all", Label: "All tenants", Flag: "--all", Type: "checkbox", Boolean: true},
				{Name: "origin", Label: "Origin", Flag: "--origin", Type: "select", Options: []string{"user", "auto"}, Default: "user",
					Help: "user backups are protected from the retention policy; auto backups are pruned by policy."},
				{Name: "owner", Label: "Owner", Flag: "--owner", Type: "text", Placeholder: "admin",
					Help: "Owner tag recorded in the backup manifest (used for delete ownership checks)."},
				{Name: "retention_days", Label: "Retention days", Flag: "--retention-days", Type: "text", Placeholder: "30"},
			},
		},
		{
			Name: "manage-backups.sh", Title: "Manage backups",
			Summary: "List, verify, delete, and prune tenant backups. User backups are protected from policy prune.",
			Fields: []Field{
				{Name: "_pos_action", Label: "Action", Type: "select", Required: true,
					Options: []string{"list", "verify", "delete", "prune"}, Default: "list"},
				{Name: "_pos_id", Label: "Backup ID", Type: "text",
					Placeholder: "acme_20250101_120000",
					Help:        "Required for verify/delete. Leave blank for list/prune."},
				{Name: "json", Label: "JSON output", Flag: "--json", Type: "checkbox", Boolean: true},
				{Name: "owner", Label: "Owner", Flag: "--owner", Type: "text",
					Help: "For delete: must match a user backup's owner. For list: filter by owner."},
				{Name: "force", Label: "Force (operator override)", Flag: "--force", Type: "checkbox", Boolean: true,
					Help: "Delete a user backup regardless of owner. Use with care."},
				{Name: "retention_days", Label: "Retention days (prune)", Flag: "--retention-days", Type: "text", Placeholder: "30"},
				{Name: "dry_run", Label: "Dry run (prune)", Flag: "--dry-run", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "restore-tenant.sh", Title: "Restore / rollback",
			Summary: "Restore a tenant's files and/or database from any backup. Takes a verified safety backup first.",
			Danger:  true,
			Fields: []Field{
				{Name: "_pos_name", Label: "Tenant name", Type: "text", Required: true, Placeholder: "acme"},
				{Name: "from", Label: "Backup ID", Flag: "--from", Type: "text", Required: true,
					Placeholder: "acme_20250101_120000",
					Help:        "The backup set to restore (see Manage backups → list)."},
				{Name: "files_only", Label: "Files only", Flag: "--files-only", Type: "checkbox", Boolean: true},
				{Name: "db_only", Label: "Database only", Flag: "--db-only", Type: "checkbox", Boolean: true},
				{Name: "no_safety_backup", Label: "Skip safety backup", Flag: "--no-safety-backup", Type: "checkbox", Boolean: true,
					Help: "NOT recommended. By default a verified backup of the current state is taken before restoring."},
				{Name: "dry_run", Label: "Dry run", Flag: "--dry-run", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "tail-logs.sh", Title: "Aggregate logs",
			Summary: "Tail logs from one or all tenants. Use --since to limit.",
			Fields: []Field{
				{Name: "tenant", Label: "Tenant", Flag: "--tenant", Type: "text"},
				{Name: "type", Label: "App type", Flag: "--type", Type: "select", Options: []string{"backend", "frontend"}},
				{Name: "grep", Label: "Pattern", Flag: "--grep", Type: "text"},
				{Name: "since", Label: "Since (e.g. 1h)", Flag: "--since", Type: "text"},
			},
		},
		{
			Name: "verify-mysql.sh", Title: "Verify MySQL", Summary: "Sanity-check the admin connection from a container.",
		},
		{
			Name: "fix-dokku-hostname.sh", Title: "Fix Dokku hostname",
			Summary: "Silence the 'sudo: unable to resolve host' warning.",
		},
		{
			Name: "setup-nats.sh", Title: "Setup NATS",
			Summary: "Run a NATS JetStream server on the host (idempotent). Backends connect via host.docker.internal:4222.",
		},
		{
			Name: "discover-dokku-nginx.sh", Title: "Discover Dokku nginx",
			Summary: "Print the IP/port Dokku nginx is reachable on, plus a ready-to-paste edge-nginx wildcard server block.",
		},
		{
			Name: "watch-dokku-traffic.sh", Title: "Watch Dokku traffic",
			Summary: "Tail Dokku nginx access logs prefixed with the tenant (vhost) name; verify *.<base-domain> routing.",
		},
		{
			Name: "auto-pull.sh", Title: "Run auto-pull",
			Summary: "Force one auto-pull cycle (normally cron does this every 2m).",
			Fields: []Field{
				{Name: "type", Label: "Type", Flag: "--type", Type: "select", Options: []string{"both", "backend", "frontend"}},
			},
		},
		{
			Name: "setup-dev-tenant.sh", Title: "Setup dev tenant", Summary: "Idempotently create the dev tenant.",
			Fields: []Field{
				{Name: "name", Label: "Tenant name", Flag: "--name", Type: "text"},
				{Name: "tag", Label: "Image tag", Flag: "--tag", Type: "text", Default: DefaultImageVersion(),
					ImageScope: "role",
					Help:       "The backend tag; enable the frontend option only when the same tag exists in both repositories."},
				{Name: "frontend", Label: "Pin frontend too", Flag: "--frontend", Type: "checkbox", Boolean: true},
			},
		},
		{
			Name: "cleanup-old-files.sh", Title: "Cleanup old files",
			Summary: "Remove leftover Compose+Traefik files from the pre-Dokku layout.", Danger: true,
		},
	}
}

// Find returns the script with the given file name or slug (file name
// without the .sh suffix), or nil.
func Find(name string) *Script {
	cat := Catalog()
	for i := range cat {
		if cat[i].Name == name || cat[i].Slug() == name {
			s := cat[i]
			return &s
		}
	}
	return nil
}

// Runner executes scripts in a one-shot sidecar container so the dashboard
// image doesn't need bash / mysql-client / curl installed locally.
type Runner struct {
	dockerBin       string
	runnerImage     string // e.g. "mysql:8.0" — has bash, curl, mysql client
	scriptsHostPath string // host path to /opt/deployment (mounted into runner)
	configFile      string // optional --config path inside runner
	backupDir       string // host path to backup dir (mounted rw so scripts can write)
	storageRoot     string // host path to persistent tenant files (mounted rw)
}

// NewRunner builds a runner. scriptsHostPath is the path on the docker
// daemon's host (NOT inside the dashboard container) to the deployment dir.
func NewRunner(dockerBin, runnerImage, scriptsHostPath, configFile string) *Runner {
	if runnerImage == "" {
		runnerImage = "dokku/dokku:latest"
	}
	return &Runner{
		dockerBin:       dockerBin,
		runnerImage:     runnerImage,
		scriptsHostPath: scriptsHostPath,
		configFile:      configFile,
	}
}

// SetBackupDir configures the host path for tenant backups.
// The directory will be mounted into runner containers so scripts can write backup files.
func (r *Runner) SetBackupDir(dir string) {
	r.backupDir = dir
}

// SetStorageRoot configures the host path for persistent tenant files.
// The directory is mounted into runner containers so create, backup, restore,
// and cleanup scripts operate on the same files as Dokku.
func (r *Runner) SetStorageRoot(dir string) {
	r.storageRoot = dir
}

func (r *Runner) volumeArgs() []string {
	var args []string
	if r.backupDir != "" {
		args = append(args, "-v", r.backupDir+":"+r.backupDir)
		args = append(args, "-e", "BACKUP_DIR="+r.backupDir)
	}
	if r.storageRoot != "" {
		args = append(args, "-v", r.storageRoot+":"+r.storageRoot)
		args = append(args, "-e", "STORAGE_ROOT="+r.storageRoot)
	}
	return args
}

func (r *Runner) dockerArgs(dockerSocket string) []string {
	full := []string{
		"run", "--rm", "-i",
		"-e", "MYSQL_CLIENT_MODE=docker",
		"-e", "BASE_DOMAIN=" + os.Getenv("BASE_DOMAIN"),
		"-e", "PUBLIC_PROTOCOL=" + os.Getenv("PUBLIC_PROTOCOL"),
		"-e", "ENABLE_SSL=" + os.Getenv("ENABLE_SSL"),
		"-e", "TENANT_NAME_PREFIX=" + os.Getenv("TENANT_NAME_PREFIX"),
		"-e", "TENANT_NAME_PREFIX_OVERRIDE=" + os.Getenv("TENANT_NAME_PREFIX"),
		"-e", "DASHBOARD_ENV=" + os.Getenv("DASHBOARD_ENV"),
		"-v", dockerSocket,
		"-v", r.scriptsHostPath + ":/opt/deployment:ro",
		"--network", "host",
	}
	return append(full, r.volumeArgs()...)
}

// safeArg only allows characters that cannot escape an argv slot. We split on
// whitespace ourselves and pass each piece as a discrete argv element, but we
// still defensively reject anything that looks like a shell metachar so a
// pasted command can't surprise us. Spaces and tabs are safe in arg values.
var safeArg = regexp.MustCompile(`^[A-Za-z0-9._@/:=+,\-\s]+$`)

func validateArgs(argv []string) error {
	for _, a := range argv {
		if a == "" {
			return errors.New("empty argument")
		}
		if !safeArg.MatchString(a) {
			return fmt.Errorf("argument %q contains disallowed characters", a)
		}
	}
	return nil
}

// Run executes a script with already-built argv (extra flags after the script
// name). Sanitized output is streamed to w line-by-line as SSE `data:` frames.
func (r *Runner) Run(ctx context.Context, w io.Writer, scriptName string, argv []string) error {
	return r.RunWithCallback(ctx, w, scriptName, argv, nil)
}

// RunWithCallback executes a script like Run and invokes onLine for every
// normalized output line before it is streamed to the caller. The callback is
// useful for durable operation history and must not write to w.
func (r *Runner) RunWithCallback(ctx context.Context, w io.Writer, scriptName string, argv []string, onLine func(string)) error {
	sc := Find(scriptName)
	if sc == nil {
		return fmt.Errorf("script %q is not in the catalog", scriptName)
	}
	img := sc.Image
	if img == "" {
		img = r.runnerImage
	}
	if r.scriptsHostPath == "" {
		return errors.New("SCRIPTS_HOST_PATH is not set; cannot mount scripts into runner container")
	}
	if err := validateArgs(argv); err != nil {
		return err
	}
	if r.configFile != "" {
		argv = append(argv, "--config", r.configFile)
	}

	// Docker socket path: Linux/macOS use a Unix socket; Windows Docker Desktop
	// exposes a named pipe. We detect by checking for the pipe path first.
	dockerSocket := "/var/run/docker.sock:/var/run/docker.sock"
	if _, err := os.Stat(`\\.\pipe\dockerDesktopLinuxEngine`); err == nil {
		dockerSocket = `//./pipe/dockerDesktopLinuxEngine://./pipe/dockerDesktopLinuxEngine`
	} else if _, err := os.Stat(`\\.\pipe\docker_engine`); err == nil {
		dockerSocket = `//./pipe/docker_engine://./pipe/docker_engine`
	}

	full := r.dockerArgs(dockerSocket)
	full = append(full,
		img,
		// CRLF tolerance: scripts authored on Windows have \r line endings
		// which break bash. Stage to a writable dir, strip CRLF, then exec.
		"bash", "-c", `
set -e
mkdir -p /tmp/dep
cp -r /opt/deployment/scripts /tmp/dep/
[ -f /opt/deployment/config.env ] && cp /opt/deployment/config.env /tmp/dep/ || true
[ -f /opt/deployment/install.env ] && cp /opt/deployment/install.env /tmp/dep/ || true
find /tmp/dep -type f \( -name '*.sh' -o -name '*.env' \) -exec sed -i 's/\r$//' {} +
cd /tmp/dep
NAME="$1"; shift
exec bash "scripts/deployctl.sh" "script" "$NAME" "$@"
`,
		"--", scriptName,
	)
	full = append(full, argv...)

	cmd := exec.CommandContext(ctx, r.dockerBin, full...)
	cmd.Env = append(os.Environ(), "TERM=dumb")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return err
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := ansi.Strip(scanner.Text())
		if onLine != nil {
			onLine(line)
		}
		if _, werr := fmt.Fprintf(w, "data: %s\n\n", line); werr != nil {
			_ = cmd.Process.Kill()
			break
		}
		if f, ok := w.(interface{ Flush() }); ok {
			f.Flush()
		}
	}
	return cmd.Wait()
}

func stripAnsi(s string) string { return ansi.Strip(s) }
