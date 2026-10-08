// hangar-relay connects the Hangar iPhone app to Macs running `hangar serve`, so neither side
// needs an open port. Everything after the handshake's public keys is end-to-end encrypted
// between the phone and the Mac; the relay just moves frames.
//
//	GET /v1/mac?id=<mac id>    the Mac: proves it owns the ID, then carries every phone's
//	                           frames as channel (uint32) ‖ kind (1 open, 2 data, 3 close) ‖ payload
//	GET /v1/phone?id=<mac id>  a phone: plain frames, forwarded on its own channel
//	GET /healthz
//
// Built on nbio: connections are served by an event loop rather than a goroutine each, so an
// idle Mac costs a few KB. nbio runs each connection's messages one at a time, in order, which the
// end-to-end channel's counters rely on.
package main

import (
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
	"os/signal"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/lesismal/nbio/nbhttp"
	"github.com/lesismal/nbio/nbhttp/websocket"
)

const (
	frameOpen  = 1
	frameData  = 2
	frameClose = 3

	maxFrame        = 4 << 20
	maxPhonesPerMac = 32
	pingEvery       = 25 * time.Second
	idleTimeout     = 80 * time.Second // no frame or pong for this long: the peer is gone
	authTimeout     = 15 * time.Second
)

var macIDRe = regexp.MustCompile(`^[0-9a-f]{32}$`)

// macState is a Mac's connection: before auth it holds the challenge, after it the phones.
type macState struct {
	id     string
	nonce  []byte
	mu     sync.Mutex
	authed bool
	phones map[uint32]*websocket.Conn
	next   uint32
}

type phoneState struct {
	mac  *websocket.Conn
	ms   *macState
	chID uint32
}

type relay struct {
	mu   sync.Mutex
	macs map[string]*websocket.Conn
	// Every connection, for the keepalive pass.
	conns sync.Map // *websocket.Conn → struct{}

	macCount, phoneCount atomic.Int64
}

func frame(ch uint32, kind byte, payload []byte) []byte {
	f := make([]byte, 5+len(payload))
	binary.BigEndian.PutUint32(f, ch)
	f[4] = kind
	copy(f[5:], payload)
	return f
}

// closeWith sends a close frame with a code the app understands (4404 offline, ...) and closes.
func closeWith(c *websocket.Conn, code int, reason string) {
	c.WriteClose(code, reason)
	c.Close()
}

func (rl *relay) macUpgrader() *websocket.Upgrader {
	u := websocket.NewUpgrader()
	u.KeepaliveTime = idleTimeout
	u.MessageLengthLimit = maxFrame
	rl.macHandlers(u)
	return u
}

// macOpened runs once the Mac's connection has its session: nbio calls OnOpen inside Upgrade,
// before the handler can attach one. The connection's messages are handled only after the
// handler returns, so nothing arrives before this.
func (rl *relay) macOpened(c *websocket.Conn, ms *macState) {
	rl.conns.Store(c, struct{}{})
	ch, _ := json.Marshal(map[string]string{"challenge": base64.StdEncoding.EncodeToString(ms.nonce)})
	c.WriteMessage(websocket.TextMessage, ch)
	time.AfterFunc(authTimeout, func() {
		ms.mu.Lock()
		ok := ms.authed
		ms.mu.Unlock()
		if !ok {
			c.Close()
		}
	})
}

func (rl *relay) macHandlers(u *websocket.Upgrader) {
	u.OnMessage(func(c *websocket.Conn, mt websocket.MessageType, data []byte) {
		ms := c.Session().(*macState)
		ms.mu.Lock()
		authed := ms.authed
		ms.mu.Unlock()
		if !authed {
			rl.authMac(c, ms, data)
			return
		}
		if len(data) < 5 {
			return
		}
		chID, kind := binary.BigEndian.Uint32(data), data[4]
		ms.mu.Lock()
		p := ms.phones[chID]
		ms.mu.Unlock()
		if p == nil {
			return
		}
		switch kind {
		case frameData:
			p.WriteMessage(websocket.BinaryMessage, data[5:])
		case frameClose:
			closeWith(p, 1000, "closed by mac")
		}
	})
	u.OnClose(func(c *websocket.Conn, err error) {
		rl.conns.Delete(c)
		ms, _ := c.Session().(*macState)
		if ms == nil {
			return
		}
		ms.mu.Lock()
		authed := ms.authed
		phones := ms.phones
		ms.phones = map[uint32]*websocket.Conn{}
		ms.mu.Unlock()
		if !authed {
			return
		}
		rl.mu.Lock()
		if rl.macs[ms.id] == c {
			delete(rl.macs, ms.id)
		}
		rl.mu.Unlock()
		rl.macCount.Add(-1)
		for _, p := range phones {
			closeWith(p, 4404, "mac went offline")
		}
		log.Printf("mac %s… disconnected", ms.id[:8])
	})
}

// authMac checks the Mac's answer to the challenge: an Ed25519 signature by the key whose hash is
// its ID.
func (rl *relay) authMac(c *websocket.Conn, ms *macState, data []byte) {
	var auth struct{ ID, Key, Sig string }
	json.Unmarshal(data, &auth)
	key, _ := base64.StdEncoding.DecodeString(auth.Key)
	sig, _ := base64.StdEncoding.DecodeString(auth.Sig)
	sum := sha256.Sum256(key)
	if auth.ID != ms.id || len(key) != ed25519.PublicKeySize || hex.EncodeToString(sum[:16]) != ms.id ||
		!ed25519.Verify(key, append([]byte("hangar-relay-v1"), ms.nonce...), sig) {
		c.WriteMessage(websocket.TextMessage, []byte(`{"ok":false,"error":"bad signature"}`))
		closeWith(c, 1008, "bad signature")
		return
	}
	ms.mu.Lock()
	ms.authed = true
	ms.mu.Unlock()
	c.WriteMessage(websocket.TextMessage, []byte(`{"ok":true}`))
	rl.mu.Lock()
	old := rl.macs[ms.id]
	rl.macs[ms.id] = c
	rl.mu.Unlock()
	if old != nil { // the Mac reconnected; its phones reconnect too
		closeWith(old, 1001, "replaced")
	}
	rl.macCount.Add(1)
	log.Printf("mac %s… connected", ms.id[:8])
}

