// claude-manager lists, starts and stops Claude Code Remote Control sessions for the projects in ~/Dev.
package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var (
	homeDir, _ = os.UserHomeDir()
	devRoot    = envOr("DEV_ROOT", filepath.Join(homeDir, "Dev"))
	stateDir   = filepath.Join(homeDir, "Library", "Application Support", "claude-manager")
)

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

var (
	nameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
	dirRe  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$`)
)

type apiError struct {
	status int
	msg    string
}

func (e apiError) Error() string { return e.msg }

func writeJSON(w http.ResponseWriter, v any, err error) {
	w.Header().Set("Content-Type", "application/json")
	if err != nil {
		status := http.StatusInternalServerError
		var ae apiError
		if errors.As(err, &ae) {
			status = ae.status
		}
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}
	json.NewEncoder(w).Encode(v)
}

type overview struct {
	Sessions []Session `json:"sessions"`
	Projects []Project `json:"projects"`
}

func getOverview() (overview, error) {
	sessions, err := findSessions()
	if err != nil {
		return overview{}, err
	}
	sort.Slice(sessions, func(i, j int) bool {
		if sessions[i].Server != sessions[j].Server {
			return sessions[i].Server
		}
		return sessions[i].StartedAt.After(sessions[j].StartedAt)
	})
	projects, err := listProjects()
	if err != nil {
		return overview{}, err
	}
	sort.Slice(projects, func(i, j int) bool { return projects[i].Modified.After(projects[j].Modified) })
	if sessions == nil {
		sessions = []Session{}
	}
	return overview{sessions, projects}, nil
}

type startRequest struct {
	Name   string `json:"name"`   // session name; defaults to the last component of dir
	Dir    string `json:"dir"`    // relative to ~/Dev; defaults to name
	Create bool   `json:"create"` // create the directory (new project)
}

var startMu sync.Mutex

func startSession(req startRequest) (Session, error) {
	startMu.Lock()
	defer startMu.Unlock()

	req.Name, req.Dir = strings.TrimSpace(req.Name), strings.Trim(strings.TrimSpace(req.Dir), "/")
	if req.Dir == "" {
		req.Dir = req.Name
	}
	if req.Name == "" {
		req.Name = filepath.Base(req.Dir)
	}
	if !nameRe.MatchString(req.Name) {
		return Session{}, apiError{400, "invalid session name: use letters, digits, '-', '_' and '.'"}
	}
	if !dirRe.MatchString(req.Dir) {
		return Session{}, apiError{400, "invalid directory"}
	}
	dir := filepath.Join(devRoot, req.Dir)

	sessions, err := findSessions()
	if err != nil {
		return Session{}, err
	}
	for _, s := range sessions {
		if s.Name == req.Name && !s.Server {
			return Session{}, apiError{409, "a session named " + req.Name + " is already running"}
		}
	}

	if info, err := os.Stat(dir); err == nil {
		if !info.IsDir() {
			return Session{}, apiError{400, req.Dir + " is not a directory"}
		}
		if req.Create {
			return Session{}, apiError{409, "project " + req.Dir + " already exists"}
		}
	} else if req.Create {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return Session{}, err
		}
	} else {
		return Session{}, apiError{404, "no such project: " + req.Dir}
	}

	os.Remove(statePath(req.Name))
	if err := spawnKeeper(req.Name, dir); err != nil {
		return Session{}, err
	}

	// Wait until the session is registered (or clearly stuck) so the app can open it right away.
	deadline := time.Now().Add(40 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(500 * time.Millisecond)
		st, ok := readState(req.Name)
		if !ok || st.ClaudePID == 0 {
			continue
		}
		if st.State == "ready" || st.State == "waiting" {
			break
		}
	}
	st, _ := readState(req.Name)
	return Session{
		Name: req.Name, Dir: relDir(dir), PID: st.ClaudePID, StartedAt: st.StartedAt,
		URL: st.URL, State: orDefault(st.State, "starting"), Waiting: st.Waiting, Managed: true,
	}, nil
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

// stopSession sends SIGTERM to a session's claude process, then SIGKILL if it hangs around.
// For the server, launchd's KeepAlive starts it again: that's a restart.
func stopSession(pid int) error {
	sessions, err := findSessions()
	if err != nil {
		return err
	}
	var target *Session
	for i := range sessions {
		if sessions[i].PID == pid {
			target = &sessions[i]
		}
	}
	if target == nil {
		return apiError{404, "no session with pid " + strconv.Itoa(pid)}
	}
	syscall.Kill(pid, syscall.SIGTERM)
	for i := 0; i < 50; i++ {
		time.Sleep(100 * time.Millisecond)
		if syscall.Kill(pid, 0) != nil {
			return nil
		}
	}
	syscall.Kill(pid, syscall.SIGKILL)
	return nil
}

// apiToken is generated on first run. homebase's private share checks its own token on the public
// URL, but its proxy also serves http://claude-manager.local to the whole LAN without one.
func apiToken() (string, error) {
	path := filepath.Join(stateDir, "token")
	if b, err := os.ReadFile(path); err == nil && len(strings.TrimSpace(string(b))) >= 32 {
		return strings.TrimSpace(string(b)), nil
	}
	b := make([]byte, 24)
	rand.Read(b)
	tok := hex.EncodeToString(b)
	return tok, os.WriteFile(path, []byte(tok+"\n"), 0o600)
}

func requireToken(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := r.Header.Get("X-Manager-Token")
		if got == "" {
			got = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		}
		if r.URL.Path != "/healthz" && subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
			writeJSON(w, nil, apiError{401, "missing or wrong X-Manager-Token"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "keep" {
		keepMain(os.Args[2:])
		return
	}
	os.MkdirAll(stateDir, 0o755)
	port := envOr("PORT", "4110")
	token, err := apiToken()
	if err != nil {
		log.Fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/overview", func(w http.ResponseWriter, r *http.Request) {
		o, err := getOverview()
		writeJSON(w, o, err)
	})
	mux.HandleFunc("POST /api/sessions", func(w http.ResponseWriter, r *http.Request) {
		var req startRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, nil, apiError{400, "bad JSON: " + err.Error()})
			return
		}
		s, err := startSession(req)
		if err == nil {
			log.Printf("started %s in ~/Dev/%s: %s", s.Name, s.Dir, orDefault(s.URL, s.State))
		}
		writeJSON(w, s, err)
	})
	mux.HandleFunc("DELETE /api/sessions/{pid}", func(w http.ResponseWriter, r *http.Request) {
		pid, err := strconv.Atoi(r.PathValue("pid"))
		if err != nil {
			writeJSON(w, nil, apiError{400, "bad pid"})
			return
		}
		err = stopSession(pid)
		if err == nil {
			log.Printf("stopped pid %d", pid)
		}
		writeJSON(w, map[string]bool{"ok": err == nil}, err)
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok\n"))
	})

	if _, err := exec.LookPath("lsof"); err != nil {
		log.Printf("warning: lsof not found, session directories will be empty")
	}
	log.Printf("listening on :%s, projects in %s", port, devRoot)
	// Loopback only: this starts processes on the Mac, so it is reachable only through homebase's
	// private share (token-checked) or from the Mac itself.
	log.Fatal(http.ListenAndServe("127.0.0.1:"+port, requireToken(token, mux)))
}
