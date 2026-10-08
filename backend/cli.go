package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/mdp/qrterminal/v3"
	"golang.org/x/term"
)

const usageText = `hangar: Claude Code Remote Control sessions for your projects, from the terminal and the iPhone app

  hangar setup           set up this Mac and pair the iPhone app (run this first)
  hangar pair            QR code to pair another phone
  hangar devices [revoke <name>]   paired phones

  hangar                  interactive list (start, stop, open, new project)
  hangar ls [--json]      running sessions
  hangar projects         projects in ~/Dev, most recently changed first
  hangar new <name>       create ~/Dev/<name> and start a session in it
  hangar start <name>     start a session in ~/Dev/<name>  (<name> may be a/b)
  hangar stop <name>      stop a session
  hangar restart <name>  stop it and start it again, continuing the conversation
  hangar rename <name> <new-name>   rename the folder and its session (restarts it if running)
  hangar url <name>       print a session's claude.ai link
  hangar open <name>      open it in the browser
  hangar qr <name>        show its link as a QR code, for the phone
  hangar restore         start the sessions that were running before a reboot (run at login)
  hangar restore --list | --install
  hangar limits           subscription limits (from claude-monitor)
  hangar serve            HTTP API for the iOS app (run by homebase)
`

var (
	green  = lipgloss.NewStyle().Foreground(lipgloss.Color("#4DD9B3"))
	sky    = lipgloss.NewStyle().Foreground(lipgloss.Color("#55B8FF"))
	amber  = lipgloss.NewStyle().Foreground(lipgloss.Color("#F9C255"))
	red    = lipgloss.NewStyle().Foreground(lipgloss.Color("#F5687A"))
	dim    = lipgloss.NewStyle().Foreground(lipgloss.Color("#7B8AA8"))
	bold   = lipgloss.NewStyle().Bold(true)
	errOut = lipgloss.NewStyle().Foreground(lipgloss.Color("#F5687A")).Bold(true)
)

func cliMain(cmd string, args []string) {
	var err error
	switch cmd {
	case "":
		if term.IsTerminal(int(os.Stdout.Fd())) {
			err = runTUI()
		} else {
			err = cmdLs(false)
		}
	case "ls", "list":
		err = cmdLs(len(args) > 0 && args[0] == "--json")
	case "projects":
		err = cmdProjects()
	case "new", "start":
		if len(args) != 1 {
			err = fmt.Errorf("usage: hangar %s <name>", cmd)
			break
		}
		err = cmdStart(args[0], cmd == "new")
	case "restart":
		if len(args) != 1 {
			err = fmt.Errorf("usage: hangar restart <name>")
			break
		}
		err = cmdRestart(args[0])
	case "stop", "url", "open", "qr":
		if len(args) != 1 {
			err = fmt.Errorf("usage: hangar %s <name>", cmd)
			break
		}
		err = cmdSession(cmd, args[0])
	case "describe":
		err = cmdDescribe(args)
	case "rename", "mv":
		err = cmdRename(args)
	case "pair":
		err = cmdPair(args)
	case "devices":
		err = cmdDevices(args)
	case "setup":
		err = cmdSetup(args)
	case "version", "--version":
		fmt.Println("hangar " + version)
	case "restore":
		err = cmdRestore(args)
	case "limits", "usage":
		err = cmdLimits()
	case "help", "-h", "--help":
		fmt.Print(usageText)
	default:
		fmt.Fprint(os.Stderr, usageText)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, errOut.Render("✗ ")+err.Error())
		os.Exit(1)
	}
}

func cmdLs(asJSON bool) error {
	o, err := getOverview()
	if err != nil {
		return err
	}
	if asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(o.Sessions)
	}
	if len(o.Sessions) == 0 {
		fmt.Println(dim.Render("No sessions running."))
		return nil
	}
	for _, s := range o.Sessions {
		fmt.Println(sessionLine(s, 22))
	}
	return nil
}

func sessionLine(s Session, width int) string {
	name := fmt.Sprintf("%-*s", width, s.Name)
	up := dim.Render(fmt.Sprintf("up %-8s", uptime(s.StartedAt)))
	switch {
	case s.State == "ready":
		return green.Render("●") + " " + bold.Render(name) + " " + up + " " + dim.Render(s.URL)
	case s.State == "waiting":
		return amber.Render("●") + " " + bold.Render(name) + " " + up + " " + amber.Render("waiting: "+short(s.Waiting, 60))
	case s.State == "disconnected":
		return red.Render("●") + " " + bold.Render(name) + " " + up + " " + red.Render(short(s.Waiting, 60))
	default:
		return amber.Render("◌") + " " + bold.Render(name) + " " + up + " " + dim.Render("starting…")
	}
}

