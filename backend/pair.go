package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// `hangar pair` shows a QR code for the app; `hangar devices` lists and revokes paired phones.

type relayStatusFile struct {
	Connected bool      `json:"connected"`
	Error     string    `json:"error,omitempty"`
	Relay     string    `json:"relay"`
	MacID     string    `json:"mac_id"`
	PID       int       `json:"pid"`
	UpdatedAt time.Time `json:"updated_at"`
}

func relayStatusPath() string { return filepath.Join(stateDir, "relay-status.json") }

func writeRelayStatus(connected bool, errText string) {
	id, _ := loadIdentity()
	st := relayStatusFile{Connected: connected, Error: errText, Relay: conf().Relay, PID: os.Getpid(), UpdatedAt: time.Now()}
	if id != nil {
		st.MacID = id.macID()
	}
	data, _ := json.MarshalIndent(st, "", "  ")
	os.WriteFile(relayStatusPath(), data, 0o644)
}

// readRelayStatus reports whether a running `hangar serve` is connected to the relay.
func readRelayStatus() (relayStatusFile, bool) {
	var st relayStatusFile
	data, err := os.ReadFile(relayStatusPath())
	if err != nil || json.Unmarshal(data, &st) != nil {
		return st, false
	}
	alive := st.PID > 0 && processAlive(st.PID)
	return st, alive
}

func cmdPair(args []string) error {
	if conf().Relay == "" {
		return fmt.Errorf("no relay configured (relay = \"\" in %s)", tildePath(configPath()))
	}
	st, alive := readRelayStatus()
	switch {
	case !alive:
		fmt.Println(amber.Render("! ") + "`hangar serve` isn't running, so the app can't reach this Mac. `hangar setup` starts it.")
	case !st.Connected:
		fmt.Println(amber.Render("! ") + "Not connected to the relay yet: " + orDefault(st.Error, "connecting…"))
	}
	link, err := newPairing()
	if err != nil {
		return err
	}
	before := len(loadDevices())
	fmt.Println()
	fmt.Println("  Scan with the iPhone's camera, or in Hangar: Settings → Add a Mac.")
	fmt.Println()
	printQR(os.Stdout, link)
	fmt.Println(dim.Render("  " + link))
	if web := webPairLink(link); web != "" {
		fmt.Println(dim.Render("  To send it to the phone instead: " + web))
	}
	fmt.Println(dim.Render("  The code works once, for 10 minutes."))
	if len(args) > 0 && args[0] == "--no-wait" {
		return nil
	}
	fmt.Println()
	deadline := time.Now().Add(10 * time.Minute)
	for time.Now().Before(deadline) {
		time.Sleep(time.Second)
		if ds := loadDevices(); len(ds) > before {
			d := ds[len(ds)-1]
			fmt.Println(green.Render("✓ ") + "Paired " + bold.Render(d.Name) + ". `hangar devices` lists paired phones.")
			return nil
		}
	}
	return fmt.Errorf("the code expired; run `hangar pair` again")
}

func cmdDevices(args []string) error {
	if len(args) >= 2 && (args[0] == "revoke" || args[0] == "rm" || args[0] == "remove") {
		d, err := revokeDevice(args[1])
		if err != nil {
			return err
		}
		fmt.Println(green.Render("✓ ") + d.Name + " can no longer reach this Mac")
		return nil
	}
	ds := loadDevices()
	if len(ds) == 0 {
		fmt.Println(dim.Render("No paired phones. `hangar pair` adds one."))
		return nil
	}
	for _, d := range ds {
		seen := "never connected"
		if !d.LastSeen.IsZero() {
			seen = "seen " + ago(d.LastSeen)
		}
		fmt.Printf("%-24s %s  %s\n", d.Name, dim.Render(d.ID), dim.Render("paired "+ago(d.AddedAt)+" · "+seen))
	}
	fmt.Println(dim.Render("\n`hangar devices revoke <name>` removes one."))
	return nil
}

func processAlive(pid int) bool { return syscall.Kill(pid, 0) == nil }

// webPairLink is an https link that opens the pairing link in the app, for sending to the phone in
// a message (apps don't make hangar:// links tappable). The parameters go in the fragment, which
// browsers don't send to the server.
func webPairLink(link string) string {
	base := strings.Replace(strings.Replace(conf().Relay, "wss://", "https://", 1), "ws://", "http://", 1)
	q := strings.TrimPrefix(link, "hangar://pair?")
	if base == "" || q == link {
		return ""
	}
	return strings.TrimSuffix(base, "/") + "/pair#" + q
}
