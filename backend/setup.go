package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// `hangar setup`: checks Claude Code, asks the few questions that are the user's to answer, starts
// the background service and pairs the iPhone app.

var stdinReader = bufio.NewReader(os.Stdin)

func ask(question, def string) string {
	fmt.Printf("%s %s ", bold.Render("?")+" "+question, dim.Render("("+def+")"))
	line, _ := stdinReader.ReadString('\n')
	if line = strings.TrimSpace(line); line != "" {
		return line
	}
	return def
}

func confirm(question string, def bool) bool {
	d := "Y/n"
	if !def {
		d = "y/N"
	}
	for {
		a := strings.ToLower(ask(question, d))
		switch a {
		case "y/n", "y/N", "":
			return def
		case "y", "yes", "д", "да":
			return true
		case "n", "no", "н", "нет":
			return false
		}
		if a == strings.ToLower(d) {
			return def
		}
	}
}

func step(ok bool, text string) {
	if ok {
		fmt.Println(green.Render("✓ ") + text)
	} else {
		fmt.Println(red.Render("✗ ") + text)
	}
}

type authStatus struct {
	LoggedIn         bool   `json:"loggedIn"`
	AuthMethod       string `json:"authMethod"`
	SubscriptionType string `json:"subscriptionType"`
}

func cmdSetup(args []string) error {
	noService := false
	for _, a := range args {
		if a == "--no-service" {
			noService = true // the API runs some other way (homebase, a dev build)
		}
	}
	fmt.Println(titleStyle.Render("⌂ hangar setup") + dim.Render("  "+version))
	fmt.Println()

	// 1. Claude Code, signed in with a plan that has Remote Control.
	out, err := exec.Command(claudeBin(), "--version").Output()
	if err != nil {
		step(false, "Claude Code isn't installed. Install it (https://claude.com/claude-code), then run `hangar setup` again.")
		return fmt.Errorf("claude not found")
	}
	step(true, "Claude Code "+strings.Fields(string(out) + " ?")[0])
	cmd := exec.Command(claudeBin(), "auth", "status", "--json")
	cmd.Env = cleanEnv()
	var st authStatus
	if out, err := cmd.Output(); err == nil {
		json.Unmarshal(out, &st)
	}
	switch {
	case !st.LoggedIn:
		step(false, "Not signed in. Run `claude`, then `/login`, and run `hangar setup` again.")
		return fmt.Errorf("not signed in")
	case st.AuthMethod != "claude.ai":
		step(false, "Signed in with "+st.AuthMethod+"; Remote Control needs a claude.ai login (Pro, Max, Team or Enterprise).")
		return fmt.Errorf("remote control needs claude.ai auth")
	default:
		step(true, "Signed in to claude.ai"+map[bool]string{true: " (" + st.SubscriptionType + ")", false: ""}[st.SubscriptionType != ""])
	}
	fmt.Println()

	// 2. The questions.
	c := conf()
	def := tildePath(c.ProjectsDir)
	if !configExists() {
		if _, err := os.Stat(c.ProjectsDir); err != nil {
			def = "~/Projects"
		}
	}
	dir := expandHome(ask("Projects folder: one subfolder per project", def))
	if !filepath.IsAbs(dir) {
		dir, _ = filepath.Abs(dir)
	}
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		if !confirm(tildePath(dir)+" doesn't exist. Create it?", true) {
			return fmt.Errorf("no projects folder")
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	c.ProjectsDir = tildePath(dir)

	fmt.Println(dim.Render("  Claude Code asks whether you trust a folder, and whether to use its .mcp.json servers,"))
	fmt.Println(dim.Render("  before a session in it can start. Nobody is at the terminal to answer when you start one"))
	fmt.Println(dim.Render("  from the phone."))
	c.AutoTrust = confirm("Answer yes to these for projects in "+c.ProjectsDir+"?", true)
	if !c.AutoTrust {
		fmt.Println(dim.Render("  Sessions in folders you haven't trusted yet will wait; the app shows what they're asking."))
	}

	if !remoteControlConsented() {
		fmt.Println(dim.Render("  The first Remote Control session asks once: \"Enable Remote Control? (y/n)\". It lets"))
		fmt.Println(dim.Render("  claude.ai and the Claude app show and steer sessions running on this Mac."))
		c.AcceptRemoteControl = confirm("Enable Remote Control?", true)
		if !c.AcceptRemoteControl {
			return fmt.Errorf("hangar needs Remote Control")
		}
	} else {
		c.AcceptRemoteControl = true
	}
	c.MacName = ask("Name of this Mac in the app", orDefault(c.MacName, computerName()))
	if c.Relay == "" {
		c.Relay = defaultRelay
	}
	if err := saveConfig(c); err != nil {
		return err
	}
	devRoot = conf().ProjectsDir
	fmt.Println()
	step(true, "Saved "+tildePath(configPath()))

	// 3. Background jobs: the API, restore after reboot, daily descriptions.
	if !noService {
		if err := startService(); err != nil {
			step(false, "Background service: "+err.Error())
			return err
		}
	}
	if _, err := writeLaunchAgent(restoreLabel, "hangar-restore.log", "\t<key>RunAtLoad</key>\n\t<true/>", "restore"); err == nil {
		step(true, "Sessions come back after a reboot")
	}
	if confirm("Describe new projects with Claude once a day (a few seconds of Haiku per new project)?", true) {
		if err := installDescribe(); err != nil {
			step(false, "Daily descriptions: "+err.Error())
		}
	}
	fmt.Println()

	// 4. Pair the phone.
	if !waitRelay(20 * time.Second) {
		st, _ := readRelayStatus()
		fmt.Println(amber.Render("! ") + "Not connected to the relay yet (" + orDefault(st.Error, "no answer") + "); the code works as soon as it is.")
	}
	fmt.Println(bold.Render("Install Hangar on the iPhone, then scan this code with the camera:"))
	return cmdPair(nil)
}

// remoteControlConsented: Claude Code records the one-time consent in ~/.claude.json.
func remoteControlConsented() bool {
	data, err := os.ReadFile(filepath.Join(homeDir, ".claude.json"))
	if err != nil {
		return false
	}
	var m map[string]any
	json.Unmarshal(data, &m)
	v, _ := m["remoteDialogSeen"].(bool)
	return v
}

func waitRelay(max time.Duration) bool {
	deadline := time.Now().Add(max)
	for time.Now().Before(deadline) {
		if st, alive := readRelayStatus(); alive && st.Connected {
			return true
		}
		time.Sleep(500 * time.Millisecond)
	}
	return false
}

const serveLabel = "ai.semenov.hangar.serve"

// startService runs `hangar serve` in the background: with brew services when installed by
// Homebrew, else with our own LaunchAgent. Both start it at login and restart it if it dies.
func startService() error {
	self := stableExecutable()
	if strings.Contains(self, "/Cellar/") || strings.HasPrefix(self, brewPrefix()+"/") {
		out, err := exec.Command(filepath.Join(brewPrefix(), "bin", "brew"), "services", "restart", "hangar").CombinedOutput()
		if err != nil {
			return fmt.Errorf("brew services: %s", strings.TrimSpace(string(out)))
		}
		step(true, "Background service started (brew services)")
		return nil
	}
	schedule := "\t<key>RunAtLoad</key>\n\t<true/>\n\t<key>KeepAlive</key>\n\t<true/>"
	path, err := writeLaunchAgent(serveLabel, "hangar.log", schedule, "serve")
	if err != nil {
		return err
	}
	uid := fmt.Sprint(os.Getuid())
	exec.Command("launchctl", "bootout", "gui/"+uid+"/"+serveLabel).Run()
	if out, err := exec.Command("launchctl", "bootstrap", "gui/"+uid, path).CombinedOutput(); err != nil {
		return fmt.Errorf("launchctl: %s", strings.TrimSpace(string(out)))
	}
	step(true, "Background service started ("+tildePath(path)+")")
	return nil
}

func brewPrefix() string {
	if _, err := os.Stat("/opt/homebrew/bin/brew"); err == nil {
		return "/opt/homebrew"
	}
	return "/usr/local"
}

// stableExecutable: a Homebrew install runs from Cellar/hangar/<version>, which goes away on
// upgrade; launchd jobs point at the opt symlink instead.
func stableExecutable() string {
	self, err := os.Executable()
	if err != nil {
		return "hangar"
	}
	if p, err := filepath.EvalSymlinks(self); err == nil {
		self = p
	}
	if i := strings.Index(self, "/Cellar/hangar/"); i >= 0 {
		return self[:i] + "/opt/hangar/bin/hangar"
	}
	return self
}
