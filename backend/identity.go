package main

import (
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// The Mac's keys and the phones paired with it.
//
//   - Ed25519 signs the relay's challenge, so nobody else can take this Mac's ID.
//   - X25519 is the Mac's static key in the end-to-end handshake with paired phones.
//   - The Mac ID is the start of SHA-256 of the Ed25519 public key.

type identity struct {
	SignKey ed25519.PrivateKey `json:"sign_key"`
	DHKey   []byte             `json:"dh_key"` // X25519 private key
}

type pairedDevice struct {
	ID       string    `json:"id"` // hex of the start of SHA-256 of the phone's public key
	Name     string    `json:"name"`
	Key      []byte    `json:"key"` // phone's X25519 public key
	AddedAt  time.Time `json:"added_at"`
	LastSeen time.Time `json:"last_seen,omitempty"`
}

type pendingPairing struct {
	Secret    []byte    `json:"secret"`
	ExpiresAt time.Time `json:"expires_at"`
}

var idMu sync.Mutex

func identityPath() string { return filepath.Join(stateDir, "identity.json") }
func devicesPath() string  { return filepath.Join(stateDir, "devices.json") }
func pairingPath() string  { return filepath.Join(stateDir, "pairing.json") }

// loadIdentity reads the Mac's keys, creating them on first use.
func loadIdentity() (*identity, error) {
	idMu.Lock()
	defer idMu.Unlock()
	var id identity
	if data, err := os.ReadFile(identityPath()); err == nil {
		if err := json.Unmarshal(data, &id); err == nil && len(id.SignKey) == ed25519.PrivateKeySize && len(id.DHKey) == 32 {
			return &id, nil
		}
	}
	_, sk, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	dh, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	id = identity{SignKey: sk, DHKey: dh.Bytes()}
	data, _ := json.MarshalIndent(id, "", "  ")
	os.MkdirAll(stateDir, 0o755)
	if err := os.WriteFile(identityPath(), data, 0o600); err != nil {
		return nil, err
	}
	return &id, nil
}

func (id *identity) macID() string {
	sum := sha256.Sum256(id.SignKey.Public().(ed25519.PublicKey))
	return hex.EncodeToString(sum[:16])
}

func (id *identity) dhPrivate() *ecdh.PrivateKey {
	k, _ := ecdh.X25519().NewPrivateKey(id.DHKey)
	return k
}

func deviceID(pub []byte) string {
	sum := sha256.Sum256(pub)
	return hex.EncodeToString(sum[:8])
}

func loadDevices() []pairedDevice {
	var ds []pairedDevice
	if data, err := os.ReadFile(devicesPath()); err == nil {
		json.Unmarshal(data, &ds)
	}
	return ds
}

func saveDevices(ds []pairedDevice) error {
	sort.Slice(ds, func(i, j int) bool { return ds[i].AddedAt.Before(ds[j].AddedAt) })
	data, _ := json.MarshalIndent(ds, "", "  ")
	tmp := devicesPath() + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, devicesPath())
}

func findDevice(pub []byte) *pairedDevice {
	for _, d := range loadDevices() {
		if hmac.Equal(d.Key, pub) {
			d := d
			return &d
		}
	}
	return nil
}

func addDevice(name string, pub []byte) (pairedDevice, error) {
	idMu.Lock()
	defer idMu.Unlock()
	ds := loadDevices()
	for i, d := range ds {
		if hmac.Equal(d.Key, pub) {
			ds[i].Name = name
			return ds[i], saveDevices(ds)
		}
	}
	d := pairedDevice{ID: deviceID(pub), Name: name, Key: pub, AddedAt: time.Now().Truncate(time.Second)}
	return d, saveDevices(append(ds, d))
}

func touchDevice(pub []byte) {
	idMu.Lock()
	defer idMu.Unlock()
	ds := loadDevices()
	for i := range ds {
		if hmac.Equal(ds[i].Key, pub) && time.Since(ds[i].LastSeen) > time.Minute {
			ds[i].LastSeen = time.Now().Truncate(time.Second)
			saveDevices(ds)
		}
	}
}

func revokeDevice(nameOrID string) (pairedDevice, error) {
	idMu.Lock()
	defer idMu.Unlock()
	ds := loadDevices()
	for i, d := range ds {
		if d.ID == nameOrID || d.Name == nameOrID {
			return d, saveDevices(append(ds[:i], ds[i+1:]...))
		}
	}
	return pairedDevice{}, fmt.Errorf("no paired device %q (see `hangar devices`)", nameOrID)
}

// newPairing makes a one-time secret, valid for 10 minutes, and the link the phone opens.
func newPairing() (string, error) {
	id, err := loadIdentity()
	if err != nil {
		return "", err
	}
	secret := make([]byte, 16)
	rand.Read(secret)
	p := pendingPairing{Secret: secret, ExpiresAt: time.Now().Add(10 * time.Minute)}
	data, _ := json.Marshal(p)
	if err := os.WriteFile(pairingPath(), data, 0o600); err != nil {
		return "", err
	}
	b64 := base64.RawURLEncoding
	q := url.Values{}
	q.Set("relay", conf().Relay)
	q.Set("mac", id.macID())
	q.Set("key", b64.EncodeToString(id.dhPrivate().PublicKey().Bytes()))
	q.Set("secret", b64.EncodeToString(secret))
	q.Set("name", conf().MacName)
	return "hangar://pair?" + q.Encode(), nil
}

// checkPairing verifies a phone's proof against the pending secret and uses the secret up.
func checkPairing(phoneKey, phoneEph, proof []byte) bool {
	idMu.Lock()
	defer idMu.Unlock()
	data, err := os.ReadFile(pairingPath())
	if err != nil {
		return false
	}
	var p pendingPairing
	if json.Unmarshal(data, &p) != nil || time.Now().After(p.ExpiresAt) {
		return false
	}
	m := hmac.New(sha256.New, p.Secret)
	m.Write([]byte("hangar-pair-v1"))
	m.Write(phoneKey)
	m.Write(phoneEph)
	if !hmac.Equal(m.Sum(nil), proof) {
		return false
	}
	os.Remove(pairingPath())
	return true
}
