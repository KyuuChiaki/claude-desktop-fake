// Copyright (c) 2026 claude-desktop-fake contributors. MIT license.
package main

/*
#include <stdint.h>
*/
import "C"

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"time"
	"unsafe"
)

// CdfTransportCheck uses the same restricted transport in an isolated process.
// Its destination and response shape are fixed. No caller-provided URL is used.
//
//export CdfTransportCheck
func CdfTransportCheck(output *C.char, capacity C.uint32_t) (used C.uint32_t) {
	defer func() {
		if recover() != nil {
			used = 0
		}
	}()
	if output == nil || capacity < 256 || capacity > 16384 {
		return 0
	}
	start := time.Now()
	result := struct {
		OK         bool   `json:"ok"`
		Stage      string `json:"stage"`
		IP         string `json:"ip,omitempty"`
		DurationMS int64  `json:"durationMs"`
	}{}
	const host = "api.ipify.org"
	roots, err := privateRoots()
	if err == nil {
		transport := &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: roots, ServerName: host, MinVersion: tls.VersionTLS12, Time: realNow},
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				if network != "tcp" || addr != host+":443" {
					return nil, errors.New("unexpected health check destination")
				}
				return openTunnel(ctx, host, 443)
			},
		}
		defer transport.CloseIdleConnections()
		client := http.Client{Transport: transport, Timeout: 18 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect refused") }}
		response, err := client.Get("https://" + host + "/?format=json")
		switch {
		case err != nil:
			result.Stage = "transport-or-tls"
		case response.StatusCode != http.StatusOK:
			response.Body.Close()
			result.Stage = "http"
		default:
			body, err := io.ReadAll(io.LimitReader(response.Body, 1025))
			response.Body.Close()
			var echo struct{ IP string }
			if err == nil && len(body) <= 1024 && json.Unmarshal(body, &echo) == nil && net.ParseIP(echo.IP) != nil {
				result.OK, result.Stage, result.IP = true, "complete", echo.IP
			} else {
				result.Stage = "response"
			}
		}
	} else {
		result.Stage = "certificates"
	}
	result.DurationMS = time.Since(start).Milliseconds()
	data, err := json.Marshal(result)
	if err != nil || len(data) > int(capacity) {
		return 0
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(output)), int(capacity)), data)
	return C.uint32_t(len(data))
}
