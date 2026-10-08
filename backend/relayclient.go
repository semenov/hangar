package main

import (
	"bytes"
	"compress/flate"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// The Mac's side of the relay. The Mac keeps one WebSocket to the relay; every phone that
// connects gets a channel on it. Frames between the Mac and the relay are
//
//	channel (uint32, big-endian) ‖ kind (1 byte) ‖ payload
//
// with kind 1 = a phone connected, 2 = data, 3 = the phone (or the Mac) closed the channel.
// The relay sees only the handshake's public keys and ciphertext.

const (
	frameOpen  = 1
	frameData  = 2
	frameClose = 3
)

// The relay's challenge, so that only the owner of the Ed25519 key can serve this Mac ID.
type relayChallenge struct {
	Challenge string `json:"challenge"`
}

type relayAuth struct {
	ID  string `json:"id"`
	Key string `json:"key"`
	Sig string `json:"sig"`
}

// rpcRequest is an API call tunnelled through a secure channel.
type rpcRequest struct {
	ID     int             `json:"id"`
	Method string          `json:"method"`
	Path   string          `json:"path"`
	Body   json.RawMessage `json:"body,omitempty"`
	// The ETag of the response the phone already has: an unchanged GET answers 304 with no body.
	IfNoneMatch string `json:"if_none_match,omitempty"`
}

type rpcResponse struct {
	ID     int             `json:"id"`
	Status int             `json:"status"`
	Body   json.RawMessage `json:"body"`
	ETag   string          `json:"etag,omitempty"`
}

var relayStatus struct {
	sync.Mutex
	connected bool
	err       string
	since     time.Time
}

func setRelayStatus(connected bool, err string) {
	relayStatus.Lock()
	defer relayStatus.Unlock()
	if relayStatus.connected != connected {
		relayStatus.since = time.Now()
	}
	relayStatus.connected, relayStatus.err = connected, err
	writeRelayStatus(connected, err)
}

// runRelay stays connected to the relay, reconnecting with backoff.
func runRelay(relay string, api http.Handler) {
	id, err := loadIdentity()
	if err != nil {
		log.Printf("relay: %v", err)
		return
	}
	backoff := time.Second
	for {
		start := time.Now()
		err := relaySession(relay, id, api)
		setRelayStatus(false, errString(err))
		if time.Since(start) > time.Minute {
			backoff = time.Second
		}
		log.Printf("relay: %v; reconnecting in %s", err, backoff)
		time.Sleep(backoff)
		backoff = min(backoff*2, time.Minute)
	}
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func relaySession(relay string, id *identity, api http.Handler) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	dialCtx, dialCancel := context.WithTimeout(ctx, 20*time.Second)
	conn, _, err := websocket.Dial(dialCtx, strings.TrimSuffix(relay, "/")+"/v1/mac?id="+id.macID(), nil)
	dialCancel()
	if err != nil {
		return err
	}
	defer conn.CloseNow()
	conn.SetReadLimit(4 << 20)

	// Prove we own the Mac ID.
	_, data, err := conn.Read(ctx)
	if err != nil {
		return err
	}
	var ch relayChallenge
	if err := json.Unmarshal(data, &ch); err != nil || ch.Challenge == "" {
		return fmt.Errorf("unexpected greeting %q", data)
	}
	nonce, err := base64.StdEncoding.DecodeString(ch.Challenge)
	if err != nil {
		return err
	}
	pub := id.SignKey.Public().(ed25519.PublicKey)
	auth, _ := json.Marshal(relayAuth{
		ID:  id.macID(),
		Key: base64.StdEncoding.EncodeToString(pub),
		Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(id.SignKey, append([]byte("hangar-relay-v1"), nonce...))),
	})
	if err := conn.Write(ctx, websocket.MessageText, auth); err != nil {
		return err
	}
	_, data, err = conn.Read(ctx)
	if err != nil {
		return err
	}
	if !bytes.Contains(data, []byte(`"ok":true`)) {
		return fmt.Errorf("relay refused: %s", data)
	}
	setRelayStatus(true, "")
	log.Printf("relay: connected to %s as %s", relay, id.macID())

	// Keepalive: proxies drop idle WebSockets.
	go func() {
		t := time.NewTicker(25 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				pctx, pc := context.WithTimeout(ctx, 15*time.Second)
				err := conn.Ping(pctx)
				pc()
				if err != nil {
					conn.Close(websocket.StatusGoingAway, "ping timeout")
					return
				}
			}
		}
	}()

	m := &macMux{conn: conn, ctx: ctx, id: id, api: api, chans: map[uint32]*phoneChannel{}}
	for {
		_, frame, err := conn.Read(ctx)
		if err != nil {
			return err
		}
		if len(frame) < 5 {
			continue
		}
		m.handle(binary.BigEndian.Uint32(frame), frame[4], frame[5:])
	}
}