func (rl *relay) phoneUpgrader() *websocket.Upgrader {
	u := websocket.NewUpgrader()
	u.KeepaliveTime = idleTimeout
	u.MessageLengthLimit = maxFrame
	rl.phoneHandlers(u)
	return u
}

// phoneOpened: see macOpened.
func (rl *relay) phoneOpened(c *websocket.Conn, ps *phoneState) {
	rl.conns.Store(c, struct{}{})
	if ps.mac == nil {
		closeWith(c, 4404, "mac offline")
		return
	}
	ps.ms.mu.Lock()
	if len(ps.ms.phones) >= maxPhonesPerMac {
		ps.ms.mu.Unlock()
		ps.mac = nil
		closeWith(c, 4429, "too many connections")
		return
	}
	ps.ms.next++
	ps.chID = ps.ms.next
	ps.ms.phones[ps.chID] = c
	ps.ms.mu.Unlock()
	rl.phoneCount.Add(1)
	if ps.mac.WriteMessage(websocket.BinaryMessage, frame(ps.chID, frameOpen, nil)) != nil {
		closeWith(c, 4404, "mac offline")
	}
}

func (rl *relay) phoneHandlers(u *websocket.Upgrader) {
	u.OnMessage(func(c *websocket.Conn, mt websocket.MessageType, data []byte) {
		ps := c.Session().(*phoneState)
		if ps.mac == nil || ps.chID == 0 {
			return
		}
		if ps.mac.WriteMessage(websocket.BinaryMessage, frame(ps.chID, frameData, data)) != nil {
			closeWith(c, 4404, "mac went offline")
		}
	})
	u.OnClose(func(c *websocket.Conn, err error) {
		rl.conns.Delete(c)
		ps, _ := c.Session().(*phoneState)
		if ps == nil || ps.mac == nil || ps.chID == 0 {
			return
		}
		ps.ms.mu.Lock()
		_, still := ps.ms.phones[ps.chID]
		delete(ps.ms.phones, ps.chID)
		ps.ms.mu.Unlock()
		rl.phoneCount.Add(-1)
		if still {
			ps.mac.WriteMessage(websocket.BinaryMessage, frame(ps.chID, frameClose, nil))
		}
	})
}

// keepalive pings every connection; nbio's read deadline (idleTimeout) closes the silent ones.
// Proxies and NATs drop idle WebSockets otherwise.
func (rl *relay) keepalive() {
	for range time.Tick(pingEvery) {
		rl.conns.Range(func(k, _ any) bool {
			k.(*websocket.Conn).WriteMessage(websocket.PingMessage, nil)
			return true
		})
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	rl := &relay{macs: map[string]*websocket.Conn{}}
	macUp, phoneUp := rl.macUpgrader(), rl.phoneUpgrader()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/mac", func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Query().Get("id")
		if !macIDRe.MatchString(id) {
			http.Error(w, "bad id", http.StatusBadRequest)
			return
		}
		nonce := make([]byte, 32)
		rand.Read(nonce)
		c, err := macUp.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		ms := &macState{id: id, nonce: nonce, phones: map[uint32]*websocket.Conn{}}
		c.SetSession(ms)
		rl.macOpened(c, ms)
	})
	mux.HandleFunc("GET /v1/phone", func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Query().Get("id")
		if !macIDRe.MatchString(id) {
			http.Error(w, "bad id", http.StatusBadRequest)
			return
		}
		rl.mu.Lock()
		mc := rl.macs[id]
		rl.mu.Unlock()
		ps := &phoneState{mac: mc}
		if mc != nil {
			ps.ms = mc.Session().(*macState)
		}
		c, err := phoneUp.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		c.SetSession(ps)
		rl.phoneOpened(c, ps)
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]int64{"macs": rl.macCount.Load(), "phones": rl.phoneCount.Load()})
	})
	mux.HandleFunc("GET /{$}", page(landingHTML))
	mux.HandleFunc("GET /privacy", page(privacyHTML))
	mux.HandleFunc("GET /pair", page(pairHTML))

	conf := nbhttp.Config{
		Network:                 "tcp",
		Handler:                 mux,
		ReleaseWebsocketPayload: true,
		MaxLoad:                 1 << 20,
	}
	// TLS_DOMAINS: serve HTTPS on 443 ourselves (own server); else plain HTTP on $PORT behind a proxy.
	if domains := strings.FieldsFunc(os.Getenv("TLS_DOMAINS"), func(r rune) bool { return r == ',' || r == ' ' }); len(domains) > 0 {
		conf.AddrsTLS = []string{":443"}
		conf.TLSConfig = autocertTLS(domains, envOr("CERT_DIR", "/var/lib/hangar-relay/certs"))
		log.Printf("TLS for %s", strings.Join(domains, ", "))
	} else {
		conf.Addrs = []string{":" + port}
	}
	engine := nbhttp.NewEngine(conf)
	if err := engine.Start(); err != nil {
		log.Fatal(err)
	}
	go rl.keepalive()
	log.Printf("hangar-relay on %v %v", conf.Addrs, conf.AddrsTLS)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	engine.Stop()
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func page(html string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(html))
	}
}
