package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/BurntSushi/toml"
)

// Config lives in ~/.config/hangar/config.toml; `hangar setup` writes it.
type Config struct {
	// Folder with one subfolder per project.
	ProjectsDir string `toml:"projects_dir"`
	// Answer Claude Code's folder-trust and .mcp.json dialogs with "yes" for projects in ProjectsDir.
	AutoTrust bool `toml:"auto_trust"`
	// The user agreed in `hangar setup` that hangar may accept Remote Control's one-time consent.
	AcceptRemoteControl bool `toml:"accept_remote_control"`
	// Relay the iPhone app connects through; "" turns it off.
	Relay string `toml:"relay"`
	// Name shown in the app.
	MacName string `toml:"mac_name"`
}

const defaultRelay = "wss://hangar.semenov.ai"

var (
	cfgOnce sync.Once
	cfg     Config
)

func configPath() string {
	if p := os.Getenv("HANGAR_CONFIG"); p != "" {
		return p
	}
	return filepath.Join(homeDir, ".config", "hangar", "config.toml")
}

func configExists() bool {
	_, err := os.Stat(configPath())
	return err == nil
}

// conf returns the config, read once. Without a config file the defaults keep things working for
// a first run: ~/Dev, no automatic answers, the public relay.
func conf() Config {
	cfgOnce.Do(func() {
		cfg = Config{ProjectsDir: filepath.Join(homeDir, "Dev"), Relay: defaultRelay}
		if data, err := os.ReadFile(configPath()); err == nil {
			toml.Unmarshal(data, &cfg)
		}
		cfg.ProjectsDir = expandHome(cfg.ProjectsDir)
		if cfg.MacName == "" {
			cfg.MacName = computerName()
		}
	})
	return cfg
}

func saveConfig(c Config) error {
	var b bytes.Buffer
	b.WriteString("# hangar config; `hangar setup` writes it.\n")
	if err := toml.NewEncoder(&b).Encode(c); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(configPath()), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(configPath(), b.Bytes(), 0o644); err != nil {
		return err
	}
	cfg = c
	cfg.ProjectsDir = expandHome(c.ProjectsDir)
	return nil
}

func expandHome(p string) string {
	if p == "~" {
		return homeDir
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(homeDir, p[2:])
	}
	return p
}

func tildePath(p string) string {
	if rel, err := filepath.Rel(homeDir, p); err == nil && !strings.HasPrefix(rel, "..") {
		return "~/" + rel
	}
	return p
}

func computerName() string {
	if out, err := execOutput("scutil", "--get", "ComputerName"); err == nil && strings.TrimSpace(out) != "" {
		return strings.TrimSpace(out)
	}
	h, _ := os.Hostname()
	return strings.TrimSuffix(h, ".local")
}
