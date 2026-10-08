package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
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
	State     string    `json:"state"`
	Waiting   string    `json:"waiting,omitempty"`
	Answered  []string  `json:"answered,omitempty"`
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
func spawnKeeper(name, dir string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(self, "keep", name, dir)
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} // own session: launchd won't reap it with ours
	if err := cmd.Start(); err != nil {
		return err
	}
	go cmd.Wait()
	return nil
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
		env = append(env, kv)
	}
	return env
}

func keep(name, dir string) error {
	os.MkdirAll(stateDir, 0o755)
	logf, err := os.Create(logPath(name))
	if err != nil {
		return err
	}
	defer logf.Close()

	// zsh -c so ~/.zshenv puts claude and node on PATH; `script` gives claude the TTY it needs.
	cmd := exec.Command("/bin/zsh", "-c", `exec script -q /dev/null claude --remote-control "$1"`, "zsh", name)
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
		// Only remove our own state: a newer keeper for the same name may have replaced it.
		if cur, ok := readState(name); ok && cur.KeeperPID == os.Getpid() {
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

	var screen tail
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
			screen.add(chunk)

			mu.Lock()
			changed := false
			if u := lastSessionURL(screen.text); u != "" && u != st.URL {
				st.URL, st.State, st.Waiting = u, "ready", ""
				changed = true
			}
			if st.URL == "" && time.Since(lastAnswer) > 2*time.Second {
				c := strings.ToLower(screen.compact())
				for _, d := range dialogs {
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
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: claude-manager keep <name> <dir>")
		os.Exit(2)
	}
	if err := keep(args[0], args[1]); err != nil {
		log.Fatal(err)
	}
}
