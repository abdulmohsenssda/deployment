package config

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// LoadEnvFiles reads simple KEY=VALUE files (shell-style, with optional
// `export ` prefix and # comments) and merges them into the process
// environment. Non-empty process values take precedence. Empty process values
// are filled from the files, allowing Compose to declare canonical keys
// without blocking credentials loaded from disk. Files listed earlier win over
// later files, matching `verify-mysql.sh`.
//
// Quoting:
//
//	FOO=bar         -> bar
//	FOO="bar baz"   -> bar baz
//	FOO='bar baz'   -> bar baz
//
// Missing files are silently skipped.
func LoadEnvFiles(paths ...string) {
	for _, p := range paths {
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			line = strings.TrimPrefix(line, "export ")
			eq := strings.IndexByte(line, '=')
			if eq <= 0 {
				continue
			}
			k := strings.TrimSpace(line[:eq])
			v := strings.TrimSpace(line[eq+1:])
			if n := len(v); n >= 2 {
				if (v[0] == '"' && v[n-1] == '"') || (v[0] == '\'' && v[n-1] == '\'') {
					v = v[1 : n-1]
				}
			}
			if value, present := os.LookupEnv(k); present && value != "" {
				continue
			}
			if err := os.Setenv(k, v); err != nil {
				continue
			}
		}
		_ = f.Close()
	}
}

// UpdateEnvFileValue sets key=value in a simple KEY=VALUE env file, preserving
// unrelated lines. Values are single-quoted so bcrypt hashes containing '$' are
// not treated as shell expansions by operators who source the file manually.
func UpdateEnvFileValue(path, key, value string) error {
	if strings.TrimSpace(path) == "" {
		return fmt.Errorf("env file path is required")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	updated := false
	encoded := key + "=" + quoteEnvValue(value)
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "export ") {
			trimmed = strings.TrimSpace(strings.TrimPrefix(trimmed, "export "))
		}
		if strings.HasPrefix(trimmed, key+"=") {
			prefix := ""
			if strings.HasPrefix(strings.TrimSpace(line), "export ") {
				prefix = "export "
			}
			lines[i] = prefix + encoded
			updated = true
		}
	}
	if !updated {
		if len(lines) > 0 && lines[len(lines)-1] == "" {
			lines[len(lines)-1] = encoded
		} else {
			lines = append(lines, encoded)
		}
		lines = append(lines, "")
	}
	out := []byte(strings.Join(lines, "\n"))
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".env-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(out); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, info.Mode().Perm()); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

func quoteEnvValue(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
