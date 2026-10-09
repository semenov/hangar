package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// The keeper (`claude-manager keep <name> <dir>`) runs detached from the server, one per session.
// It owns the session's stdin/stdout, answers the startup dialogs that block `--remote-control`,
// records the session URL in a state file and caps the log, which the TUI otherwise grows to
// 100+ MB.

const (
	maxLogSize = 20 << 20
	up         = "\x1b[A"
	down       = "\x1b[B"
)

type keeperState struct {
	Name      string    `json:"name"`
	Dir       string    `json:"dir"`
	KeeperPID int       `json:"keeper_pid"`
	ClaudePID int       `json:"claude_pid"`
	StartedAt time.Time `json:"started_at"`
	URL       string    `json:"url,omitempty"`
	State     string    `json:"state"` // starting | waiting | ready | disconnected | exited
	Waiting   string    `json:"waiting,omitempty"`
	Answered  []string  `json:"answered,omitempty"`
	ExitedAt  time.Time `json:"exited_at,omitzero"`
}

// A dialog Claude Code shows before it registers with Remote Control.
type dialog struct {
	name  string
	match string   // lowercase, whitespace removed
	keys  []string // sent with a pause in between, so the TUI sees separate key presses
}

var dialogs = []dialog{
	{"remote-control consent", "enableremotecontrol?", []string{"y\n"}},
	// "❯ No, exit" is preselected.
	{"folder trust", "yes,itrustthisfolder", []string{down, "\r"}},
	// "❯ Continue without using this MCP server" is preselected; one up is "Use this and all
	// future MCP servers in this project".
	{"mcp servers", "foundinthisproject", []string{up, "\r"}},
}

// dialogAllowed: what the user agreed to in `hangar setup`.
// What a session prints when it loses Remote Control after registering, e.g.
// "⏺ Remote Control disconnected — Claude.ai login expired — run /login to restore Remote Control".
// It reconnects by itself after network trouble; this one needs a new login. The ⏺ at the start
// tells it from the conversation quoting it.
var disconnectedRe = regexp.MustCompile(`⏺ ?Remote Control disconnected ?— ?([^—]{1,80}?) ?— ?run /login`)

func dialogAllowed(d dialog) bool {
	if d.name == "remote-control consent" {
		return conf().AcceptRemoteControl
	}
	return conf().AutoTrust
}

func statePath(name string) string { return filepath.Join(stateDir, name+".json") }
func logPath(name string) string {
	return filepath.Join(homeDir, "Library", "Logs", "claude-rc-"+name+".log")
}

func readState(name string) (keeperState, bool) {
	var st keeperState
	data, err := os.ReadFile(statePath(name))
	if err != nil || json.Unmarshal(data, &st) != nil {
		return st, false
	}
	return st, true
}

func writeState(st keeperState) {
	data, _ := json.MarshalIndent(st, "", "  ")
	tmp := statePath(st.Name) + ".tmp"
	if os.WriteFile(tmp, data, 0o644) == nil {
		os.Rename(tmp, statePath(st.Name))
	}
}

// spawnKeeper starts a detached keeper; it survives the server being restarted.
// The returned channel is closed when the keeper exits.
func spawnKeeper(name, dir string, resume, retitle bool) (<-chan struct{}, error) {
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	args := []string{"keep", name, dir}
	if resume {
		args = append(args, "--continue")
	}
	if retitle {
		args = append(args, "--retitle")
	}
	cmd := exec.Command(self, args...)
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} // own session: launchd won't reap it with ours
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	done := make(chan struct{})
	go func() { cmd.Wait(); close(done) }()
	return done, nil
}

