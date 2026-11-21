// Copyright (c) 2026 claude-desktop-fake contributors. MIT license.
package connectionlog

import (
	"sync"
	"time"
)

const (
	Version      = 1
	ActiveLimit  = 4096
	HistoryLimit = 512
)

type Record struct {
	ID         uint64    `json:"id"`
	Target     string    `json:"target"`
	ServerName string    `json:"serverName,omitempty"`
	Port       uint16    `json:"port"`
	State      string    `json:"state"`
	Started    time.Time `json:"started"`
	Active     time.Time `json:"active,omitempty"`
	Ended      time.Time `json:"ended,omitempty"`
	DurationMS int64     `json:"durationMs"`
	Reason     string    `json:"reason,omitempty"`
	Cursor     uint64    `json:"cursor,omitempty"`
}

type Snapshot struct {
	Version     int          `json:"version"`
	PID         uint32       `json:"pid"`
	Created     uint64       `json:"created"`
	Cursor      uint64       `json:"cursor"`
	Lost        bool         `json:"lost"`
	Overflow    bool         `json:"overflow"`
	ServerNames bool         `json:"serverNames"`
	Active      []Record     `json:"active"`
	Closed      []Record     `json:"closed"`
	DNS         *DNSSnapshot `json:"dns,omitempty"`
}

// The transport publishes metadata only. Snapshot copies are made under this
// lock and serialized after releasing it, independent of forwarding I/O.
type Log struct {
	mu        sync.Mutex
	nextID    uint64
	cursor    uint64
	dropped   bool
	active    map[uint64]Record
	closed    [HistoryLimit]Record
	dnsCursor uint64
	dns       [DNSLimit]DNSRecord
}

func (l *Log) Begin(target string, port uint16, now time.Time) uint64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.active) >= ActiveLimit {
		l.dropped = true
		return 0
	}
	if l.active == nil {
		l.active = make(map[uint64]Record)
	}
	l.nextID++
	l.active[l.nextID] = Record{ID: l.nextID, Target: target, Port: port, State: "connecting", Started: now.UTC()}
	return l.nextID
}

func (l *Log) Activate(id uint64, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if r, ok := l.active[id]; ok {
		r.Active, r.State = now.UTC(), "active"
		l.active[id] = r
	}
}

func (l *Log) SetServerName(id uint64, name string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if r, ok := l.active[id]; ok {
		r.ServerName = name
		l.active[id] = r
	}
}

func (l *Log) Finish(id uint64, reason string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	r, ok := l.active[id]
	if !ok {
		return
	}
	delete(l.active, id)
	l.cursor++
	r.Ended, r.State, r.Reason, r.Cursor = now.UTC(), "closed", reason, l.cursor
	r.DurationMS = max(0, now.Sub(r.Started).Milliseconds())
	l.closed[(l.cursor-1)%HistoryLimit] = r
}

func (l *Log) Snapshot(pid uint32, created, since uint64, now time.Time) Snapshot {
	l.mu.Lock()
	defer l.mu.Unlock()
	s := Snapshot{Version: Version, PID: pid, Created: created, Cursor: l.cursor, Overflow: l.dropped, ServerNames: true,
		Active: make([]Record, 0, len(l.active)), Closed: []Record{}}
	for _, r := range l.active {
		r.DurationMS = max(0, now.Sub(r.Started).Milliseconds())
		s.Active = append(s.Active, r)
	}
	if since >= l.cursor {
		return s
	}
	if l.cursor-since > HistoryLimit {
		s.Lost = true
		since = l.cursor - HistoryLimit
	}
	for seq := since + 1; seq <= l.cursor; seq++ {
		s.Closed = append(s.Closed, l.closed[(seq-1)%HistoryLimit])
	}
	return s
}
