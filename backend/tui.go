package main

import (
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// The interactive list: running sessions on top, then the projects in ~/Dev.

type mode int

const (
	modeList mode = iota
	modeFilter
	modeNew
	modeConfirmStop
	modeQR
)

type item struct {
	session *Session // running session, or nil for an idle project
	project *Project
}

func (it item) name() string {
	if it.session != nil {
		return it.session.Name
	}
	return it.project.Name
}

type model struct {
	overview overview
	usage    *Usage
	items    []item
	cursor   int
	offset   int
	width    int
	height   int
	mode     mode
	input    textinput.Model
	filter   string
	busy     map[string]string // name → "starting" | "stopping"
	status   string
	err      string
	qrURL    string
}

type (
	overviewMsg overview
	usageMsg    Usage
	errMsg      struct{ err error }
	tickMsg     struct{}
	startedMsg  struct {
		name    string
		session Session
		err     error
		open    bool
	}
	stoppedMsg struct {
		name string
		err  error
	}
)

func runTUI() error {
	in := textinput.New()
	in.Prompt = ""
	m := model{busy: map[string]string{}, input: in}
	_, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
	return err
}

func loadOverview() tea.Msg {
	o, err := getOverview()
	if err != nil {
		return errMsg{err}
	}
	return overviewMsg(o)
}

// Limits are fetched on start and on `r` only: each fetch runs `claude -p /usage`.
func loadUsage() tea.Msg {
	u, err := fetchUsage(false)
	if err != nil {
		return nil // limits are optional; claude-monitor may not be running
	}
	return usageMsg(u)
}

func tick() tea.Cmd { return tea.Tick(3*time.Second, func(time.Time) tea.Msg { return tickMsg{} }) }

func (m model) Init() tea.Cmd { return tea.Batch(loadOverview, loadUsage, tick()) }

func (m *model) rebuild() {
	keep := ""
	if m.cursor < len(m.items) {
		keep = m.items[m.cursor].name()
	}
	q := strings.ToLower(m.filter)
	running := map[string]bool{}
	m.items = nil
	for i := range m.overview.Sessions {
		s := &m.overview.Sessions[i]
		if !s.Server {
			running[s.Dir] = true
		}
		if q == "" || strings.Contains(strings.ToLower(s.Name), q) {
			m.items = append(m.items, item{session: s})
		}
	}
	for i := range m.overview.Projects {
		p := &m.overview.Projects[i]
		if !running[p.Name] && (q == "" || strings.Contains(strings.ToLower(p.Name), q)) {
			m.items = append(m.items, item{project: p})
		}
	}
	m.cursor = 0
	for i, it := range m.items {
		if it.name() == keep {
			m.cursor = i
		}
	}
}

func (m model) selected() *item {
	if m.cursor < len(m.items) {
		return &m.items[m.cursor]
	}
	return nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case overviewMsg:
		m.overview = overview(msg)
		m.rebuild()
		return m, nil
	case usageMsg:
		u := Usage(msg)
		m.usage = &u
		return m, nil
	case errMsg:
		m.err = msg.err.Error()
		return m, nil
	case tickMsg:
		return m, tea.Batch(loadOverview, tick())
	case startedMsg:
		delete(m.busy, msg.name)
		if msg.err != nil {
			m.err = msg.err.Error()
		} else {
			m.err = ""
			m.status = msg.session.Name + " started"
			if msg.session.URL != "" {
				m.status += ": " + msg.session.URL
				if msg.open {
					exec.Command("open", msg.session.URL).Start()
				}
			} else if msg.session.State == "waiting" {
				m.status = msg.session.Name + " is waiting: " + msg.session.Waiting
			}
		}
		return m, loadOverview
	case stoppedMsg:
		delete(m.busy, msg.name)
		if msg.err != nil {
			m.err = msg.err.Error()
		} else {
			m.status = msg.name + " stopped"
		}
		return m, loadOverview
	case tea.KeyMsg:
		return m.key(msg)
	}
	return m, nil
}

func startCmd(name string, create, open bool) tea.Cmd {
	return func() tea.Msg {
		s, err := startSession(startRequest{Dir: name, Create: create})
		return startedMsg{name, s, err, open}
	}
}

func stopCmd(s Session) tea.Cmd {
	return func() tea.Msg { return stoppedMsg{s.Name, stopSession(s.PID)} }
}

