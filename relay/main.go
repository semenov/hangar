// hangar-relay connects the Hangar iPhone app to Macs running `hangar serve`, so neither side
// needs an open port. Everything after the handshake's public keys is end-to-end encrypted
// between the phone and the Mac; the relay just moves frames.
//
//	GET /v1/mac?id=<mac id>    the Mac: proves it owns the ID, then carries every phone's
//	                           frames as channel (uint32) ‖ kind (1 open, 2 data, 3 close) ‖ payload
//	GET /v1/phone?id=<mac id>  a phone: plain frames, forwarded on its own channel
//	GET /healthz
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"regexp"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

const (
	frameOpen  = 1
	frameData  = 2
	frameClose = 3

	maxFrame        = 4 << 20
	maxPhonesPerMac = 32
	pingEvery       = 25 * time.Second
)

var macIDRe = regexp.MustCompile(`^[0-9a-f]{32}$`)

type mac struct {
	conn   *websocket.Conn
	ctx    context.Context
	wmu    sync.Mutex
	mu     sync.Mutex
	phones map[uint32]*websocket.Conn
	next   uint32
}

type relay struct {
	mu   sync.Mutex
	macs map[string]*mac
	// Counters for /healthz.
	macCount, phoneCount atomic.Int64
}

func (m *mac) write(ch uint32, kind byte, payload []byte) error {
	frame := make([]byte, 5+len(payload))
	binary.BigEndian.PutUint32(frame, ch)
	frame[4] = kind
	copy(frame[5:], payload)
	m.wmu.Lock()
	defer m.wmu.Unlock()
	ctx, cancel := context.WithTimeout(m.ctx, 30*time.Second)
	defer cancel()
	return m.conn.Write(ctx, websocket.MessageBinary, frame)
}

func keepalive(ctx context.Context, c *websocket.Conn) {
	t := time.NewTicker(pingEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			pctx, cancel := context.WithTimeout(ctx, 15*time.Second)
			err := c.Ping(pctx)
			cancel()
			if err != nil {
				c.Close(websocket.StatusGoingAway, "ping timeout")
				return
			}
		}
	}
}

func (rl *relay) serveMac(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if !macIDRe.MatchString(id) {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	c, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer c.CloseNow()
	c.SetReadLimit(maxFrame)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	// Challenge: the Mac signs a nonce with the Ed25519 key whose hash is its ID.
	nonce := make([]byte, 32)
	rand.Read(nonce)
	ch, _ := json.Marshal(map[string]string{"challenge": base64.StdEncoding.EncodeToString(nonce)})
	actx, acancel := context.WithTimeout(ctx, 15*time.Second)
	defer acancel()
	if err := c.Write(actx, websocket.MessageText, ch); err != nil {
		return
	}
	_, data, err := c.Read(actx)
	if err != nil {
		return
	}
	var auth struct{ ID, Key, Sig string }
	json.Unmarshal(data, &auth)
	key, _ := base64.StdEncoding.DecodeString(auth.Key)
	sig, _ := base64.StdEncoding.DecodeString(auth.Sig)
	sum := sha256.Sum256(key)
	if auth.ID != id || len(key) != ed25519.PublicKeySize || hex.EncodeToString(sum[:16]) != id ||
		!ed25519.Verify(key, append([]byte("hangar-relay-v1"), nonce...), sig) {
		c.Write(actx, websocket.MessageText, []byte(`{"ok":false,"error":"bad signature"}`))
		c.Close(websocket.StatusPolicyViolation, "bad signature")
		return
	}
	c.Write(actx, websocket.MessageText, []byte(`{"ok":true}`))

	m := &mac{conn: c, ctx: ctx, phones: map[uint32]*websocket.Conn{}}
	rl.mu.Lock()
	old := rl.macs[id]
	rl.macs[id] = m
	rl.mu.Unlock()
	if old != nil { // the Mac reconnected; its phones reconnect too
		old.conn.Close(websocket.StatusGoingAway, "replaced")
	}
	rl.macCount.Add(1)
	defer rl.macCount.Add(-1)
	log.Printf("mac %s… connected", id[:8])
	defer func() {
		rl.mu.Lock()
		if rl.macs[id] == m {
			delete(rl.macs, id)
		}
		rl.mu.Unlock()
		m.mu.Lock()
		for _, p := range m.phones {
			p.Close(4404, "mac went offline")
		}
		m.mu.Unlock()
		log.Printf("mac %s… disconnected", id[:8])
	}()
	go keepalive(ctx, c)

	for {
		_, frame, err := c.Read(ctx)
		if err != nil {
			return
		}
		if len(frame) < 5 {
			continue
		}
		chID, kind := binary.BigEndian.Uint32(frame), frame[4]
		m.mu.Lock()
		p := m.phones[chID]
		m.mu.Unlock()
		if p == nil {
			continue
		}
		switch kind {
		case frameData:
			wctx, wcancel := context.WithTimeout(ctx, 30*time.Second)
			p.Write(wctx, websocket.MessageBinary, frame[5:])
			wcancel()
		case frameClose:
			p.Close(websocket.StatusNormalClosure, "closed by mac")
		}
	}
}

func (rl *relay) servePhone(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if !macIDRe.MatchString(id) {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	c, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer c.CloseNow()
	c.SetReadLimit(maxFrame)
	ctx := r.Context()

	rl.mu.Lock()
	m := rl.macs[id]
	rl.mu.Unlock()
	if m == nil {
		c.Close(4404, "mac offline")
		return
	}
	m.mu.Lock()
	if len(m.phones) >= maxPhonesPerMac {
		m.mu.Unlock()
		c.Close(4429, "too many connections")
		return
	}
	m.next++
	chID := m.next
	m.phones[chID] = c
	m.mu.Unlock()
	rl.phoneCount.Add(1)
	defer rl.phoneCount.Add(-1)
	defer func() {
		m.mu.Lock()
		delete(m.phones, chID)
		m.mu.Unlock()
		m.write(chID, frameClose, nil)
	}()
	if err := m.write(chID, frameOpen, nil); err != nil {
		c.Close(4404, "mac offline")
		return
	}
	go keepalive(ctx, c)

	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			return
		}
		if err := m.write(chID, frameData, data); err != nil {
			c.Close(4404, "mac went offline")
			return
		}
	}
}

func page(html string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(html))
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	rl := &relay{macs: map[string]*mac{}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/mac", rl.serveMac)
	mux.HandleFunc("GET /v1/phone", rl.servePhone)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]int64{"macs": rl.macCount.Load(), "phones": rl.phoneCount.Load()})
	})
	mux.HandleFunc("GET /{$}", page(landingHTML))
	mux.HandleFunc("GET /privacy", page(privacyHTML))
	log.Printf("hangar-relay on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
