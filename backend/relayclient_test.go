package main

import (
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Paths the app builds from folder names must not take the server down.
func TestCallAPIOddPaths(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/describe/{name...}", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]string{"name": r.PathValue("name")}, nil)
	})
	mux.HandleFunc("POST /api/boom", func(w http.ResponseWriter, r *http.Request) { panic("boom") })
	for path, want := range map[string]int{
		"/api/describe/my project":   200,
		"/api/describe/my%20project": 200,
		"/api/describe/a%zz":         400,
		"/api/describe/проект":       200,
		"/api/boom":                  500,
	} {
		if got := callAPI(mux, rpcRequest{ID: 7, Method: "POST", Path: path}); got.Status != want || got.ID != 7 {
			t.Errorf("%q: status %d, want %d (%s)", path, got.Status, want, got.Body)
		}
	}
}

func TestReplayCache(t *testing.T) {
	c := &replayCache{entries: map[string]*replayEntry{}}
	var runs atomic.Int32
	run := func() rpcResponse {
		runs.Add(1)
		time.Sleep(50 * time.Millisecond)
		return rpcResponse{Status: 200}
	}
	// The same key, while the first is still running and after it: one run, each caller's own ID.
	var wg sync.WaitGroup
	for id := 1; id <= 3; id++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := c.do("phone", rpcRequest{ID: id, Method: "POST", Key: "k"}, run)
			if r.Status != 200 || r.ID != 0 && r.ID != id {
				t.Errorf("id %d got %+v", id, r)
			}
		}()
	}
	wg.Wait()
	if r := c.do("phone", rpcRequest{ID: 9, Method: "POST", Key: "k"}, run); r.ID != 9 {
		t.Errorf("replayed answer has id %d, want 9", r.ID)
	}
	if runs.Load() != 1 {
		t.Fatalf("ran %d times, want 1", runs.Load())
	}
	// Another phone, another key, no key and GETs all run.
	c.do("other", rpcRequest{Method: "POST", Key: "k"}, run)
	c.do("phone", rpcRequest{Method: "POST", Key: "k2"}, run)
	c.do("phone", rpcRequest{Method: "POST"}, run)
	c.do("phone", rpcRequest{Method: "GET", Key: "k"}, run)
	if runs.Load() != 5 {
		t.Fatalf("ran %d times, want 5", runs.Load())
	}
}
