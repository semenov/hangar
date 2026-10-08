package main

import (
	"testing"
	"time"
)

const sample = `You are currently using your subscription to power your Claude Code usage

Current session: 2% used · resets Oct 7 at 4am (Europe/Belgrade)
Current week (all models): 12% used · resets Oct 10 at 5pm (Europe/Belgrade)
Current week (Fable): 0% used · resets Oct 10 at 5:30pm (Europe/Belgrade)

What's contributing to your limits usage?
Approximate, based on local sessions on this machine — does not include other devices or claude.ai.

Last 7d · 4700 requests · 18 sessions
  45% of your usage was at >150k context
`

func TestParseUsage(t *testing.T) {
	loc, _ := time.LoadLocation("Europe/Belgrade")
	now := time.Date(2026, 10, 7, 0, 30, 0, 0, loc)
	u := parseUsage(sample, now)
	if len(u.Limits) != 3 {
		t.Fatalf("limits = %d", len(u.Limits))
	}
	if l := u.Limits[1]; l.ID != "current-week-all-models" || l.Percent != 12 {
		t.Errorf("bad limit %+v", l)
	}
	want := time.Date(2026, 10, 7, 4, 0, 0, 0, loc)
	if got := u.Limits[0].ResetsAt; got == nil || !got.Equal(want) {
		t.Errorf("session reset = %v, want %v", got, want)
	}
	want = time.Date(2026, 10, 10, 17, 30, 0, 0, loc)
	if got := u.Limits[2].ResetsAt; got == nil || !got.Equal(want) {
		t.Errorf("fable reset = %v, want %v", got, want)
	}
	if len(u.Insights) != 2 || u.Insights[0] != "Last 7d · 4700 requests · 18 sessions" {
		t.Errorf("insights = %q", u.Insights)
	}
}

func TestParseResetTimeOnly(t *testing.T) {
	loc, _ := time.LoadLocation("Europe/Belgrade")
	now := time.Date(2026, 10, 7, 10, 0, 0, 0, loc)
	got := parseReset("4am (Europe/Belgrade)", now)
	if want := time.Date(2026, 10, 8, 4, 0, 0, 0, loc); got == nil || !got.Equal(want) {
		t.Errorf("got %v, want %v", got, want)
	}
}
