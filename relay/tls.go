package main

import (
	stdtls "crypto/tls"
	"log"
	"net/http"

	llibtls "github.com/lesismal/llib/std/crypto/tls"
	"golang.org/x/crypto/acme"
	"golang.org/x/crypto/acme/autocert"
)

// On its own server the relay terminates TLS itself, with Let's Encrypt certificates from
// autocert: a proxy in front would hold its own buffers for every idle Mac. nbio uses llib's fork
// of crypto/tls, whose types mirror the standard ones, so autocert plugs in through a small
// conversion.

func autocertTLS(domains []string, cacheDir string) *llibtls.Config {
	m := &autocert.Manager{
		Prompt:     autocert.AcceptTOS,
		HostPolicy: autocert.HostWhitelist(domains...),
		Cache:      autocert.DirCache(cacheDir),
	}
	// Port 80: ACME http-01 challenges and a redirect to https for everything else.
	go func() {
		fallback := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, "https://"+r.Host+r.URL.RequestURI(), http.StatusMovedPermanently)
		})
		log.Fatal(http.ListenAndServe(":80", m.HTTPHandler(fallback)))
	}()

	return &llibtls.Config{
		MinVersion: llibtls.VersionTLS12,
		NextProtos: []string{"http/1.1", acme.ALPNProto},
		GetCertificate: func(h *llibtls.ClientHelloInfo) (*llibtls.Certificate, error) {
			std := &stdtls.ClientHelloInfo{
				CipherSuites:      h.CipherSuites,
				ServerName:        h.ServerName,
				SupportedPoints:   h.SupportedPoints,
				SupportedProtos:   h.SupportedProtos,
				SupportedVersions: h.SupportedVersions,
			}
			for _, c := range h.SupportedCurves {
				std.SupportedCurves = append(std.SupportedCurves, stdtls.CurveID(c))
			}
			for _, s := range h.SignatureSchemes {
				std.SignatureSchemes = append(std.SignatureSchemes, stdtls.SignatureScheme(s))
			}
			c, err := m.GetCertificate(std)
			if err != nil {
				return nil, err
			}
			return &llibtls.Certificate{Certificate: c.Certificate, PrivateKey: c.PrivateKey, Leaf: c.Leaf, OCSPStaple: c.OCSPStaple}, nil
		},
	}
}
