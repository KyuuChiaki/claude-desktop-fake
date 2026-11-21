// Copyright (c) 2026 claude-desktop-fake contributors. MIT license.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"sync"
	"time"

	"claude-desktop-fake/network-transport/internal/connectionlog"
	"claude-desktop-fake/network-transport/internal/localpipe"
)

const closedLimit = 2000

type processRow struct {
	PID            uint32 `json:"pid"`
	Created        string `json:"created"`
	Role           string `json:"role"`
	Name           string `json:"name"`
	NetworkLoaded  bool   `json:"networkLoaded"`
	TransportReady *bool  `json:"transportReady"`
}

type observedRow struct {
	connectionlog.Record
	Key   string `json:"key"`
	PID   uint32 `json:"pid"`
	Name  string `json:"name"`
	Role  string `json:"role"`
	Stale bool   `json:"stale"`
}

type observedDNS struct {
	connectionlog.DNSRecord
	PID     uint32 `json:"pid"`
	Process string `json:"process"`
	Role    string `json:"role"`
}

type processLog struct {
	identity     localpipe.Identity
	role         string
	name         string
	serverNames  bool
	dnsSupported bool
	dnsCursor    uint64
	cursor       uint64
	active       []observedRow
	last         time.Time
	stale        bool
}

type history struct {
	mu         sync.Mutex
	cutoff     time.Time
	list       map[string]*processLog
	closed     []observedRow
	dnsCutoff  time.Time
	dnsQueries []observedDNS
	dnsGaps    bool
	observed   time.Time
	gaps       bool
	waiting    int
}

func newHistory(now time.Time) *history {
	return &history{cutoff: now.UTC(), dnsCutoff: now.UTC(), list: make(map[string]*processLog)}
}

func procKey(id localpipe.Identity) string { return fmt.Sprintf("%d/%d", id.PID, id.Created) }

func withProcess(rec connectionlog.Record, p *processLog) observedRow {
	return observedRow{Record: rec, PID: p.identity.PID, Name: p.name, Role: p.role,
		Key: fmt.Sprintf("%s/%d", procKey(p.identity), rec.ID)}
}

func (h *history) clear(now time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = nil
	h.cutoff = now.UTC()
}

func (h *history) clearDNS(now time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.dnsQueries = nil
	h.dnsCutoff = now.UTC()
	h.dnsGaps = false
}

func (h *history) recordDNS(p *processLog, s *connectionlog.DNSSnapshot) {
	p.dnsSupported = s != nil && len(s.Queries) <= connectionlog.DNSLimit
	if s == nil || s.Cursor < p.dnsCursor || len(s.Queries) > connectionlog.DNSLimit {
		return
	}
	cursor := p.dnsCursor
	for _, q := range s.Queries {
		if q.Cursor > cursor && q.Cursor <= s.Cursor && !q.Finished.IsZero() &&
			!q.Finished.Before(h.dnsCutoff) && len(q.Name) > 0 && len(q.Name) <= 255 &&
			len(q.Type) <= 16 && len(q.Status) <= 32 && len(q.Addresses) <= 12 {
			h.dnsQueries = append(h.dnsQueries, observedDNS{DNSRecord: q, PID: p.identity.PID, Process: p.name, Role: p.role})
			cursor = q.Cursor
		}
	}
	p.dnsCursor = s.Cursor
	h.dnsGaps = h.dnsGaps || s.Lost
	if len(s.Queries) > 0 {
		sort.SliceStable(h.dnsQueries, func(i, j int) bool { return h.dnsQueries[i].Finished.After(h.dnsQueries[j].Finished) })
		if len(h.dnsQueries) > closedLimit {
			clear(h.dnsQueries[closedLimit:])
			h.dnsQueries = h.dnsQueries[:closedLimit]
		}
	}
}

func (h *history) appendClosed(r observedRow) {
	if !r.Ended.Before(h.cutoff) {
		h.closed = append(h.closed, r)
	}
}

func (h *history) trim() {
	sort.SliceStable(h.closed, func(i, j int) bool { return h.closed[i].Ended.After(h.closed[j].Ended) })
	if len(h.closed) > closedLimit {
		clear(h.closed[closedLimit:])
		h.closed = h.closed[:closedLimit]
	}
}

