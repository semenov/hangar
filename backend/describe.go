package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// One-line project descriptions, kept in one file rather than in the projects, so git repos
// don't get a stray file. Generated with `claude -p` from each project's README and file list.

type description struct {
	Text      string    `json:"text"`
	Source    string    `json:"source"` // auto | manual
	UpdatedAt time.Time `json:"updated_at"`
}

var descMu sync.Mutex

func descPath() string { return filepath.Join(stateDir, "descriptions.json") }

func loadDescriptions() map[string]description {
	descMu.Lock()
	defer descMu.Unlock()
	m := map[string]description{}
	if data, err := os.ReadFile(descPath()); err == nil {
		json.Unmarshal(data, &m)
	}
	return m
}

// setDescription updates one entry, re-reading the file so concurrent writers don't clobber each other.
func setDescription(name string, d description) error {
	descMu.Lock()
	defer descMu.Unlock()
	m := map[string]description{}
	if data, err := os.ReadFile(descPath()); err == nil {
		json.Unmarshal(data, &m)
	}
	if d.Text == "" {
		delete(m, name)
	} else {
		m[name] = d
	}
	data, _ := json.MarshalIndent(m, "", "  ")
	os.MkdirAll(stateDir, 0o755)
	tmp := descPath() + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, descPath())
}

const describePrompt = `You have no tools; answer from the text below only, even if it is thin. Write a one-line description (max 90 characters, English, no trailing period, don't start with the project's name) of this software project, for a list of projects. Say what it is or does, concretely. Reply with the description only.`

// projectContext is what Claude sees: the file list and the start of the docs and manifests.
func projectContext(dir string) (string, bool) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", false
	}
	var names []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".") && e.Name() != ".mcp.json" {
			continue
		}
		n := e.Name()
		if e.IsDir() {
			n += "/"
			// One level down, so folders of folders still say something.
			if sub, err := os.ReadDir(filepath.Join(dir, e.Name())); err == nil && e.Name() != "node_modules" {
				var inner []string
				for _, se := range sub {
					if !strings.HasPrefix(se.Name(), ".") {
						inner = append(inner, se.Name())
					}
				}
				if len(inner) > 0 {
					n += "{" + strings.Join(first(inner, 8), ", ") + "}"
				}
			}
		}
		names = append(names, n)
	}
	if len(names) == 0 {
		return "", false
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Project folder: %s\nFiles: %s\n", filepath.Base(dir), strings.Join(first(names, 40), " "))
	budget := 6000
	add := func(file string, limit int) {
		data, err := os.ReadFile(filepath.Join(dir, file))
		if err != nil || budget <= 0 {
			return
		}
		data = bytes.ToValidUTF8(data[:min(len(data), limit, budget)], nil)
		fmt.Fprintf(&b, "\n--- %s ---\n%s\n", file, data)
		budget -= len(data)
	}
	for _, f := range []string{"README.md", "README", "readme.md", "CLAUDE.md", "package.json", "go.mod", "Cargo.toml", "pyproject.toml"} {
		add(f, 3000)
	}
	if budget == 6000 { // no docs or manifests: show some source
		for _, n := range names {
			if ext := filepath.Ext(n); ext == ".go" || ext == ".py" || ext == ".ts" || ext == ".js" || ext == ".swift" || ext == ".html" || ext == ".rs" || ext == ".md" || ext == ".txt" {
				add(n, 1500)
			}
		}
	}
	return b.String(), true
}

func first(s []string, n int) []string {
	if len(s) > n {
		return append(s[:n:n], fmt.Sprintf("… (%d more)", len(s)-n))
	}
	return s
}

