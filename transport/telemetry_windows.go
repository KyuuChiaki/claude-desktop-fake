// Copyright (c) 2026 claude-desktop-fake contributors. MIT license.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"claude-desktop-fake/network-transport/internal/connectionlog"
	"claude-desktop-fake/network-transport/internal/localpipe"
)

var connections connectionlog.Log

func serveConnections(ctx context.Context) {
	identity, err := localpipe.ProcessIdentity(uint32(os.Getpid()))
	if err != nil {
		return
	}
	pipe, err := localpipe.Listen(localpipe.Name(identity.Logon, fmt.Sprintf("connections.%d", identity.PID)), identity)
	if err != nil {
		return
	}
	pipe.Serve(ctx, func(data []byte, _ localpipe.Identity) []byte {
		var req struct {
			Version  int     `json:"version"`
			Since    uint64  `json:"since"`
			DNSSince *uint64 `json:"dnsSince"`
		}
		if json.Unmarshal(data, &req) != nil || req.Version != connectionlog.Version {
			return nil
		}
		snapshot := connections.Snapshot(identity.PID, identity.Created, req.Since, realNow())
		if req.DNSSince != nil {
			snapshot.DNS = connections.DNS(*req.DNSSince)
		}
		result, _ := json.Marshal(snapshot)
		if len(result) > localpipe.MaxFrame {
			// Keep the original connection data within the fixed pipe limit.
			for i := range snapshot.Active {
				snapshot.Active[i].ServerName = ""
			}
			for i := range snapshot.Closed {
				snapshot.Closed[i].ServerName = ""
			}
			snapshot.Overflow = true
			result, _ = json.Marshal(snapshot)
		}
		if len(result) > localpipe.MaxFrame && snapshot.DNS != nil {
			snapshot.DNS.Queries = nil
			snapshot.DNS.Lost = true
			result, _ = json.Marshal(snapshot)
		}
		return result
	})
}
