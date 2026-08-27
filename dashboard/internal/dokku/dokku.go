// Package dokku wraps the docker / dokku CLIs to inspect and control apps.
//
// All operations shell out to the local docker binary (which must be mounted
// from the host) and execute dokku commands inside the dokku-in-docker
// container via `docker exec`.
package dokku

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/abdul-mohsen/deployment/dashboard/internal/ansi"
)

// Client is a thin wrapper around the docker + dokku CLIs.
type Client struct {
	dockerBin    string
	dokkuName    string
	probeCommand func(context.Context, ...string) (string, string, error)
}

// New returns a client. dockerBin is the docker executable on the host
// (typically "docker"); dokkuName is the dokku container name (typically
// "dokku").
func New(dockerBin, dokkuName string) *Client {
	return &Client{dockerBin: dockerBin, dokkuName: dokkuName}
}

// App is a single Dokku app with the data needed to render the list page.
type App struct {
	Name           string
	Role           string // backend / frontend / app
	Tenant         string
	State          string // running / stopped / not-deployed / restarting / mixed / unknown
	LifecycleState string
	LifecycleError string
	Image          string
	Version        string
	RestartCnt     string
	Procs          []string
	IntPort        string
	HostPorts      string
	Domains        []string
	HTTPCode       string // Deprecated compatibility alias for Probe.HTTPCode.
	Probe          HealthProbe
	ContainerID    string
	PublicURL   string
}

// HealthProbe describes the latest application HTTP probe independently from
// the app's lifecycle state.
type HealthProbe struct {
	Status            string // healthy / http-error / failed / unavailable / unknown
	HTTPCode          string
	CheckedAt         time.Time
	Error             string
	UnavailableReason string
}

const (
	ProbeStatusHealthy     = "healthy"
	ProbeStatusHTTPError   = "http-error"
	ProbeStatusFailed      = "failed"
	ProbeStatusUnavailable = "unavailable"
	ProbeStatusUnknown     = "unknown"
)

type containerSummary struct {
	State      string
	Image      string
	Version    string
	RestartCnt string
	Error      string
}

var nameLine = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// AppsList returns all Dokku apps registered on the host.
func (c *Client) AppsList(ctx context.Context) ([]string, error) {
	out, err := c.exec(ctx, c.dockerBin, "exec", "-i", c.dokkuName, "dokku", "--quiet", "apps:list")
	if err != nil {
		return nil, err
	}
	var apps []string
	for _, ln := range strings.Split(out, "\n") {
		ln = strings.TrimSpace(ln)
		if nameLine.MatchString(ln) {
			apps = append(apps, ln)
		}
	}
	return apps, nil
}

// AppSummary is optimized for the dashboard grid. It uses Docker metadata,
// domains, and one bounded HTTP probe per app so large tenant lists remain
// responsive when collected by the dashboard worker pool.
func (c *Client) AppSummary(ctx context.Context, name string) App {
	return c.AppSummaryFrom(ctx, name, c.ContainerIDsByApp(ctx)[name], c.DomainMap(ctx)[name])
}

func (c *Client) AppSummaryFrom(ctx context.Context, name, containerID string, domains []string) App {
	app := App{
		Name:           name,
		Role:           roleOf(name),
		Tenant:         tenantOf(name),
		HTTPCode:       "000",
		LifecycleState: "not-deployed",
		Probe:          unavailableProbe("no container is available"),
		Domains:        domains,
	}
	app.ContainerID = containerID
	if app.ContainerID == "" {
		app.State = "not-deployed"
		return app
	}
	container := c.containerSummary(ctx, app.ContainerID)
	switch container.State {
	case "running":
		app.State = "running"
	case "exited":
		app.State = "stopped"
	case "":
		app.State = "unknown"
	default:
		app.State = container.State
	}
	app.LifecycleState = app.State
	app.LifecycleError = container.Error
	app.Image = container.Image
	app.Version = container.Version
	if app.Version == "" {
		app.Version = imageTag(app.Image)
	}
	app.RestartCnt = container.RestartCnt
	app.Probe = c.appProbe(ctx, name, app.Role, app.State)
	if app.Probe.Status == ProbeStatusUnknown && app.LifecycleError != "" {
		app.Probe.Error = app.LifecycleError
	}
	app.HTTPCode = app.Probe.HTTPCode
	return app
}

