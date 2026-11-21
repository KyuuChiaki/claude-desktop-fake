package main

import (
	"bytes"
	"crypto/tls"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"testing/iotest"
	"time"
)

func recordClientHello(t *testing.T, name string, protocols ...string) []byte {
	t.Helper()
	local, peer := net.Pipe()
	defer local.Close()
	defer peer.Close()
	if err := peer.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	client := tls.Client(local, &tls.Config{ServerName: name, NextProtos: protocols})
	go func() { _ = client.Handshake() }()
	var header [5]byte
	if _, err := io.ReadFull(peer, header[:]); err != nil {
		t.Fatal(err)
	}
	payload := make([]byte, int(binary.BigEndian.Uint16(header[3:])))
	if _, err := io.ReadFull(peer, payload); err != nil {
		t.Fatal(err)
	}
	return append(header[:], payload...)
}

func TestConnectionServerName(t *testing.T) {
	const host = "service.example"
	hello := recordClientHello(t, host)
	split := func(payload []byte) []byte {
		header := binary.BigEndian.AppendUint16([]byte{22, 3, 3}, uint16(len(payload)))
		return append(header, payload...)
	}
	fragments := append(split(hello[5:7]), split(hello[7:])...)
	for _, tt := range []struct {
		label string
		data  []byte
		want  string
	}{
		{"client hello", hello, host},
		{"multiple TLS records", fragments, host},
		{"truncated handshake", hello[:len(hello)/2], ""},
		{"invalid domain", recordClientHello(t, "-invalid.example"), ""},
		{"IP literal", recordClientHello(t, "203.0.113.5"), ""},
		{"plaintext", []byte("GET / HTTP/1.1\r\nHost: service.example\r\n\r\n"), ""},
	} {
		t.Run(tt.label, func(t *testing.T) {
			var name string
			source := iotest.OneByteReader(bytes.NewReader(tt.data))
			r := &clientHelloReader{Reader: source, onName: func(observed string) { name = observed }}
			got, err := io.ReadAll(r)
			if err != nil || !bytes.Equal(got, tt.data) || name != tt.want {
				t.Fatalf("observed name %q, want %q, bytes unchanged %t, read error %v",
					name, tt.want, bytes.Equal(got, tt.data), err)
			}
		})
	}
}
