package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"os"

	"golang.org/x/crypto/cryptobyte"
)

var errWebRTCBlocked = errors.New("WebRTC transport blocked")

func webRTCDisabled(path string) bool {
	file, err := os.Open(path)
	if err != nil {
		return true
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 1024 {
		return true
	}
	wire, err := io.ReadAll(io.LimitReader(file, 1025))
	var cfg struct {
		SchemaVersion  int   `json:"schemaVersion"`
		WebRTCDisabled *bool `json:"webRTCDisabled"`
	}
	if err != nil || len(wire) > 1024 || json.Unmarshal(wire, &cfg) != nil ||
		cfg.SchemaVersion != 1 || cfg.WebRTCDisabled == nil {
		return true
	}
	return *cfg.WebRTCDisabled
}

func blockedWebRTCPort(port uint16, disabled bool) bool {
	return disabled && (port == 3478 || port == 5349)
}

func stunHeader(data []byte) bool {
	return len(data) >= 8 && data[0]&0xc0 == 0 && data[3]&3 == 0 &&
		binary.BigEndian.Uint32(data[4:8]) == 0x2112a442
}

func stunPrefix(data []byte) bool {
	if stunHeader(data) {
		return true
	}
	// ICE-TCP may prefix the STUN message with its two-byte framing length.
	return len(data) >= 10 && stunHeader(data[2:]) &&
		int(binary.BigEndian.Uint16(data[:2])) == 20+int(binary.BigEndian.Uint16(data[4:6]))
}

func stunALPN(hello []byte) bool {
	body := cryptobyte.String(hello)
	var ignored, extensions cryptobyte.String
	if !body.Skip(38) || !body.ReadUint8LengthPrefixed(&ignored) ||
		!body.ReadUint16LengthPrefixed(&ignored) || !body.ReadUint8LengthPrefixed(&ignored) ||
		!body.ReadUint16LengthPrefixed(&extensions) || !body.Empty() {
		return false
	}
	for !extensions.Empty() {
		var extension uint16
		var values cryptobyte.String
		if !extensions.ReadUint16(&extension) || !extensions.ReadUint16LengthPrefixed(&values) {
			return false
		}
		if extension != 16 {
			continue
		}
		var protocols cryptobyte.String
		if !values.ReadUint16LengthPrefixed(&protocols) || !values.Empty() {
			return false
		}
		for !protocols.Empty() {
			var p cryptobyte.String
			if !protocols.ReadUint8LengthPrefixed(&p) {
				return false
			}
			switch string(p) {
			case "stun.turn", "stun.nat-discovery":
				return true
			}
		}
	}
	return false
}
