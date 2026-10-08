package main

import (
	"context"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Subscription limits, from the output of `claude -p /usage` (parser from claude-monitor).
// Fetched only when asked for, and cached for a minute.

// Limit is one row of `/usage`, e.g.
// "Current week (all models): 12% used · resets Oct 10 at 5pm (Europe/Belgrade)".
type Limit struct {
	ID       string     `json:"id"`
	Label    string     `json:"label"`
	Percent  float64    `json:"percent"`
	ResetsAt *time.Time `json:"resets_at,omitempty"`
	Resets   string     `json:"resets"`
}

type Usage struct {
	Plan      string    `json:"plan"`
	Limits    []Limit   `json:"limits"`
	Insights  []string  `json:"insights"`
	FetchedAt time.Time `json:"fetched_at"`
}

var (
	limitRe = regexp.MustCompile(`^(.+?):\s*([\d.]+)%\s*used(?:\s*·\s*resets\s+(.+?))?\s*$`)
	resetRe = regexp.MustCompile(`^(?:([A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*(?:\(([^)]+)\))?$`)
	nonID   = regexp.MustCompile(`[^a-z0-9]+`)
)

func parseUsage(out string, now time.Time) Usage {
	u := Usage{FetchedAt: now, Limits: []Limit{}, Insights: []string{}}
	inInsights := false
	for _, line := range strings.Split(out, "\n") {
		t := strings.TrimSpace(line)
		if t == "" {
			continue
		}
		if m := limitRe.FindStringSubmatch(t); m != nil {
			pct, _ := strconv.ParseFloat(m[2], 64)
			l := Limit{
				ID:      strings.Trim(nonID.ReplaceAllString(strings.ToLower(m[1]), "-"), "-"),
				Label:   m[1],
				Percent: pct,
				Resets:  m[3],
			}
			l.ResetsAt = parseReset(m[3], now)
			u.Limits = append(u.Limits, l)
			continue
		}
		switch {
		case strings.HasPrefix(t, "You are currently using"):
			u.Plan = t
		case strings.HasPrefix(t, "What's contributing"):
			inInsights = true
		case inInsights && !strings.HasPrefix(t, "Approximate,"):
			u.Insights = append(u.Insights, t)
		}
	}
	return u
}

// parseReset turns "Oct 10 at 5pm (Europe/Belgrade)" or "4am (Europe/Belgrade)"
// into the next matching instant. Returns nil when the format is unknown.
func parseReset(s string, now time.Time) *time.Time {
	m := resetRe.FindStringSubmatch(strings.TrimSpace(s))
	if m == nil {
		return nil
	}
	loc := time.Local
	if m[6] != "" {
		if l, err := time.LoadLocation(m[6]); err == nil {
			loc = l
		}
	}
	now = now.In(loc)
	hour, _ := strconv.Atoi(m[3])
	minute, _ := strconv.Atoi(m[4])
	hour %= 12
	if m[5] == "pm" {
		hour += 12
	}
	year, month, day := now.Date()
	if m[1] != "" {
		mon, err := time.Parse("Jan", m[1])
		if err != nil {
			return nil
		}
		month = mon.Month()
		day, _ = strconv.Atoi(m[2])
	}
	t := time.Date(year, month, day, hour, minute, 0, 0, loc)
	// Dates are given without a year (and sometimes without a day): roll forward.
	for t.Before(now.Add(-time.Hour)) {
		if m[1] != "" {
			t = t.AddDate(1, 0, 0)
		} else {
			t = t.AddDate(0, 0, 1)
		}
	}
	return &t
}

const usageTTL = 60 * time.Second

var usageCache struct {
	sync.Mutex
	last *Usage
}

// fetchUsage runs `claude -p /usage` unless the last answer is under a minute old (or force).
func fetchUsage(force bool) (Usage, error) {
	usageCache.Lock()
	defer usageCache.Unlock()
	if !force && usageCache.last != nil && time.Since(usageCache.last.FetchedAt) < usageTTL {
		return *usageCache.last, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, claudeBin(), "-p", "/usage")
	cmd.Dir = os.TempDir()
	cmd.Env = cleanEnv()
	out, err := cmd.Output()
	if err != nil {
		if usageCache.last != nil {
			return *usageCache.last, nil // stale beats nothing
		}
		return Usage{}, err
	}
	u := parseUsage(string(out), time.Now().Truncate(time.Second))
	usageCache.last = &u
	return u, nil
}

func execOutput(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).Output()
	return string(out), err
}
