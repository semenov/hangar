package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Renaming a project renames its folder and its session together (they share the name), and
// carries over what hangar and Claude Code keep by path: the description, the restore entry and
// Claude's transcripts, so a running session comes back under the new name with --continue.
// Remote Control may then reattach to the same claude.ai session, which keeps its old title
// (--name doesn't change it), so the keeper also types /rename into it.

var nonAlnum = regexp.MustCompile(`[^A-Za-z0-9-]`)

// transcriptsDir is where Claude Code keeps a folder's conversations: the path with every
// character other than letters, digits and '-' replaced by '-'.
func transcriptsDir(abs string) string {
	return filepath.Join(homeDir, ".claude", "projects", nonAlnum.ReplaceAllString(abs, "-"))
}

type renameResult struct {
	Project   string   `json:"project"`
	Restarted *Session `json:"restarted,omitempty"`
}

// renameProject renames ~/Dev/<from> to a sibling named <to>.
func renameProject(from, to string) (renameResult, error) {
	from, to = strings.Trim(from, "/"), strings.TrimSpace(to)
	if !dirRe.MatchString(from) {
		return renameResult{}, apiError{400, "invalid project"}
	}
	if !nameRe.MatchString(to) {
		return renameResult{}, apiError{400, "invalid name: use letters, digits, '-', '_' and '.'"}
	}
	newRel := to
	if parent := filepath.Dir(from); parent != "." {
		newRel = filepath.Join(parent, to) // a subproject stays in its parent folder
	}
	if newRel == from {
		return renameResult{Project: from}, nil
	}
	oldAbs, newAbs := filepath.Join(devRoot, from), filepath.Join(devRoot, newRel)
	if fi, err := os.Stat(oldAbs); err != nil || !fi.IsDir() {
		return renameResult{}, apiError{404, "no such project: " + from}
	}
	if _, err := os.Stat(newAbs); err == nil {
		return renameResult{}, apiError{409, "~/Dev/" + newRel + " already exists"}
	}

	// A running session is stopped first and started again afterwards, under the new name.
	sessions, err := findSessions()
	if err != nil {
		return renameResult{}, err
	}
	var running *Session
	for i := range sessions {
		if sessions[i].Dir == from {
			running = &sessions[i]
		}
	}
	for _, s := range sessions {
		if s.Name == to && (running == nil || s.PID != running.PID) {
			return renameResult{}, apiError{409, "a session named " + to + " is already running"}
		}
	}
	if running != nil {
		if err := stopSession(running.PID); err != nil {
			return renameResult{}, err
		}
		time.Sleep(time.Second)
	}

	if err := os.Rename(oldAbs, newAbs); err != nil {
		return renameResult{}, err
	}
	if oldT, newT := transcriptsDir(oldAbs), transcriptsDir(newAbs); oldT != newT {
		if _, err := os.Stat(newT); os.IsNotExist(err) {
			os.Rename(oldT, newT) // no transcripts yet is fine
		}
	}
	if d, ok := loadDescriptions()[from]; ok {
		setDescription(newRel, d)
		setDescription(from, description{})
	}
	removeDesired(filepath.Base(from))
	os.Rename(logPath(filepath.Base(from)), logPath(to))

	res := renameResult{Project: newRel}
	if running != nil {
		s, err := startSession(startRequest{Name: to, Dir: newRel, Resume: true, Retitle: true})
		if err != nil {
			return res, fmt.Errorf("renamed, but the session didn't start again: %w", err)
		}
		res.Restarted = &s
	}
	return res, nil
}

func cmdRename(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: hangar rename <project> <new-name>")
	}
	res, err := renameProject(args[0], args[1])
	if err != nil {
		return err
	}
	fmt.Println(green.Render("✓ ") + "~/Dev/" + args[0] + " → ~/Dev/" + res.Project)
	if res.Restarted != nil {
		fmt.Println(green.Render("● ") + bold.Render(res.Restarted.Name) + " restarted  " +
			dim.Render(orDefault(res.Restarted.URL, res.Restarted.State)))
	}
	return nil
}