func (c *Client) containerSummary(ctx context.Context, cid string) containerSummary {
	out, err := c.exec(ctx, c.dockerBin, "inspect", "-f", `{{.State.Status}}
{{.Config.Image}}
{{.RestartCount}}
{{range .Config.Env}}{{println .}}{{end}}`, cid)
	lines := strings.Split(out, "\n")
	summary := containerSummary{}
	if len(lines) > 0 {
		summary.State = strings.TrimSpace(lines[0])
	}
	if len(lines) > 1 {
		summary.Image = strings.TrimSpace(lines[1])
	}
	if len(lines) > 2 {
		summary.RestartCnt = strings.TrimSpace(lines[2])
	}
	for _, line := range lines[3:] {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "APP_IMAGE_VERSION=") {
			summary.Version = strings.TrimPrefix(line, "APP_IMAGE_VERSION=")
			break
		}
	}
	if err != nil {
		summary.Error = err.Error()
	}
	return summary
}

func (c *Client) ContainerIDsByApp(ctx context.Context) map[string]string {
	out, _ := c.exec(ctx, c.dockerBin, "ps", "-a",
		"--filter", "label=com.dokku.app-name",
		"--format", `{{.ID}} {{.Label "com.dokku.app-name"}} {{.Label "com.dokku.process-type"}}`)
	containers := map[string]string{}
	processTypes := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		containerID := fields[0]
		appName := fields[1]
		processType := ""
		if len(fields) > 2 {
			processType = fields[2]
		}
		if containers[appName] == "" || (processTypes[appName] != "web" && processType == "web") {
			containers[appName] = containerID
			processTypes[appName] = processType
		}
	}
	return containers
}

func (c *Client) DomainMap(ctx context.Context) map[string][]string {
	script := `for app_dir in /home/dokku/*; do
  [ -f "$app_dir/VHOST" ] || continue
  app="${app_dir##*/}"
  domains="$(tr '\n' ' ' < "$app_dir/VHOST" | xargs)"
  printf '%s\t%s\n' "$app" "$domains"
done`
	out, _ := c.exec(ctx, c.dockerBin, "exec", "-i", c.dokkuName, "bash", "-lc", script)
	domains := map[string][]string{}
	for _, line := range strings.Split(out, "\n") {
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" {
			continue
		}
		domains[strings.TrimSpace(parts[0])] = strings.Fields(parts[1])
	}
	return domains
}

// AppDetails populates an App with current state from docker + dokku.
func (c *Client) AppDetails(ctx context.Context, name string) App {
	a := App{Name: name, Role: roleOf(name), Tenant: tenantOf(name)}
	a.ContainerID = c.containerID(ctx, name)
	a.State, a.LifecycleError = c.appStateResult(ctx, name, a.ContainerID)
	a.LifecycleState = a.State
	if a.ContainerID != "" {
		a.Image = c.inspectField(ctx, a.ContainerID, "{{.Config.Image}}")
		a.Version = c.envField(ctx, a.ContainerID, "APP_IMAGE_VERSION")
		if a.Version == "" {
			a.Version = imageTag(a.Image)
		}
		a.RestartCnt = c.inspectField(ctx, a.ContainerID, "{{.RestartCount}}")
		a.HostPorts = c.hostPorts(ctx, a.ContainerID)
	}
	a.IntPort = c.intPort(ctx, name)
	a.Procs = c.procTypes(ctx, name)
	a.Domains = c.domains(ctx, name)
	if a.ContainerID == "" && a.State == "running" {
		a.Probe = unavailableProbe("lifecycle reports running but no container was found")
	} else {
		a.Probe = c.appProbe(ctx, name, a.Role, a.State)
	}
	if a.Probe.Status == ProbeStatusUnknown && a.LifecycleError != "" {
		a.Probe.Error = a.LifecycleError
	}
	a.HTTPCode = a.Probe.HTTPCode
	return a
}

func (c *Client) containerIDAny(ctx context.Context, app string) string {
	id, _ := c.exec(ctx, c.dockerBin, "ps", "-a",
		"--filter", "label=com.dokku.app-name="+app,
		"--filter", "label=com.dokku.process-type=web",
		"--format", "{{.ID}}")
	id = firstLine(id)
	if id == "" {
		id, _ = c.exec(ctx, c.dockerBin, "ps", "-a",
			"--filter", "label=com.dokku.app-name="+app,
			"--format", "{{.ID}}")
		id = firstLine(id)
	}
	return id
}