func (m model) key(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch m.mode {
	case modeFilter, modeNew:
		switch k.Type {
		case tea.KeyEsc:
			if m.mode == modeFilter {
				m.filter = ""
				m.rebuild()
			}
			m.mode = modeList
			return m, nil
		case tea.KeyEnter:
			if m.mode == modeNew {
				name := slugify(m.input.Value())
				m.mode = modeList
				if name == "" {
					return m, nil
				}
				m.busy[name] = "starting"
				m.status, m.err = "Creating ~/Dev/"+name+"…", ""
				return m, startCmd(name, true, false)
			}
			m.mode = modeList
			return m, nil
		}
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(k)
		if m.mode == modeFilter {
			m.filter = m.input.Value()
			m.rebuild()
		}
		return m, cmd

	case modeConfirmStop:
		m.mode = modeList
		if it := m.selected(); it != nil && it.session != nil && (k.String() == "y" || k.String() == "enter") {
			m.busy[it.session.Name] = "stopping"
			return m, stopCmd(*it.session)
		}
		return m, nil

	case modeQR:
		m.mode = modeList
		return m, nil
	}

	it := m.selected()
	m.err = ""
	switch k.String() {
	case "q", "esc", "ctrl+c":
		return m, tea.Quit
	case "up", "k":
		m.cursor = max(0, m.cursor-1)
	case "down", "j":
		m.cursor = min(len(m.items)-1, m.cursor+1)
	case "home", "g":
		m.cursor = 0
	case "end", "G":
		m.cursor = len(m.items) - 1
	case "/":
		m.mode = modeFilter
		m.input.Placeholder = "filter"
		m.input.SetValue(m.filter)
		m.input.Focus()
	case "n":
		m.mode = modeNew
		m.input.Placeholder = "todo-app"
		m.input.SetValue("")
		m.input.Focus()
	case "r":
		m.status = "Refreshing…"
		return m, tea.Batch(loadOverview, loadUsage)
	case "enter", "o":
		if it == nil {
			break
		}
		if it.session != nil {
			if it.session.URL != "" {
				exec.Command("open", it.session.URL).Start()
				m.status = "Opened " + it.session.Name
			}
		} else if m.busy[it.project.Name] == "" {
			m.busy[it.project.Name] = "starting"
			m.status = "Starting " + it.project.Name + "…"
			return m, startCmd(it.project.Name, false, k.String() == "enter")
		}
	case "s":
		if it != nil && it.project != nil && m.busy[it.project.Name] == "" {
			m.busy[it.project.Name] = "starting"
			m.status = "Starting " + it.project.Name + "…"
			return m, startCmd(it.project.Name, false, false)
		}
	case "x", "delete", "backspace":
		if it != nil && it.session != nil {
			m.mode = modeConfirmStop
		}
	case "c":
		if it != nil && it.session != nil && it.session.URL != "" {
			c := exec.Command("pbcopy")
			c.Stdin = strings.NewReader(it.session.URL)
			c.Run()
			m.status = "Copied " + it.session.URL
		}
	case " ":
		if it != nil && it.session != nil && it.session.URL != "" {
			m.qrURL = it.session.URL
			m.mode = modeQR
		}
	}
	return m, nil
}

// MARK: view

var (
	titleStyle   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#4DD9B3"))
	headerStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#7B8AA8")).Bold(true)
	cursorStyle  = lipgloss.NewStyle().Background(lipgloss.Color("#1E2A5C"))
	keyStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#55B8FF"))
	promptStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#55B8FF")).Bold(true)
	waitingStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#F9C255"))
)

