package web

import (
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strings"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
)

type fleetOpenState struct {
	URL         string `json:"url"`
	Unavailable string `json:"unavailable"`
}

type fleetBootstrap struct {
	Apps []fleetAppWire            `json:"apps"`
	Open map[string]fleetOpenState `json:"open"`
}

type fleetAppWire struct {
	Name      string `json:"name"`
	Role      string `json:"role"`
	Tenant    string `json:"tenant"`
	State     string `json:"state"`
	Image     string `json:"image"`
	Version   string `json:"version"`
	HTTP      string `json:"http"`
	IntPort   string `json:"int_port"`
	HostPorts string `json:"host_ports"`
	Procs     string `json:"procs"`
	Domains   string `json:"domains"`
}

func newFleetBootstrap(apps []dokku.App) fleetBootstrap {
	wireApps := make([]fleetAppWire, 0, len(apps))
	for _, app := range apps {
		wireApps = append(wireApps, fleetAppWire{
			Name:      app.Name,
			Role:      app.Role,
			Tenant:    app.Tenant,
			State:     app.State,
			Image:     app.Image,
			Version:   app.Version,
			HTTP:      app.HTTPCode,
			IntPort:   app.IntPort,
			HostPorts: app.HostPorts,
			Procs:     strings.Join(app.Procs, ","),
			Domains:   strings.Join(app.Domains, ","),
		})
	}
	return fleetBootstrap{
		Apps: wireApps,
		Open: fleetOpenStates(apps),
	}
}

func fleetOpenStates(apps []dokku.App) map[string]fleetOpenState {
	grouped := make(map[string][]dokku.App)
	for _, app := range apps {
		tenant := strings.TrimSpace(app.Tenant)
		if tenant == "" {
			tenant = tenantFromAppName(app.Name)
		}
		if tenant == "" {
			continue
		}
		grouped[tenant] = append(grouped[tenant], app)
	}

	states := make(map[string]fleetOpenState, len(grouped))
	for tenant, tenantApps := range grouped {
		states[tenant] = fleetOpenStateForApps(tenantApps)
	}
	return states
}

func fleetOpenStateForApps(apps []dokku.App) fleetOpenState {
	if len(apps) == 0 {
		return fleetOpenState{}
	}

	ordered := append([]dokku.App(nil), apps...)
	sort.SliceStable(ordered, func(i, j int) bool {
		pi, pj := fleetRolePriority(ordered[i].Role), fleetRolePriority(ordered[j].Role)
		if pi != pj {
			return pi < pj
		}
		return ordered[i].Name < ordered[j].Name
	})

	var unavailable string
	for _, app := range ordered {
		appURL := firstPublicAppURL(app.Domains)
		if appURL == "" {
			continue
		}
		if strings.EqualFold(strings.TrimSpace(app.State), "running") {
			return fleetOpenState{URL: appURL}
		}
		if unavailable == "" {
			unavailable = fmt.Sprintf("%s is %s", fleetRoleName(app.Role), fleetStateName(app.State))
		}
	}
	if unavailable == "" {
		unavailable = "No public URL configured"
	}
	return fleetOpenState{Unavailable: unavailable}
}

func fleetRolePriority(role string) int {
	switch strings.ToLower(strings.TrimSpace(role)) {
	case "frontend":
		return 0
	case "backend":
		return 1
	default:
		return 2
	}
}

func fleetRoleName(role string) string {
	role = strings.ToLower(strings.TrimSpace(role))
	if role == "" {
		return "app"
	}
	return role
}

func fleetStateName(state string) string {
	state = strings.ToLower(strings.TrimSpace(state))
	switch state {
	case "":
		return "state unavailable"
	case "not-deployed":
		return "not deployed"
	default:
		return state
	}
}

func firstPublicAppURL(domains []string) string {
	for _, domain := range domains {
		raw := strings.TrimSpace(domain)
		if raw == "" {
			continue
		}
		if !strings.Contains(raw, "://") {
			raw = "http://" + raw
		}
		parsed, err := url.Parse(raw)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") ||
			parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" ||
			parsed.RawQuery != "" || (parsed.Path != "" && parsed.Path != "/") {
			continue
		}
		hostname := parsed.Hostname()
		if hostname == "" || strings.ContainsAny(hostname, " \t\r\n*") {
			continue
		}
		return parsed.Scheme + "://" + parsed.Host
	}
	return ""
}

func writeFleetOpenJSON(b *strings.Builder, apps []dokku.App) {
	states := fleetOpenStates(apps)
	keys := make([]string, 0, len(states))
	for tenant := range states {
		keys = append(keys, tenant)
	}
	sort.Strings(keys)

	b.WriteByte('{')
	for i, tenant := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		state := states[tenant]
		fmt.Fprintf(b, `%q:{"url":%q,"unavailable":%q}`, tenant, state.URL, state.Unavailable)
	}
	b.WriteByte('}')
}

func marshalFleetBootstrap(apps []dokku.App) string {
	data, err := json.Marshal(newFleetBootstrap(apps))
	if err != nil {
		return `{"apps":[],"open":{}}`
	}
	return string(data)
}