func (c *Client) containerID(ctx context.Context, app string) string {
	id, _ := c.exec(ctx, c.dockerBin, "ps",
		"--filter", "label=com.dokku.app-name="+app,
		"--filter", "label=com.dokku.process-type=web",
		"--format", "{{.ID}}")
	id = firstLine(id)
	if id == "" {
		id, _ = c.exec(ctx, c.dockerBin, "ps",
			"--filter", "label=com.dokku.app-name="+app,
			"--format", "{{.ID}}")
		id = firstLine(id)
	}
	return id
}

func (c *Client) appState(ctx context.Context, app, cid string) string {
	state, _ := c.appStateResult(ctx, app, cid)
	return state
}

func (c *Client) appStateResult(ctx context.Context, app, cid string) (string, string) {
	report, err := c.dokku(ctx, "ps:report", app)
	if err != nil {
		return "unknown", commandError(report, err)
	}
	deployed := fieldFromReport(report, "Deployed:")
	running := fieldFromReport(report, "Running:")
	if deployed == "" {
		return "unknown", "Dokku did not report a deployment state"
	}
	if !strings.EqualFold(deployed, "true") {
		return "not-deployed", ""
	}
	if running == "" {
		return "unknown", "Dokku did not report a running state"
	}
	state := "unknown"
	switch strings.ToLower(running) {
	case "true":
		state = "running"
	case "false":
		state = "stopped"
	case "mixed":
		state = "mixed"
	}
	if cid != "" {
		cs, inspectErr := c.inspectFieldResult(ctx, cid, "{{.State.Status}}")
		if inspectErr != nil {
			return "unknown", commandError(cs, inspectErr)
		}
		switch cs {
		case "restarting", "exited", "dead", "paused":
			state = cs
		}
	}
	if state == "unknown" {
		return state, "Dokku did not report a known lifecycle state"
	}
	return state, ""
}

func (c *Client) inspectField(ctx context.Context, cid, tmpl string) string {
	out, _ := c.inspectFieldResult(ctx, cid, tmpl)
	return strings.TrimSpace(out)
}

func (c *Client) inspectFieldResult(ctx context.Context, cid, tmpl string) (string, error) {
	out, err := c.exec(ctx, c.dockerBin, "inspect", "-f", tmpl, cid)
	return strings.TrimSpace(out), err
}

func (c *Client) hostPorts(ctx context.Context, cid string) string {
	tmpl := `{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostPort}}->{{$p}} {{end}}{{end}}`
	out, _ := c.exec(ctx, c.dockerBin, "inspect", "-f", tmpl, cid)
	return strings.TrimSpace(out)
}

func (c *Client) exposedPort(ctx context.Context, cid string) string {
	tmpl := `{{range $p, $_ := .Config.ExposedPorts}}{{println $p}}{{end}}`
	out, _ := c.exec(ctx, c.dockerBin, "inspect", "-f", tmpl, cid)
	port := firstLine(out)
	port = strings.TrimSuffix(port, "/tcp")
	port = strings.TrimSuffix(port, "/udp")
	return strings.TrimSpace(port)
}

func (c *Client) envField(ctx context.Context, cid, key string) string {
	out, _ := c.exec(ctx, c.dockerBin, "inspect", "-f", `{{range .Config.Env}}{{println .}}{{end}}`, cid)
	prefix := key + "="
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			return strings.TrimPrefix(line, prefix)
		}
	}
	return ""
}

func imageTag(image string) string {
	lastSlash := strings.LastIndex(image, "/")
	lastColon := strings.LastIndex(image, ":")
	if lastColon > lastSlash {
		return image[lastColon+1:]
	}
	return ""
}

