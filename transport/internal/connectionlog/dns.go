package connectionlog

import "time"

const DNSLimit = 512

type DNSRecord struct {
	Cursor     uint64    `json:"cursor"`
	Name       string    `json:"name"`
	Type       string    `json:"type"`
	Status     string    `json:"status"`
	Addresses  []string  `json:"addresses,omitempty"`
	Finished   time.Time `json:"finished"`
	DurationMS int64     `json:"durationMs"`
}

type DNSSnapshot struct {
	Cursor  uint64      `json:"cursor"`
	Lost    bool        `json:"lost"`
	Queries []DNSRecord `json:"queries"`
}

func (l *Log) RecordDNS(r DNSRecord) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.dnsCursor++
	r.Cursor = l.dnsCursor
	l.dns[(r.Cursor-1)%DNSLimit] = r
}

func (l *Log) DNS(since uint64) *DNSSnapshot {
	l.mu.Lock()
	defer l.mu.Unlock()
	s := &DNSSnapshot{Cursor: l.dnsCursor, Queries: []DNSRecord{}}
	if since >= l.dnsCursor {
		return s
	}
	if l.dnsCursor-since > DNSLimit {
		s.Lost = true
		since = l.dnsCursor - DNSLimit
	}
	for seq := since + 1; seq <= l.dnsCursor; seq++ {
		s.Queries = append(s.Queries, l.dns[(seq-1)%DNSLimit])
	}
	return s
}
