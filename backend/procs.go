package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Session is one `claude --remote-control <name>` process (or the "Dev Projects" server).
type Session struct {
	Name      string    `json:"name"`
	Dir       string    `json:"dir"` // relative to ~/Dev ("" for ~/Dev itself)
	PID       int       `json:"pid"`
	StartedAt time.Time `json:"started_at"`
	URL       string    `json:"url,omitempty"`
	State     string    `json:"state"`             // starting | waiting | ready
	Waiting   string    `json:"waiting,omitempty"` // what a stuck session shows on screen
	Managed   bool      `json:"managed"`           // started by claude-manager (vs. by hand)
	Server    bool      `json:"server"`            // the `claude remote-control` server form

	Description string `json:"description,omitempty"` // the project's, from `hangar describe`
}

type proc struct {
	pid, ppid int
	started   time.Time
	args      string
}

// listProcs returns all processes of this user.
func listProcs() ([]proc, error) {
	out, err := exec.Command("ps", "-x", "-o", "pid=,ppid=,lstart=,command=").Output()
	if err != nil {
		return nil, err
	}
	var ps []proc
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 8 {
			continue
		}
		pid, _ := strconv.Atoi(f[0])
		ppid, _ := strconv.Atoi(f[1])
		// lstart is 5 fields: "Wed Oct  7 03:38:42 2026"
		t, _ := time.ParseInLocation("Mon Jan 2 15:04:05 2006", strings.Join(f[2:7], " "), time.Local)
		ps = append(ps, proc{pid, ppid, t, strings.Join(f[7:], " ")})
	}
	return ps, nil
}

var (
	rcSessionRe = regexp.MustCompile(`^(?:\S*/)?claude --remote-control(?:\s+(.+))?$`)
	rcServerRe  = regexp.MustCompile(`^(?:\S*/)?claude remote-control\b.*--name\s+(.+)$`)
)

// cwds returns the working directories of the given processes.
func cwds(pids []int) map[int]string {
	res := map[int]string{}
	if len(pids) == 0 {
		return res
	}
	s := make([]string, len(pids))
	for i, p := range pids {
		s[i] = strconv.Itoa(p)
	}
	out, _ := exec.Command("lsof", "-a", "-d", "cwd", "-Fn", "-p", strings.Join(s, ",")).Output()
	pid := 0
	for _, line := range strings.Split(string(out), "\n") {
		switch {
		case strings.HasPrefix(line, "p"):
			pid, _ = strconv.Atoi(line[1:])
		case strings.HasPrefix(line, "n") && pid != 0:
			res[pid] = line[1:]
		}
	}
	return res
}

// findSessions lists running Remote Control sessions, merging in what keepers recorded.
func findSessions() ([]Session, error) {
	ps, err := listProcs()
	if err != nil {
		return nil, err
	}
	var sessions []Session
	var pids []int
	for _, p := range ps {
		if m := rcSessionRe.FindStringSubmatch(p.args); m != nil {
			// Restored sessions run as `claude --remote-control <name> --continue`.
			name := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(m[1]), "--continue"))
			sessions = append(sessions, Session{Name: unquote(name), PID: p.pid, StartedAt: p.started})
			pids = append(pids, p.pid)
		} else if m := rcServerRe.FindStringSubmatch(p.args); m != nil {
			sessions = append(sessions, Session{Name: unquote(m[1]), PID: p.pid, StartedAt: p.started, Server: true, State: "ready"})
			pids = append(pids, p.pid)
		}
	}
	dirs := cwds(pids)
	descs := loadDescriptions()
	for i := range sessions {
		s := &sessions[i]
		s.Dir = relDir(dirs[s.PID])
		s.Description = descriptionFor(s.Dir, descs)
		if s.Server {
			continue
		}
		if st, ok := readState(s.Name); ok && st.ClaudePID == s.PID {
			s.Managed = true
			s.URL, s.State, s.Waiting = st.URL, st.State, st.Waiting
		} else {
			s.URL = urlFromLog(s.Name, s.PID)
			s.State = "ready"
			if s.URL == "" {
				s.State = "starting"
			}
		}
	}
	return sessions, nil
}

func unquote(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && (s[0] == '"' || s[0] == '\'') && s[len(s)-1] == s[0] {
		s = s[1 : len(s)-1]
	}
	return s
}

func relDir(abs string) string {
	if abs == "" {
		return ""
	}
	r, err := filepath.Rel(devRoot, abs)
	if err != nil || strings.HasPrefix(r, "..") {
		return abs
	}
	if r == "." {
		return ""
	}
	return r
}

// URLs of sessions started by hand are scraped from their logs (often 100+ MB of TUI redraws),
// so the result is cached per PID.
var (
	logURLMu    sync.Mutex
	logURLCache = map[int]string{}
)

func urlFromLog(name string, pid int) string {
	logURLMu.Lock()
	defer logURLMu.Unlock()
	if u, ok := logURLCache[pid]; ok {
		return u
	}
	data, err := os.ReadFile(logPath(name))
	if err != nil {
		return ""
	}
	u := firstSessionURL(data)
	if u != "" {
		logURLCache[pid] = u
	}
	return u
}

var sessionURLRe = regexp.MustCompile(`claude\.ai/code/(session_[A-Za-z0-9]{20,})`)

// firstSessionURL finds the link Claude Code prints when it registers. It's the first one: later
// output is the conversation, which can mention other sessions' links.
func firstSessionURL(data []byte) string {
	m := sessionURLRe.FindSubmatch(data)
	if m == nil {
		return ""
	}
	return "https://claude.ai/code/" + string(m[1])
}

// Project is a directory in ~/Dev.
type Project struct {
	Name        string    `json:"name"`
	Modified    time.Time `json:"modified"`
	Git         bool      `json:"git"`
	Description string    `json:"description,omitempty"`
	// Why its last session ended, if it crashed or didn't start; cleared by the next start.
	LastExit   string    `json:"last_exit,omitempty"`
	LastExitAt time.Time `json:"last_exit_at,omitzero"`
}

// exitedStates: the sessions that crashed or didn't start, by project directory.
func exitedStates() map[string]keeperState {
	res := map[string]keeperState{}
	entries, _ := os.ReadDir(stateDir)
	for _, e := range entries {
		name, ok := strings.CutSuffix(e.Name(), ".json")
		if !ok || name == "desired" {
			continue
		}
		if st, ok := readState(name); ok && st.State == "exited" {
			res[relDir(st.Dir)] = st
		}
	}
	return res
}

func listProjects() ([]Project, error) {
	entries, err := os.ReadDir(devRoot)
	if err != nil {
		return nil, err
	}
	var res []Project
	descs := loadDescriptions()
	exited := exitedStates()
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		_, gitErr := os.Stat(filepath.Join(devRoot, e.Name(), ".git"))
		p := Project{Name: e.Name(), Modified: info.ModTime().Truncate(time.Second), Git: gitErr == nil,
			Description: descriptionFor(e.Name(), descs)}
		if st, ok := exited[e.Name()]; ok {
			p.LastExit, p.LastExitAt = st.Waiting, st.ExitedAt
		}
		res = append(res, p)
	}
	return res, nil
}
