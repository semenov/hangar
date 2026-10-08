package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Sessions survive a reboot: every session started through hangar is recorded in desired.json
// until it is stopped (from hangar or the app) or exits on its own (/exit). At login a LaunchAgent
// runs `hangar restore`, which starts them again with --continue, so the conversation resumes.

type desiredSession struct {
	Dir     string    `json:"dir"` // absolute
	AddedAt time.Time `json:"added_at"`
}

var desiredMu sync.Mutex

func desiredPath() string { return filepath.Join(stateDir, "desired.json") }

func loadDesired() map[string]desiredSession {
	m := map[string]desiredSession{}
	if data, err := os.ReadFile(desiredPath()); err == nil {
		json.Unmarshal(data, &m)
	}
	return m
}

// updateDesired re-reads the file under the lock, so the server, the CLI and keepers can all write it.
func updateDesired(f func(map[string]desiredSession)) error {
	desiredMu.Lock()
	defer desiredMu.Unlock()
	m := loadDesired()
	f(m)
	data, _ := json.MarshalIndent(m, "", "  ")
	os.MkdirAll(stateDir, 0o755)
	tmp := fmt.Sprintf("%s.%d.tmp", desiredPath(), os.Getpid())
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, desiredPath())
}

func addDesired(name, dir string) {
	updateDesired(func(m map[string]desiredSession) {
		if _, ok := m[name]; !ok || m[name].Dir != dir {
			m[name] = desiredSession{Dir: dir, AddedAt: time.Now().Truncate(time.Second)}
		}
	})
}

func removeDesired(name string) {
	updateDesired(func(m map[string]desiredSession) { delete(m, name) })
}

// waitForNetwork: at login Wi-Fi may not be up yet, and a session that can't reach claude.ai
// starts without Remote Control.
func waitForNetwork(max time.Duration) bool {
	deadline := time.Now().Add(max)
	for time.Now().Before(deadline) {
		if c, err := net.DialTimeout("tcp", "claude.ai:443", 3*time.Second); err == nil {
			c.Close()
			return true
		}
		time.Sleep(3 * time.Second)
	}
	return false
}

const restoreLabel = "ai.semenov.hangar.restore"

// cmdRestore: `hangar restore` starts the recorded sessions that aren't running;
// `--list` shows them; `--install` adds the login item and records the sessions running now.
func cmdRestore(args []string) error {
	if len(args) > 0 {
		switch args[0] {
		case "--list":
			m := loadDesired()
			names := make([]string, 0, len(m))
			for n := range m {
				names = append(names, n)
			}
			sort.Strings(names)
			for _, n := range names {
				fmt.Printf("%-24s %s\n", n, dim.Render(relDir(m[n].Dir)))
			}
			if len(names) == 0 {
				fmt.Println(dim.Render("Nothing to restore."))
			}
			return nil
		case "--install":
			return installRestore()
		default:
			return fmt.Errorf("usage: hangar restore [--list | --install]")
		}
	}

	m := loadDesired()
	if len(m) == 0 {
		fmt.Println(dim.Render("Nothing to restore."))
		return nil
	}
	if !waitForNetwork(3 * time.Minute) {
		fmt.Fprintln(os.Stderr, amber.Render("! ")+"claude.ai unreachable; starting anyway")
	}
	running := map[string]bool{}
	if sessions, err := findSessions(); err == nil {
		for _, s := range sessions {
			running[s.Name] = true
		}
	}
	names := make([]string, 0, len(m))
	for n := range m {
		names = append(names, n)
	}
	sort.Strings(names)
	failed := 0
	for _, name := range names {
		d := m[name]
		if running[name] {
			fmt.Println(dim.Render("· " + name + " is already running"))
			continue
		}
		if fi, err := os.Stat(d.Dir); err != nil || !fi.IsDir() {
			fmt.Println(dim.Render("· " + name + ": " + d.Dir + " is gone, dropping it"))
			removeDesired(name)
			continue
		}
		rel, err := filepath.Rel(devRoot, d.Dir)
		if err != nil || strings.HasPrefix(rel, "..") {
			fmt.Println(red.Render("✗ ") + name + ": " + d.Dir + " is outside " + devRoot)
			failed++
			continue
		}
		s, err := startSession(startRequest{Name: name, Dir: rel, Resume: true})
		if err != nil {
			fmt.Println(red.Render("✗ ") + bold.Render(name) + "  " + err.Error())
			failed++
			continue
		}
		fmt.Println(green.Render("● ") + bold.Render(fmt.Sprintf("%-24s", name)) + " " + dim.Render(orDefault(s.URL, s.State)))
	}
	if failed > 0 {
		return fmt.Errorf("%d session(s) failed", failed)
	}
	return nil
}

// writeLaunchAgent writes a LaunchAgent that runs `hangar <args...>`; schedule is extra plist XML
// (RunAtLoad, StartCalendarInterval, ...).
func writeLaunchAgent(label, logName, schedule string, args ...string) (string, error) {
	self, err := os.Executable()
	if err != nil {
		return "", err
	}
	if p, err := filepath.EvalSymlinks(self); err == nil {
		self = p
	}
	argXML := "\t\t<string>" + self + "</string>\n"
	for _, a := range args {
		argXML += "\t\t<string>" + a + "</string>\n"
	}
	logFile := filepath.Join(homeDir, "Library", "Logs", logName)
	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>%s</string>
	<key>ProgramArguments</key>
	<array>
%s	</array>
%s
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>%s/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>StandardOutPath</key>
	<string>%s</string>
	<key>StandardErrorPath</key>
	<string>%s</string>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
`, label, argXML, schedule, homeDir, logFile, logFile)
	path := filepath.Join(homeDir, "Library", "LaunchAgents", label+".plist")
	if err := os.WriteFile(path, []byte(plist), 0o644); err != nil {
		return "", err
	}
	if out, err := exec.Command("plutil", "-lint", path).CombinedOutput(); err != nil {
		return "", fmt.Errorf("plist doesn't validate: %s", out)
	}
	return path, nil
}

func installRestore() error {
	path, err := writeLaunchAgent(restoreLabel, "hangar-restore.log", "\t<key>RunAtLoad</key>\n\t<true/>", "restore")
	if err != nil {
		return err
	}
	logFile := filepath.Join(homeDir, "Library", "Logs", "hangar-restore.log")

	// Record what's running now, so the first reboot brings it back too.
	sessions, err := findSessions()
	if err != nil {
		return err
	}
	n := 0
	for _, s := range sessions {
		if s.Server || s.Dir == "" || strings.HasPrefix(s.Dir, "/") {
			continue
		}
		addDesired(s.Name, filepath.Join(devRoot, s.Dir))
		n++
	}
	fmt.Println(green.Render("✓ ") + "Login item: " + path)
	fmt.Println(green.Render("✓ ") + fmt.Sprintf("%d running session(s) recorded; `hangar restore --list` shows them", n))
	fmt.Println(dim.Render("  It runs at the next login. Logs: " + logFile))
	return nil
}
