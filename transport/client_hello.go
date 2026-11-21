// Copyright (c) 2026 claude-desktop-fake contributors. MIT license.
package main

import (
	"encoding/binary"
	"io"
	"net/netip"
	"strings"

	tlsprotocol "github.com/xtls/xray-core/common/protocol/tls"
)

const maxClientHello = 32 * 1024

// Read observes the initial TLS records and checks the first STUN header.
// TLS records and the underlying reads can split the handshake independently.
type clientHelloReader struct {
	io.Reader
	onName      func(string)
	blockWebRTC bool
	blocked     bool
	prefix      [10]byte
	prefixLen   int
	header      [5]byte
	headerLen   int
	remaining   int
	hello       []byte
	done        bool
}

func (r *clientHelloReader) Read(p []byte) (int, error) {
	if r.blocked {
		return 0, errWebRTCBlocked
	}
	n, err := r.Reader.Read(p)
	if r.blockWebRTC && n > 0 && r.prefixLen < len(r.prefix) {
		r.prefixLen += copy(r.prefix[r.prefixLen:], p[:n])
		if stunPrefix(r.prefix[:r.prefixLen]) {
			r.stop()
			r.blocked = true
			return 0, errWebRTCBlocked
		}
	}
	if !r.done && n > 0 {
		r.inspect(p[:n])
	}
	if !r.done && err != nil {
		r.stop()
	}
	if r.blocked {
		return 0, errWebRTCBlocked
	}
	return n, err
}

func (r *clientHelloReader) stop() {
	clear(r.hello)
	r.hello = nil
	r.done = true
}

func (r *clientHelloReader) inspect(data []byte) {
	for len(data) > 0 {
		if r.remaining == 0 {
			count := copy(r.header[r.headerLen:], data)
			r.headerLen += count
			data = data[count:]
			if r.headerLen < len(r.header) {
				return
			}
			r.headerLen = 0
			r.remaining = int(binary.BigEndian.Uint16(r.header[3:]))
			if r.header[0] != 22 || r.header[1] != 3 || r.remaining == 0 || r.remaining > 16384 {
				r.stop()
				return
			}
		}
		count := min(len(data), r.remaining, maxClientHello-len(r.hello))
		r.hello = append(r.hello, data[:count]...)
		r.remaining -= count
		data = data[count:]
		if len(r.hello) < 4 {
			continue
		}
		size := 4 + (int(r.hello[1])<<16 | int(r.hello[2])<<8 | int(r.hello[3]))
		if r.hello[0] != 1 || size < 42 || size > maxClientHello {
			r.stop()
			return
		}
		if len(r.hello) >= size {
			var hello tlsprotocol.SniffHeader
			if tlsprotocol.ReadClientHello(r.hello[:size], &hello) == nil {
				if name := dnsServerName(hello.Domain()); name != "" {
					r.onName(name)
				}
			}
			r.blocked = r.blockWebRTC && stunALPN(r.hello[:size])
			r.stop()
			return
		}
	}
}

func dnsServerName(name string) string {
	if name == "" || len(name) > 253 {
		return ""
	}
	if _, err := netip.ParseAddr(name); err == nil {
		return ""
	}
	for label := range strings.SplitSeq(name, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return ""
		}
		for _, c := range label {
			switch {
			case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '-':
			default:
				return ""
			}
		}
	}
	return strings.ToLower(name)
}