// generateDescription asks Claude (a small model, no tools, nothing saved) to describe a project.
func generateDescription(dir string) (string, error) {
	ctxText, ok := projectContext(dir)
	if !ok {
		return "Empty folder", nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, claudeBin(), "-p", "--model", "haiku", "--tools", "",
		"--no-session-persistence", "--strict-mcp-config", "--setting-sources", "user")
	cmd.Dir = os.TempDir() // not the project: its CLAUDE.md, hooks and MCP servers stay out of it
	cmd.Env = cleanEnv()
	cmd.Stdin = strings.NewReader(describePrompt + "\n\n" + ctxText)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("claude -p: %v %s", err, strings.TrimSpace(errb.String()))
	}
	text := strings.TrimSpace(out.String())
	if i := strings.IndexByte(text, '\n'); i >= 0 {
		text = text[:i]
	}
	text = strings.TrimSuffix(strings.Trim(text, `"' `), ".")
	if !plausible(text) {
		return "", fmt.Errorf("unusable answer: %q", short(text, 80))
	}
	return text, nil
}

// plausible rejects answers that aren't a description: attempted tool calls, questions back.
func plausible(text string) bool {
	low := strings.ToLower(text)
	return text != "" && len(text) < 200 && !strings.ContainsAny(text, "<>") && !strings.HasSuffix(text, "?") &&
		!strings.HasPrefix(low, "i ") && !strings.HasPrefix(low, "i'") && !strings.Contains(low, "can't tell")
}

func claudeBin() string {
	if p, err := exec.LookPath("claude"); err == nil {
		return p
	}
	return filepath.Join(homeDir, ".local", "bin", "claude")
}

// cmdDescribe: `hangar describe [--force] [name...]` generates descriptions (all projects without
// one by default); `hangar describe --set <name> <text>` sets one by hand; `--clear <name>` removes it.
func cmdDescribe(args []string) error {
	force := false
	var names []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--force", "-f":
			force = true
		case "--set":
			if len(args) < i+3 {
				return fmt.Errorf("usage: hangar describe --set <name> <text>")
			}
			name, text := args[i+1], strings.Join(args[i+2:], " ")
			if err := setDescription(name, description{Text: text, Source: "manual", UpdatedAt: time.Now()}); err != nil {
				return err
			}
			fmt.Println(green.Render("✓ ") + bold.Render(name) + "  " + text)
			return nil
		case "--clear":
			if len(args) < i+2 {
				return fmt.Errorf("usage: hangar describe --clear <name>")
			}
			return setDescription(args[i+1], description{})
		default:
			names = append(names, args[i])
		}
	}

	existing := loadDescriptions()
	if len(names) == 0 {
		projects, err := listProjects()
		if err != nil {
			return err
		}
		for _, p := range projects {
			d, ok := existing[p.Name]
			// Manual descriptions are only replaced when a project is named explicitly.
			if !ok || (force && d.Source != "manual") {
				names = append(names, p.Name)
			}
		}
	}
	if len(names) == 0 {
		fmt.Println(dim.Render("Every project has a description. --force regenerates them."))
		return nil
	}
	sort.Strings(names)
	fmt.Fprintln(os.Stderr, dim.Render(fmt.Sprintf("Describing %d project(s) with claude -p (haiku)…", len(names))))

	jobs := make(chan string)
	var wg sync.WaitGroup
	var outMu sync.Mutex
	failed := 0
	for w := 0; w < 6; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for name := range jobs {
				dir := filepath.Join(devRoot, name)
				text, err := generateDescription(dir)
				if err != nil { // models misfire now and then; one retry
					text, err = generateDescription(dir)
				}
				outMu.Lock()
				if err != nil {
					failed++
					fmt.Println(red.Render("✗ ") + bold.Render(name) + "  " + dim.Render(err.Error()))
				} else {
					setDescription(name, description{Text: text, Source: "auto", UpdatedAt: time.Now()})
					fmt.Println(green.Render("✓ ") + bold.Render(fmt.Sprintf("%-24s", name)) + " " + text)
				}
				outMu.Unlock()
			}
		}()
	}
	for _, n := range names {
		if fi, err := os.Stat(filepath.Join(devRoot, n)); err != nil || !fi.IsDir() {
			fmt.Println(red.Render("✗ ") + bold.Render(n) + "  " + dim.Render("no such project"))
			failed++
			continue
		}
		jobs <- n
	}
	close(jobs)
	wg.Wait()
	if failed > 0 {
		return fmt.Errorf("%d project(s) failed", failed)
	}
	return nil
}