type macMux struct {
	conn  *websocket.Conn
	ctx   context.Context
	id    *identity
	api   http.Handler
	wmu   sync.Mutex
	mu    sync.Mutex
	chans map[uint32]*phoneChannel
}

type phoneChannel struct {
	mu       sync.Mutex // serializes sealing (the nonce counter)
	sc       *secureChannel
	phoneKey []byte
	deflate  bool // agreed in the handshake: messages carry a flag byte and may be compressed
}

// send seals and writes a message under the channel's lock, so counters reach the phone in order.
func (m *macMux) send(ch uint32, pc *phoneChannel, plain []byte) {
	pc.mu.Lock()
	defer pc.mu.Unlock()
	if pc.deflate {
		plain = packMessage(plain)
	}
	m.write(ch, frameData, pc.sc.seal(plain))
}

func (m *macMux) write(ch uint32, kind byte, payload []byte) error {
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

func (m *macMux) closeChan(ch uint32, why string) {
	m.mu.Lock()
	delete(m.chans, ch)
	m.mu.Unlock()
	if why != "" {
		msg, _ := json.Marshal(map[string]string{"t": "error", "error": why})
		m.write(ch, frameData, msg)
	}
	m.write(ch, frameClose, nil)
}

func (m *macMux) handle(ch uint32, kind byte, payload []byte) {
	switch kind {
	case frameOpen:
		m.mu.Lock()
		m.chans[ch] = &phoneChannel{}
		m.mu.Unlock()
	case frameClose:
		m.mu.Lock()
		delete(m.chans, ch)
		m.mu.Unlock()
	case frameData:
		m.mu.Lock()
		pc := m.chans[ch]
		m.mu.Unlock()
		if pc == nil {
			return
		}
		if pc.sc == nil {
			m.handshake(ch, pc, payload)
			return
		}
		pc.mu.Lock()
		plain, err := pc.sc.open(payload)
		if err == nil && pc.deflate {
			plain, err = unpackMessage(plain)
		}
		pc.mu.Unlock()
		if err != nil {
			m.closeChan(ch, "bad frame")
			return
		}
		go m.serveRequest(ch, pc, plain)
	}
}

type handshakeMsg struct {
	T        string   `json:"t"`
	Compress []string `json:"compress,omitempty"` // what the phone can decompress, e.g. ["deflate"]
	Key      []byte   `json:"key"`
	Eph      []byte   `json:"eph"`
	Name     string   `json:"name,omitempty"`
	Proof    []byte   `json:"proof,omitempty"`
}

func (m *macMux) handshake(ch uint32, pc *phoneChannel, payload []byte) {
	var h handshakeMsg
	if err := json.Unmarshal(payload, &h); err != nil || len(h.Key) != 32 || len(h.Eph) != 32 {
		m.closeChan(ch, "bad handshake")
		return
	}
	switch h.T {
	case "hello":
		if findDevice(h.Key) == nil {
			m.closeChan(ch, "not paired") // revoked, or this Mac's keys were reset
			return
		}
	case "pair":
		if !checkPairing(h.Key, h.Eph, h.Proof) {
			m.closeChan(ch, "pairing code expired or already used; run `hangar pair` for a new one")
			return
		}
		name := strings.TrimSpace(h.Name)
		if name == "" {
			name = "iPhone"
		}
		d, err := addDevice(name, h.Key)
		if err != nil {
			m.closeChan(ch, err.Error())
			return
		}
		log.Printf("relay: paired %s (%s)", d.Name, d.ID)
	default:
		m.closeChan(ch, "bad handshake")
		return
	}
	eph, err := newEphemeral()
	if err != nil {
		m.closeChan(ch, err.Error())
		return
	}
	sc, err := deriveChannel(m.id.dhPrivate(), eph, h.Key, h.Eph)
	if err != nil {
		m.closeChan(ch, "bad keys")
		return
	}
	w := map[string]any{"t": "welcome", "eph": eph.PublicKey().Bytes(), "name": conf().MacName}
	for _, c := range h.Compress {
		if c == "deflate" {
			pc.deflate = true
			w["compress"] = "deflate"
		}
	}
	welcome, _ := json.Marshal(w)
	pc.sc, pc.phoneKey = sc, h.Key
	m.write(ch, frameData, welcome)
	touchDevice(h.Key)
}

// serveRequest runs one tunnelled API call through the same handlers as the HTTP API.
func (m *macMux) serveRequest(ch uint32, pc *phoneChannel, plain []byte) {
	var req rpcRequest
	if err := json.Unmarshal(plain, &req); err != nil {
		return
	}
	if findDevice(pc.phoneKey) == nil { // revoked while connected
		m.closeChan(ch, "not paired")
		return
	}
	if req.Path == "/api/unpair" { // the phone removed this Mac: forget it here too
		d := findDevice(pc.phoneKey)
		revokeDevice(d.ID)
		log.Printf("relay: %s unpaired itself", d.Name)
		resp, _ := json.Marshal(rpcResponse{ID: req.ID, Status: 200, Body: json.RawMessage(`{"ok":true}`)})
		m.send(ch, pc, resp)
		m.closeChan(ch, "")
		return
	}
	if !strings.HasPrefix(req.Path, "/api/") {
		req.Path = "/api/" + strings.TrimPrefix(req.Path, "/")
	}
	var body *bytes.Reader
	if len(req.Body) > 0 {
		body = bytes.NewReader(req.Body)
	} else {
		body = bytes.NewReader(nil)
	}
	r := httptest.NewRequest(req.Method, req.Path, body)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	m.api.ServeHTTP(w, r)
	respBody := bytes.TrimSpace(w.Body.Bytes())
	if !json.Valid(respBody) {
		respBody, _ = json.Marshal(string(respBody))
	}
	out := rpcResponse{ID: req.ID, Status: w.Code, Body: respBody}
	if req.Method == http.MethodGet && w.Code == http.StatusOK {
		sum := sha256.Sum256(respBody)
		out.ETag = hex.EncodeToString(sum[:12])
		if req.IfNoneMatch == out.ETag {
			out.Status, out.Body = http.StatusNotModified, json.RawMessage("null")
		}
	}
	resp, _ := json.Marshal(out)
	m.send(ch, pc, resp)
}

// Messages on a channel that agreed to "deflate" start with a flag byte: 0 = as is, 1 = raw DEFLATE
// (RFC 1951, what Apple's Compression framework calls zlib). Small messages aren't worth it.
const compressAbove = 512

func packMessage(plain []byte) []byte {
	if len(plain) > compressAbove {
		var b bytes.Buffer
		b.WriteByte(1)
		fw, _ := flate.NewWriter(&b, flate.BestSpeed)
		fw.Write(plain)
		fw.Close()
		if b.Len() < len(plain) {
			return b.Bytes()
		}
	}
	return append([]byte{0}, plain...)
}

func unpackMessage(msg []byte) ([]byte, error) {
	if len(msg) == 0 {
		return nil, errors.New("empty message")
	}
	switch msg[0] {
	case 0:
		return msg[1:], nil
	case 1:
		return io.ReadAll(io.LimitReader(flate.NewReader(bytes.NewReader(msg[1:])), 32<<20))
	}
	return nil, errors.New("unknown message encoding")
}
