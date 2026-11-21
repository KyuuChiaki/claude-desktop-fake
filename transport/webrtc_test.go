package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
	"testing/iotest"
)

func TestWebRTCPolicy(t *testing.T) {
	path := filepath.Join(t.TempDir(), "protection.json")
	if !webRTCDisabled(path) {
		t.Fatal("missing configuration must disable WebRTC")
	}
	for _, tc := range []struct {
		wire     string
		disabled bool
	}{
		{`{"schemaVersion":1,"webRTCDisabled":true}`, true},
		{`{"schemaVersion":1,"webRTCDisabled":false}`, false},
		{`{"schemaVersion":1,"webRTCDisabled":"false"}`, true},
		{`{"schemaVersion":2,"webRTCDisabled":false}`, true},
	} {
		if err := os.WriteFile(path, []byte(tc.wire), 0600); err != nil {
			t.Fatal(err)
		}
		disabled := webRTCDisabled(path)
		if disabled != tc.disabled || blockedWebRTCPort(3478, disabled) != disabled ||
			blockedWebRTCPort(5349, disabled) != disabled || blockedWebRTCPort(443, disabled) {
			t.Fatalf("unexpected policy for %s", tc.wire)
		}
	}
}

func TestIdentifiableWebRTCStreams(t *testing.T) {
	stun := make([]byte, 20)
	copy(stun, []byte{0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42})
	framed := append([]byte{0, 20}, stun...)
	turn := recordClientHello(t, "relay.example", "stun.turn")
	https := recordClientHello(t, "service.example", "h2", "http/1.1")
	for _, tc := range []struct {
		name  string
		data  []byte
		isRTC bool
	}{
		{"stun", stun, true},
		{"ice-tcp", framed, true},
		{"turn-tls", turn, true},
		{"https", https, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, disabled := range []bool{true, false} {
				reader := &clientHelloReader{
					Reader:      iotest.OneByteReader(bytes.NewReader(tc.data)),
					blockWebRTC: disabled, onName: func(string) {},
				}
				got, err := io.ReadAll(reader)
				if disabled && tc.isRTC {
					if !errors.Is(err, errWebRTCBlocked) || len(got) >= len(tc.data) {
						t.Fatalf("complete RTC request escaped the guard: %v", err)
					}
				} else if err != nil || !bytes.Equal(got, tc.data) {
					t.Fatalf("unblocked stream changed: %v", err)
				}
			}
		})
	}
}