func cmdProjects() error {
	o, err := getOverview()
	if err != nil {
		return err
	}
	running := map[string]bool{}
	for _, s := range o.Sessions {
		if !s.Server {
			running[s.Dir] = true
		}
	}
	for _, p := range o.Projects {
		dot := "  "
		if running[p.Name] {
			dot = green.Render("● ")
		}
		fmt.Printf("%s%-26s %s %s\n", dot, p.Name, dim.Render(fmt.Sprintf("%-9s", ago(p.Modified))), p.Description)
		if p.LastExit != "" && !running[p.Name] {
			fmt.Printf("  %-26s %s\n", "", red.Render("✗ exited "+ago(p.LastExitAt)+": "+short(p.LastExit, 80)))
		}
	}
	return nil
}

func cmdStart(name string, create bool) error {
	fmt.Fprintln(os.Stderr, dim.Render("Starting "+name+"…"))
	s, err := startSession(startRequest{Dir: name, Create: create})
	if err != nil {
		return err
	}
	switch s.State {
	case "ready":
		fmt.Println(green.Render("● ") + bold.Render(s.Name) + " is ready")
		fmt.Println("  " + s.URL)
	case "waiting":
		fmt.Println(amber.Render("● ") + bold.Render(s.Name) + " is waiting on its terminal:")
		fmt.Println("  " + s.Waiting)
	default:
		fmt.Println(amber.Render("◌ ") + bold.Render(s.Name) + " is still starting; `hangar ls` shows when it's ready")
	}
	return nil
}

// findByName finds a running session by its name or directory.
func findByName(name string) (Session, error) {
	sessions, err := findSessions()
	if err != nil {
		return Session{}, err
	}
	for _, s := range sessions {
		if s.Name == name || (s.Dir == name && !s.Server) {
			return s, nil
		}
	}
	return Session{}, fmt.Errorf("no running session named %s (see `hangar ls`)", name)
}

// cmdRestart fixes a session whose link to the app went quiet: same folder, same conversation.
func cmdRestart(name string) error {
	s, err := findByName(name)
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, dim.Render("Restarting "+s.Name+"…"))
	ns, err := restartSession(s.PID)
	if err != nil {
		return err
	}
	fmt.Println(green.Render("● ") + bold.Render(ns.Name) + " restarted  " + dim.Render(orDefault(ns.URL, ns.State)))
	return nil
}

func cmdSession(cmd, name string) error {
	s, err := findByName(name)
	if err != nil {
		return err
	}
	if cmd == "stop" {
		if err := stopSession(s.PID); err != nil {
			return err
		}
		fmt.Println(dim.Render("■ ") + s.Name + " stopped")
		return nil
	}
	if s.URL == "" {
		return fmt.Errorf("%s has no link yet (state: %s)", s.Name, s.State)
	}
	switch cmd {
	case "url":
		fmt.Println(s.URL)
	case "open":
		return exec.Command("open", s.URL).Run()
	case "qr":
		printQR(os.Stdout, s.URL)
		fmt.Println(dim.Render(s.URL))
	}
	return nil
}

func printQR(w io.Writer, url string) {
	qrterminal.GenerateWithConfig(url, qrterminal.Config{
		Level: qrterminal.L, Writer: w, HalfBlocks: true,
		BlackChar: qrterminal.BLACK_BLACK, WhiteChar: qrterminal.WHITE_WHITE,
		BlackWhiteChar: qrterminal.BLACK_WHITE, WhiteBlackChar: qrterminal.WHITE_BLACK, QuietZone: 1,
	})
}

func cmdLimits() error {
	u, err := fetchUsage(false)
	if err != nil {
		return err
	}
	for _, l := range u.Limits {
		reset := ""
		if l.ResetsAt != nil {
			reset = dim.Render("resets in " + countdown(*l.ResetsAt))
		}
		fmt.Printf("%-28s %s %s  %s\n", strings.TrimPrefix(l.Label, "Current "), bar(l.Percent, 20),
			pctStyle(l.Percent).Render(fmt.Sprintf("%3.0f%%", l.Percent)), reset)
	}
	return nil
}

func pctStyle(p float64) lipgloss.Style {
	switch {
	case p >= 90:
		return red
	case p >= 70:
		return amber
	default:
		return green
	}
}

func bar(p float64, width int) string {
	n := int(p/100*float64(width) + 0.5)
	n = max(0, min(width, n))
	return pctStyle(p).Render(strings.Repeat("━", n)) + dim.Render(strings.Repeat("━", width-n))
}

func uptime(since time.Time) string {
	m := int(time.Since(since).Minutes())
	switch {
	case m < 60:
		return fmt.Sprintf("%dm", m)
	case m < 24*60:
		return fmt.Sprintf("%dh %dm", m/60, m%60)
	default:
		return fmt.Sprintf("%dd %dh", m/(24*60), m/60%24)
	}
}

func countdown(t time.Time) string {
	d := time.Until(t)
	if d < time.Minute {
		return "<1m"
	}
	m := int(d.Minutes())
	switch {
	case m < 60:
		return fmt.Sprintf("%dm", m)
	case m < 24*60:
		return fmt.Sprintf("%dh %dm", m/60, m%60)
	default:
		return fmt.Sprintf("%dd %dh", m/(24*60), m/60%24)
	}
}

func ago(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	case d < 60*24*time.Hour:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	default:
		return t.Format("Jan 2006")
	}
}

func short(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n-1]) + "…"
	}
	return s
}