func (h *history) record(id localpipe.Identity, target processRow, s connectionlog.Snapshot, now time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	key := procKey(id)
	p := h.list[key]
	if p == nil {
		p = &processLog{identity: id, role: target.Role, name: target.Name}
		h.list[key] = p
	}
	if s.Cursor < p.cursor {
		p.stale = true
		return
	}
	for _, rec := range s.Closed {
		if rec.Cursor > p.cursor && rec.Cursor <= s.Cursor && rec.ID != 0 && !rec.Ended.IsZero() {
			h.appendClosed(withProcess(rec, p))
		}
	}
	p.cursor = s.Cursor
	p.serverNames = s.ServerNames
	h.recordDNS(p, s.DNS)
	p.active = make([]observedRow, 0, len(s.Active))
	for _, rec := range s.Active {
		if rec.ID != 0 && (rec.State == "active" || rec.State == "connecting") {
			p.active = append(p.active, withProcess(rec, p))
		}
	}
	p.last, p.stale = now, false
	h.observed = now
	h.gaps = h.gaps || s.Lost || s.Overflow
	h.trim()
}

func (h *history) finishPoll(observed map[string]bool, waiting int, now time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.waiting = waiting
	for key, p := range h.list {
		if observed[key] {
			continue
		}
		if !processExited(p.identity) {
			p.stale = true
			continue
		}
		for _, row := range p.active {
			row.State, row.Ended, row.Reason = "closed", now.UTC(), "process-exit"
			row.DurationMS = max(0, now.Sub(row.Started).Milliseconds())
			h.appendClosed(row)
		}
		delete(h.list, key)
	}
	h.trim()
}

func (h *history) view() any {
	h.mu.Lock()
	defer h.mu.Unlock()
	active := []observedRow{}
	nameSources := 0
	dnsSources := 0
	for _, p := range h.list {
		if p.serverNames {
			nameSources++
		}
		if p.dnsSupported {
			dnsSources++
		}
		for _, row := range p.active {
			row.Stale = p.stale
			active = append(active, row)
		}
	}
	sort.SliceStable(active, func(i, j int) bool { return active[i].Started.After(active[j].Started) })
	return struct {
		Active      []observedRow `json:"active"`
		Closed      []observedRow `json:"closed"`
		Updated     time.Time     `json:"updated"`
		Sources     int           `json:"sources"`
		NameSources int           `json:"nameSources"`
		DNS         []observedDNS `json:"dns"`
		DNSSources  int           `json:"dnsSources"`
		DNSGaps     bool          `json:"dnsGaps"`
		Waiting     int           `json:"waiting"`
		Gaps        bool          `json:"gaps"`
	}{active, append([]observedRow{}, h.closed...), h.observed, len(h.list), nameSources,
		append([]observedDNS{}, h.dnsQueries...), dnsSources, h.dnsGaps, h.waiting, h.gaps}
}

func (d *dashboard) pollConnections(owner localpipe.Identity) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-ticker.C:
		}
		d.mu.Lock()
		raw := d.status
		d.mu.Unlock()
		var status struct {
			Processes []processRow `json:"processes"`
		}
		_ = json.Unmarshal(raw, &status)
		d.history.poll(d.ctx, owner, status.Processes)
	}
}

func (h *history) poll(ctx context.Context, owner localpipe.Identity, targets []processRow) {
	now := time.Now()
	observed := make(map[string]bool)
	waiting := 0
	for _, p := range targets {
		// Older installed providers may lack a matching diagnostic map.
		// Discover their pipe using the same verified process identity.
		if !p.NetworkLoaded || (p.TransportReady != nil && !*p.TransportReady) {
			continue
		}
		id, err := localpipe.ProcessIdentity(p.PID)
		if err != nil || !localpipe.SameLogon(owner, id) || p.Created != fmt.Sprint(id.Created) {
			waiting++
			continue
		}
		key := procKey(id)
		h.mu.Lock()
		var since, dnsSince uint64
		if old := h.list[key]; old != nil {
			since, dnsSince = old.cursor, old.dnsCursor
		}
		h.mu.Unlock()
		name := localpipe.Name(owner.Logon, fmt.Sprintf("connections.%d", id.PID))
		probe, cancel := context.WithTimeout(ctx, 350*time.Millisecond)
		response, err := localpipe.Exchange(probe, name, id, fmt.Appendf(nil, `{"version":1,"since":%d,"dnsSince":%d}`, since, dnsSince))
		cancel()
		var snap connectionlog.Snapshot
		// Exchange verified the peer's real creation time. The producer's
		// GetProcessTimes can reflect the configured virtual clock.
		if err != nil || json.Unmarshal(response, &snap) != nil || snap.Version != connectionlog.Version ||
			snap.PID != id.PID || len(snap.Active) > connectionlog.ActiveLimit ||
			len(snap.Closed) > connectionlog.HistoryLimit {
			waiting++
			continue
		}
		observed[key] = true
		h.record(id, p, snap, now)
	}
	h.finishPoll(observed, waiting, now)
}
