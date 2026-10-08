package main

import (
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"io"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
)

// End-to-end encryption between a paired phone and this Mac; the relay only sees ciphertext.
//
// Handshake (plaintext JSON, phone first):
//
//	phone → mac  {"t":"hello", "key": phone static, "eph": phone ephemeral}
//	             or {"t":"pair", ..., "name", "proof": HMAC(secret, "hangar-pair-v1"‖key‖eph)}
//	mac → phone  {"t":"welcome", "eph": mac ephemeral}   or {"t":"error", "error"}
//
// Keys: HKDF-SHA256 over DH(mac static, phone static) ‖ DH(mac eph, phone eph) ‖ DH(mac static,
// phone eph), salt SHA-256("hangar-v1"‖phone key‖phone eph‖mac eph), info "phone→mac" and
// "mac→phone". The static-static part authenticates both sides, the ephemeral parts give
// forward secrecy. Every message after that is ChaCha20-Poly1305, nonce = 4 zero bytes ‖ 64-bit
// big-endian counter (counters must go up, so replayed frames are rejected), sent as
// nonce ‖ ciphertext ‖ tag (CryptoKit's ChaChaPoly.SealedBox.combined).

type secureChannel struct {
	send, recv cipher.AEAD
	sendN      uint64
	recvN      uint64 // next acceptable counter
}

func deriveChannel(macStatic *ecdh.PrivateKey, macEph *ecdh.PrivateKey, phoneKey, phoneEph []byte) (*secureChannel, error) {
	pk, err := ecdh.X25519().NewPublicKey(phoneKey)
	if err != nil {
		return nil, err
	}
	pe, err := ecdh.X25519().NewPublicKey(phoneEph)
	if err != nil {
		return nil, err
	}
	ss, err := macStatic.ECDH(pk)
	if err != nil {
		return nil, err
	}
	ee, err := macEph.ECDH(pe)
	if err != nil {
		return nil, err
	}
	se, err := macStatic.ECDH(pe)
	if err != nil {
		return nil, err
	}
	ikm := append(append(ss, ee...), se...)
	h := sha256.New()
	h.Write([]byte("hangar-v1"))
	h.Write(phoneKey)
	h.Write(phoneEph)
	h.Write(macEph.PublicKey().Bytes())
	salt := h.Sum(nil)

	key := func(info string) (cipher.AEAD, error) {
		k := make([]byte, chacha20poly1305.KeySize)
		if _, err := io.ReadFull(hkdf.New(sha256.New, ikm, salt, []byte(info)), k); err != nil {
			return nil, err
		}
		return chacha20poly1305.New(k)
	}
	recv, err := key("phone→mac")
	if err != nil {
		return nil, err
	}
	send, err := key("mac→phone")
	if err != nil {
		return nil, err
	}
	return &secureChannel{send: send, recv: recv}, nil
}

func (c *secureChannel) seal(plain []byte) []byte {
	nonce := make([]byte, 12)
	binary.BigEndian.PutUint64(nonce[4:], c.sendN)
	c.sendN++
	return c.send.Seal(nonce, nonce, plain, nil)
}

var errReplay = errors.New("frame out of order")

func (c *secureChannel) open(frame []byte) ([]byte, error) {
	if len(frame) < 12+chacha20poly1305.Overhead {
		return nil, errors.New("short frame")
	}
	n := binary.BigEndian.Uint64(frame[4:12])
	if n < c.recvN {
		return nil, errReplay
	}
	plain, err := c.recv.Open(nil, frame[:12], frame[12:], nil)
	if err != nil {
		return nil, err
	}
	c.recvN = n + 1
	return plain, nil
}

func newEphemeral() (*ecdh.PrivateKey, error) { return ecdh.X25519().GenerateKey(rand.Reader) }