func (m model) View() string {
	if m.width == 0 {
		return ""
	}
	if m.mode == modeQR {
		var b strings.Builder
		printQR(&b, m.qrURL)
		return "\n" + b.String() + "\n  " + dim.Render(m.qrURL) + "\n\n  " + dim.Render("Scan with the phone's camera · any key to go back")
	}

	var top []string
	head := titleStyle.Render("⌂ hangar")
	head += dim.Render(fmt.Sprintf("   %d running · %d projects", len(m.overview.Sessions), len(m.overview.Projects)))
	if m.usage != nil {
		var parts []string
		for _, l := range m.usage.Limits {
			label := strings.ToLower(strings.TrimPrefix(l.Label, "Current "))
			label = strings.ReplaceAll(strings.ReplaceAll(label, " (all models)", ""), "week (", "")
			label = strings.TrimSuffix(label, ")")
			parts = append(parts, dim.Render(label+" ")+pctStyle(l.Percent).Render(fmt.Sprintf("%.0f%%", l.Percent)))
		}
		head += dim.Render("   ") + strings.Join(parts, dim.Render(" · "))
	}
	top = append(top, " "+head, "")

	// Rows, with section headers.
	var rows []string
	cursorRow := 0
	section := ""
	for i, it := range m.items {
		sec := "RUNNING"
		if it.project != nil {
			sec = "PROJECTS"
		}
		if sec != section {
			if section != "" {
				rows = append(rows, "")
			}
			rows = append(rows, " "+headerStyle.Render(sec))
			section = sec
		}
		if i == m.cursor {
			cursorRow = len(rows)
		}
		rows = append(rows, m.row(it, i == m.cursor))
	}
	if len(m.items) == 0 {
		rows = append(rows, dim.Render("  Nothing matches."))
	}

	bottom := []string{""}
	switch m.mode {
	case modeFilter:
		bottom = append(bottom, " "+promptStyle.Render("/ ")+m.input.View())
	case modeNew:
		bottom = append(bottom, " "+promptStyle.Render("New project ~/Dev/")+m.input.View()+dim.Render("   enter create · esc cancel"))
	case modeConfirmStop:
		bottom = append(bottom, " "+waitingStyle.Render(fmt.Sprintf("Stop %s? ", m.selected().name()))+dim.Render("y / n"))
	default:
		switch {
		case m.err != "":
			bottom = append(bottom, " "+red.Render(short(m.err, m.width-2)))
		case m.status != "":
			bottom = append(bottom, " "+dim.Render(short(m.status, m.width-2)))
		default:
			bottom = append(bottom, "")
		}
	}
	bottom = append(bottom, " "+help(m.selected()))

	// Scroll the rows so the cursor stays visible.
	avail := max(3, m.height-len(top)-len(bottom))
	off := m.offset
	if cursorRow < off+1 {
		off = max(0, cursorRow-1)
	}
	if cursorRow >= off+avail {
		off = cursorRow - avail + 1
	}
	end := min(len(rows), off+avail)
	visible := rows[off:end]
	for len(visible) < avail {
		visible = append(visible, "")
	}
	return strings.Join(append(append(top, visible...), bottom...), "\n")
}

func (m model) row(it item, selected bool) string {
	w := max(40, m.width)
	var line string
	if s := it.session; s != nil {
		dot, info := green.Render("●"), s.Description
		if info == "" {
			info = dim.Render(s.URL)
		}
		switch {
		case m.busy[s.Name] == "stopping":
			dot, info = amber.Render("◌"), amber.Render("stopping…")
		case s.State == "waiting":
			dot, info = amber.Render("●"), waitingStyle.Render("waiting: "+short(s.Waiting, 50))
		case s.State == "disconnected":
			dot, info = red.Render("●"), red.Render(short(s.Waiting, 50))
		case s.State != "ready":
			dot, info = amber.Render("◌"), dim.Render("starting…")
		}
		line = fmt.Sprintf("  %s %-26s %s %s", dot, short(s.Name, 26), dim.Render(fmt.Sprintf("%-10s", uptime(s.StartedAt))), info)
	} else {
		p := it.project
		info := dim.Render(fmt.Sprintf("%-10s", ago(p.Modified))) + short(p.Description, max(10, w-42))
		if m.busy[p.Name] == "starting" {
			info = amber.Render("starting…")
		}
		line = fmt.Sprintf("    %-26s %s", short(p.Name, 26), info)
	}
	if selected {
		pad := w - lipgloss.Width(line)
		if pad > 0 {
			line += strings.Repeat(" ", pad)
		}
		return cursorStyle.Render(line)
	}
	return line
}

func help(it *item) string {
	k := func(key, what string) string { return keyStyle.Render(key) + dim.Render(" "+what) }
	var parts []string
	switch {
	case it != nil && it.session != nil:
		parts = []string{k("enter", "open"), k("space", "qr"), k("c", "copy link"), k("x", "stop")}
	case it != nil:
		parts = []string{k("enter", "start & open"), k("s", "start")}
	}
	parts = append(parts, k("n", "new"), k("/", "filter"), k("r", "refresh"), k("q", "quit"))
	return strings.Join(parts, dim.Render(" · "))
}

// slugify turns "Todo App" into "todo-app".
func slugify(s string) string {
	s = strings.Join(strings.Fields(strings.ToLower(s)), "-")
	var b strings.Builder
	for _, r := range s {
		if r < 128 && (r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || strings.ContainsRune("-_.", r)) {
			b.WriteRune(r)
		}
	}
	return b.String()
}