// cleanEnv drops the markers of the Claude session this may have been started from: with
// CLAUDE_CODE_CHILD_SESSION set, the new session doesn't save its transcript.
func cleanEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		if k == "CLAUDECODE" || k == "AI_AGENT" || k == "CLAUDE_PID" || k == "CLAUDE_EFFORT" || strings.HasPrefix(k, "CLAUDE_CODE_") {
			continue
		}
		if k == "PATH" {
			continue
		}
		env = append(env, kv)
	}
	// launchd (homebase) gives a bare PATH; claude lives in ~/.local/bin. ~/.zshenv adds node.
	path := filepath.Join(homeDir, ".local", "bin") + ":/opt/homebrew/bin:/opt/homebrew/sbin:" +
		envOr("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
	return append(env, "PATH="+path)
}

func keep(name, dir string, resume, retitle bool) error {
	os.MkdirAll(stateDir, 0o755)
	// At shutdown everything gets SIGTERM: remember that, so the session stays in desired.json.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGINT)
	var signaled atomic.Bool
	go func() {
		for range sigs {
			signaled.Store(true)
		}
	}()

	logf, err := os.Create(logPath(name))
	if err != nil {
		return err
	}
	defer logf.Close()

	// zsh -c so ~/.zshenv puts claude and node on PATH; `script` gives claude the TTY it needs.
	shell := `exec script -q /dev/null claude --remote-control "$1"`
	if resume { // --continue with no earlier conversation just starts a new one
		shell += " --continue"
	}
	cmd := exec.Command("/bin/zsh", "-c", shell, "zsh", name)
	cmd.Dir = dir
	cmd.Env = cleanEnv()
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	r, w, err := os.Pipe()
	if err != nil {
		return err
	}
	cmd.Stdout, cmd.Stderr = w, w
	if err := cmd.Start(); err != nil {
		return err
	}
	w.Close()

	st := keeperState{Name: name, Dir: dir, KeeperPID: os.Getpid(), StartedAt: time.Now().Truncate(time.Second), State: "starting"}
	var mu sync.Mutex
	writeState(st)
	defer func() {
		// Only remove our own state: a newer keeper for the same name may have replaced it. An
		// "exited" state stays, so the app can show why the session ended.
		if cur, ok := readState(name); ok && cur.KeeperPID == os.Getpid() && cur.State != "exited" {
			os.Remove(statePath(name))
		}
	}()

	go func() { // find the claude process under `script`
		for i := 0; i < 50; i++ {
			ps, _ := listProcs()
			for _, p := range ps {
				if p.ppid == cmd.Process.Pid && rcSessionRe.MatchString(p.args) {
					mu.Lock()
					st.ClaudePID = p.pid
					writeState(st)
					mu.Unlock()
					return
				}
			}
			time.Sleep(200 * time.Millisecond)
		}
	}()

	var screen tail // guarded by mu
	// A session that prints nothing at all is stuck too; the read loop below wouldn't notice.
	go func() {
		for range time.Tick(5 * time.Second) {
			mu.Lock()
			if st.State == "starting" && time.Since(st.StartedAt) > 30*time.Second {
				st.State, st.Waiting = "waiting", orDefault(screen.readable(400), "no output from claude")
				writeState(st)
			}
			mu.Unlock()
		}
	}()

	var written int64
	lastAnswer := time.Time{}
	buf := make([]byte, 32<<10)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			chunk := buf[:n]
			if written+int64(n) > maxLogSize {
				logf.Truncate(0)
				logf.Seek(0, io.SeekStart)
				written = 0
			}
			logf.Write(chunk)
			written += int64(n)

			mu.Lock()
			screen.add(chunk)
			changed := false
			if u := firstSessionURL(screen.text); u != "" && st.URL == "" {
				st.URL, st.State, st.Waiting = u, "ready", ""
				screen.reset() // what follows is the session; the startup screen is done with
				changed = true
				if retitle {
					go func() {
						time.Sleep(2 * time.Second) // let the prompt come up
						log.Printf("%s: /rename %s", name, name)
						io.WriteString(stdin, "/rename "+name)
						time.Sleep(400 * time.Millisecond)
						io.WriteString(stdin, "\r")
					}()
				}
			}
			if st.URL != "" && st.State != "disconnected" {
				if m := disconnectedRe.FindStringSubmatch(screen.readable(4000)); m != nil {
					log.Printf("%s: Remote Control disconnected: %s", name, m[1])
					st.State = "disconnected"
					st.Waiting = "Remote Control disconnected: " + m[1] + ". Run `claude` and /login on the Mac, then restart the session."
					changed = true
				}
			}
			if st.URL == "" && time.Since(lastAnswer) > 2*time.Second {
				c := strings.ToLower(screen.compact())
				for _, d := range dialogs {
					if !dialogAllowed(d) {
						continue // left for the user; the session shows as "waiting" with the screen text
					}
					if strings.Contains(c, d.match) {
						log.Printf("%s: answering %s", name, d.name)
						time.Sleep(500 * time.Millisecond) // let the dialog finish drawing
						for _, k := range d.keys {
							io.WriteString(stdin, k)
							time.Sleep(400 * time.Millisecond)
						}
						st.Answered = append(st.Answered, d.name)
						screen.reset()
						lastAnswer = time.Now()
						changed = true
						break
					}
				}
			}
			if st.URL == "" && time.Since(st.StartedAt) > 30*time.Second {
				if wt := screen.readable(400); wt != st.Waiting {
					st.State, st.Waiting = "waiting", wt
					changed = true
				}
			}
			if changed {
				writeState(st)
			}
			mu.Unlock()
		}
		if err != nil {
			break
		}
	}
	err = cmd.Wait()
	log.Printf("%s: exited: %v", name, err)
	// The grace period covers shutdown, where claude may get its SIGTERM a moment before we do.
	time.Sleep(3 * time.Second)
	_, wanted := loadDesired()[name] // stopSession removes it before stopping claude
	switch {
	case signaled.Load():
		// The Mac is shutting down: it stays in desired.json and comes back at login.
	case err == nil:
		removeDesired(name) // /exit: don't bring it back
	case wanted:
		// Crashed or refused to start. It stays in desired.json (a reboot tries again), and the
		// state file stays with the last screen, for the app.
		mu.Lock()
		st.State, st.ExitedAt = "exited", time.Now().Truncate(time.Second)
		st.Waiting = orDefault(screen.readable(300), err.Error())
		writeState(st)
		mu.Unlock()
	}
	return nil
}

