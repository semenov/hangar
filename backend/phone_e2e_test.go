package main

import (
	"context"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
)

// A phone, for end-to-end tests against a running relay and `hangar serve`:
//
//	HANGAR_E2E_LINK='hangar://pair?...' go test -run TestPhoneE2E -v
//
// It pairs, calls /api/version and /api/overview through the encrypted channel, reconnects
// with "hello", and checks that an unpaired phone is turned away.
func TestPhoneE2E(t *testing.T) {
	link := os.Getenv("HANGAR_E2E_LINK")
	if link == "" {
		t.Skip("HANGAR_E2E_LINK not set")
	}
	u, err := url.Parse(link)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	b64 := base64.RawURLEncoding
	macKey, _ := b64.DecodeString(q.Get("key"))
	secret, _ := b64.DecodeString(q.Get("secret"))
	phone, _ := ecdh.X25519().GenerateKey(rand.Reader)

	// Pair, then call the API.
	conn, recv, send := phoneConnect(t, q.Get("relay"), q.Get("mac"), macKey, phone, secret)
	send(map[string]any{"id": 1, "method": "GET", "path": "/api/version"})
	t.Logf("version: %s", recv())
	send(map[string]any{"id": 2, "method": "GET", "path": "/api/overview"})
	var resp struct {
		ID     int
		Status int
		Body   struct{ Sessions []Session }
	}
	json.Unmarshal([]byte(recv()), &resp)
	if resp.ID != 2 || resp.Status != 200 {
		t.Fatalf("overview: %+v", resp)
	}
	t.Logf("overview: %d sessions", len(resp.Body.Sessions))
	conn.Close(websocket.StatusNormalClosure, "")

	// Compressed channel: overview comes deflated, and a repeat with its ETag answers 304.
	conn, recv, send = phoneConnectOpts(t, q.Get("relay"), q.Get("mac"), macKey, phone, nil, true)
	send(map[string]any{"id": 10, "method": "GET", "path": "/api/overview"})
	var full struct {
		Status int
		ETag   string
	}
	json.Unmarshal([]byte(recv()), &full)
	send(map[string]any{"id": 11, "method": "GET", "path": "/api/overview", "if_none_match": full.ETag})
	var again struct{ Status int }
	json.Unmarshal([]byte(recv()), &again)
	if full.Status != 200 || full.ETag == "" || again.Status != 304 {
		t.Fatalf("etag: first %d %q, then %d", full.Status, full.ETag, again.Status)
	}
	t.Logf("deflate + etag: 200 then 304")
	conn.Close(websocket.StatusNormalClosure, "")

	// Reconnect as a paired phone.
	conn, recv, send = phoneConnect(t, q.Get("relay"), q.Get("mac"), macKey, phone, nil)
	send(map[string]any{"id": 3, "method": "GET", "path": "/api/version"})
	if r := recv(); !strings.Contains(r, `"id":3`) {
		t.Fatalf("after reconnect: %s", r)
	}
	conn.Close(websocket.StatusNormalClosure, "")

	// A stranger with the same Mac ID but no pairing is turned away.
	stranger, _ := ecdh.X25519().GenerateKey(rand.Reader)
	c, _, err := websocket.Dial(context.Background(), q.Get("relay")+"/v1/phone?id="+q.Get("mac"), nil)
	if err != nil {
		t.Fatal(err)
	}
	eph, _ := ecdh.X25519().GenerateKey(rand.Reader)
	hello, _ := json.Marshal(map[string]any{"t": "hello", "key": stranger.PublicKey().Bytes(), "eph": eph.PublicKey().Bytes()})
	c.Write(context.Background(), websocket.MessageBinary, hello)
	_, msg, _ := c.Read(context.Background())
	if !strings.Contains(string(msg), "not paired") {
		t.Fatalf("stranger got: %s", msg)
	}
	t.Logf("stranger: %s", msg)
}

func phoneConnect(t *testing.T, relay, macID string, macKey []byte, phone *ecdh.PrivateKey, secret []byte) (*websocket.Conn, func() string, func(any)) {
	return phoneConnectOpts(t, relay, macID, macKey, phone, secret, false)
}

func phoneConnectOpts(t *testing.T, relay, macID string, macKey []byte, phone *ecdh.PrivateKey, secret []byte, deflate bool) (*websocket.Conn, func() string, func(any)) {
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, relay+"/v1/phone?id="+macID, nil)
	if err != nil {
		t.Fatal(err)
	}
	eph, _ := ecdh.X25519().GenerateKey(rand.Reader)
	msg := map[string]any{"t": "hello", "key": phone.PublicKey().Bytes(), "eph": eph.PublicKey().Bytes()}
	if deflate {
		msg["compress"] = []string{"deflate"}
	}
	if secret != nil {
		m := hmac.New(sha256.New, secret)
		m.Write([]byte("hangar-pair-v1"))
		m.Write(phone.PublicKey().Bytes())
		m.Write(eph.PublicKey().Bytes())
		msg["t"], msg["name"], msg["proof"] = "pair", "e2e test phone", m.Sum(nil)
	}
	data, _ := json.Marshal(msg)
	if err := c.Write(ctx, websocket.MessageBinary, data); err != nil {
		t.Fatal(err)
	}
	_, data, err = c.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var w struct {
		T, Error string
		Eph      []byte
	}
	json.Unmarshal(data, &w)
	if w.T != "welcome" {
		t.Fatalf("handshake: %s", data)
	}

	// Same derivation as deriveChannel, from the phone's side.
	mk, _ := ecdh.X25519().NewPublicKey(macKey)
	me, _ := ecdh.X25519().NewPublicKey(w.Eph)
	ss, _ := phone.ECDH(mk)
	ee, _ := eph.ECDH(me)
	se, _ := eph.ECDH(mk)
	ikm := append(append(ss, ee...), se...)
	h := sha256.New()
	h.Write([]byte("hangar-v1"))
	h.Write(phone.PublicKey().Bytes())
	h.Write(eph.PublicKey().Bytes())
	h.Write(w.Eph)
	salt := h.Sum(nil)
	key := func(info string) []byte {
		k := make([]byte, 32)
		io.ReadFull(hkdf.New(sha256.New, ikm, salt, []byte(info)), k)
		return k
	}
	sendAEAD, _ := chacha20poly1305.New(key("phone→mac"))
	recvAEAD, _ := chacha20poly1305.New(key("mac→phone"))
	var n uint64
	var last []byte
	send := func(v any) {
		plain, _ := json.Marshal(v)
		if deflate {
			plain = append([]byte{0}, plain...)
		}
		nonce := make([]byte, 12)
		binary.BigEndian.PutUint64(nonce[4:], n)
		n++
		last = sendAEAD.Seal(nonce, nonce, plain, nil)
		c.Write(ctx, websocket.MessageBinary, last)
	}
	recv := func() string {
		rctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
		_, frame, err := c.Read(rctx)
		if err != nil {
			t.Fatal(err)
		}
		plain, err := recvAEAD.Open(nil, frame[:12], frame[12:], nil)
		if err != nil {
			t.Fatalf("decrypt: %v (%s)", err, frame)
		}
		if deflate {
			if plain, err = unpackMessage(plain); err != nil {
				t.Fatal(err)
			}
		}
		return string(plain)
	}
	return c, recv, send
}