func (c *Client) intPort(ctx context.Context, app string) string {
	out, err := c.dokku(ctx, "ports:report", app)
	if err != nil {
		return ""
	}
	for _, ln := range strings.Split(out, "\n") {
		if strings.Contains(ln, "Ports map:") {
			parts := strings.Split(ln, ":")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	return ""
}

func (c *Client) procTypes(ctx context.Context, app string) []string {
	out, err := c.dokku(ctx, "ps:scale", app)
	if err != nil {
		return nil
	}
	var procs []string
	for i, ln := range strings.Split(out, "\n") {
		if i < 2 {
			continue
		}
		f := strings.Fields(ln)
		if len(f) > 0 {
			procs = append(procs, f[0])
		}
	}
	return procs
}

func (c *Client) domains(ctx context.Context, app string) []string {
	out, err := c.dokku(ctx, "domains:report", app, "--domains-app-vhosts")
	if err != nil {
		return nil
	}
	out = strings.TrimSpace(out)
	if out == "" {
		return nil
	}
	return strings.Fields(out)
}

func (c *Client) appProbe(ctx context.Context, app, role, state string) HealthProbe {
	switch state {
	case "running":
		path := "/"
		if role == "backend" {
			path = "/healthz"
		}
		return c.httpProbeResult(ctx, app, path)
	case "unknown", "":
		return unknownProbe("lifecycle state is unknown; probe was not attempted")
	default:
		return unavailableProbe("probe not attempted because lifecycle state is " + state)
	}
}

// httpProbe is retained as a compatibility helper for callers that only need
// the legacy HTTP code.
func (c *Client) httpProbe(ctx context.Context, app, path string) string {
	return c.httpProbeResult(ctx, app, path).HTTPCode
}

func (c *Client) httpProbeResult(ctx context.Context, app, path string) HealthProbe {
	checkedAt := time.Now().UTC()
	probeCtx, cancel := context.WithTimeout(ctx, 7*time.Second)
	defer cancel()

	args := []string{"exec", "-i", c.dokkuName, "bash", "-lc",
		fmt.Sprintf(`curl -sS -o /dev/null -w '%%{http_code}' --max-time 5 http://%s.web%s`, app, path)}
	stdoutText, stderrText, err := c.runProbeCommand(probeCtx, args...)

	code := normalizeHTTPCode(stdoutText)
	if err != nil {
		code = "000"
		message := strings.TrimSpace(stderrText)
		if message == "" {
			message = commandError("", err)
		}
		if message == "" {
			message = "probe command failed"
		}
		return HealthProbe{
			Status:    ProbeStatusFailed,
			HTTPCode:  code,
			CheckedAt: checkedAt,
			Error:     message,
		}
	}
	if code == "000" {
		message := strings.TrimSpace(stderrText)
		if message == "" {
			message = "probe returned HTTP 000"
		}
		return HealthProbe{
			Status:    ProbeStatusFailed,
			HTTPCode:  code,
			CheckedAt: checkedAt,
			Error:     message,
		}
	}
	return HealthProbe{
		Status:    probeStatusForHTTPCode(code),
		HTTPCode:  code,
		CheckedAt: checkedAt,
	}
}

func (c *Client) runProbeCommand(ctx context.Context, args ...string) (string, string, error) {
	if c.probeCommand != nil {
		return c.probeCommand(ctx, args...)
	}
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, c.dockerBin, args...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

func probeStatusForHTTPCode(code string) string {
	if !isHTTPCode(code) || code == "000" {
		return ProbeStatusUnknown
	}
	if code[0] == '2' || code[0] == '3' {
		return ProbeStatusHealthy
	}
	return ProbeStatusHTTPError
}

func normalizeHTTPCode(out string) string {
	out = strings.TrimSpace(out)
	if isHTTPCode(out) {
		return out
	}
	for _, field := range strings.Fields(out) {
		if isHTTPCode(field) {
			return field
		}
	}
	return "000"
}

func isHTTPCode(code string) bool {
	if len(code) != 3 {
		return false
	}
	for i := range code {
		if code[i] < '0' || code[i] > '9' {
			return false
		}
	}
	return true
}

func unavailableProbe(reason string) HealthProbe {
	return HealthProbe{
		Status:            ProbeStatusUnavailable,
		HTTPCode:          "000",
		CheckedAt:         time.Now().UTC(),
		UnavailableReason: reason,
	}
}

func unknownProbe(reason string) HealthProbe {
	return HealthProbe{
		Status:    ProbeStatusUnknown,
		HTTPCode:  "000",
		CheckedAt: time.Now().UTC(),
		Error:     reason,
	}
}

// Action runs a Dokku lifecycle action against an app.
//
// verb must be one of: start, stop, restart, rebuild.
func (c *Client) Action(ctx context.Context, app, verb string) (string, error) {
	switch verb {
	case "start", "stop", "restart", "rebuild":
	default:
		return "", fmt.Errorf("invalid action %q", verb)
	}
	return c.dokku(ctx, "ps:"+verb, app)
}

// StreamLogs invokes `dokku logs --tail -t <app>` and writes sanitized lines
// to w until the context is cancelled. The writer is flushed after every line
// if it implements http.Flusher (caller's responsibility — see web.handleLogs).
func (c *Client) StreamLogs(ctx context.Context, app string, w io.Writer, onLine func(string)) error {
	cmd := exec.CommandContext(ctx, c.dockerBin, "exec", "-i", c.dokkuName,
		"dokku", "logs", app, "--tail", "-t")
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
		if _, err := fmt.Fprintf(w, "data: %s\n\n", line); err != nil {
			_ = cmd.Process.Kill()
			break
		}
		if f, ok := w.(interface{ Flush() }); ok {
			f.Flush()
		}
	}
	_ = cmd.Wait()
	return scanner.Err()
}

// DokkuContainerStatus returns up, down, or unavailable and keeps command
// failures separate from a confirmed non-running Dokku container.
func (c *Client) DokkuContainerStatus(ctx context.Context) (string, error) {
	out, err := c.exec(ctx, c.dockerBin, "inspect", "-f", "{{.State.Status}}", c.dokkuName)
	if err != nil {
		return "unavailable", fmt.Errorf("%s", commandError(out, err))
	}
	switch strings.TrimSpace(out) {
	case "running":
		return "up", nil
	case "":
		return "unavailable", fmt.Errorf("Dokku container status was empty")
	default:
		return "down", nil
	}
}

// DokkuContainerHealthy returns true when the dokku container is running.
func (c *Client) DokkuContainerHealthy(ctx context.Context) bool {
	status, _ := c.DokkuContainerStatus(ctx)
	return status == "up"
}

func (c *Client) dokku(ctx context.Context, args ...string) (string, error) {
	full := append([]string{"exec", "-i", c.dokkuName, "dokku"}, args...)
	return c.exec(ctx, c.dockerBin, full...)
}

func (c *Client) exec(ctx context.Context, name string, args ...string) (string, error) {
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, name, args...).CombinedOutput()
	return string(out), err
}

func commandError(output string, err error) string {
	if message := strings.TrimSpace(output); message != "" {
		return message
	}
	if err != nil {
		return err.Error()
	}
	return ""
}

// Helpers ---------------------------------------------------------------------

// ConfigGet returns the value of a single Dokku config var for an app.
func (c *Client) ConfigGet(ctx context.Context, app, key string) (string, error) {
	out, err := c.exec(ctx, c.dockerBin, "exec", "-i", c.dokkuName,
		"dokku", "config:get", app, key)
	return strings.TrimSpace(out), err
}

// ConfigSet sets one or more KEY=VALUE pairs for a Dokku app (no-restart).
func (c *Client) ConfigSet(ctx context.Context, app string, kvs map[string]string) error {
	args := []string{"exec", "-i", c.dokkuName, "dokku", "config:set", "--no-restart", app}
	for k, v := range kvs {
		args = append(args, k+"="+v)
	}
	_, err := c.exec(ctx, c.dockerBin, args...)
	return err
}

func roleOf(app string) string {
	switch {
	case strings.HasSuffix(app, "-backend"):
		return "backend"
	case strings.HasSuffix(app, "-frontend"):
		return "frontend"
	default:
		return "app"
	}
}

func tenantOf(app string) string {
	switch {
	case strings.HasSuffix(app, "-backend"):
		return strings.TrimSuffix(app, "-backend")
	case strings.HasSuffix(app, "-frontend"):
		return strings.TrimSuffix(app, "-frontend")
	default:
		return app
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return strings.TrimSpace(s)
}

func fieldFromReport(report, label string) string {
	for _, ln := range strings.Split(report, "\n") {
		if i := strings.Index(ln, label); i >= 0 {
			return strings.TrimSpace(ln[i+len(label):])
		}
	}
	return ""
}