// tail keeps the last few KB of terminal output with escape sequences removed.
type tail struct{ text []byte }

var (
	csiRe = regexp.MustCompile(`\x1b\[[0-9;?<>=]*[ -/]*[@-~]`)
	oscRe = regexp.MustCompile(`\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)`)
	escRe = regexp.MustCompile(`\x1b[@-_]?`)
	wsRe  = regexp.MustCompile(`\s+`)
)

func (t *tail) add(chunk []byte) {
	s := oscRe.ReplaceAll(chunk, nil)
	s = csiRe.ReplaceAll(s, []byte(" ")) // cursor moves stand in for spaces in the TUI
	s = escRe.ReplaceAll(s, nil)
	t.text = append(t.text, s...)
	if len(t.text) > 16<<10 {
		t.text = t.text[len(t.text)-8<<10:]
	}
}

func (t *tail) reset()          { t.text = nil }
func (t *tail) compact() string { return wsRe.ReplaceAllString(string(t.text), "") }

func (t *tail) readable(n int) string {
	s := strings.TrimSpace(wsRe.ReplaceAllString(string(t.text), " "))
	if r := []rune(s); len(r) > n {
		s = "…" + string(r[len(r)-n:])
	}
	return s
}

func keepMain(args []string) {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: claude-manager keep <name> <dir> [--continue] [--retitle]")
		os.Exit(2)
	}
	if err := keep(args[0], args[1], slices.Contains(args[2:], "--continue"), slices.Contains(args[2:], "--retitle")); err != nil {
		log.Fatal(err)
	}
}
