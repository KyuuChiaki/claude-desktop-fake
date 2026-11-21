package connectionlog

import (
	"testing"
	"time"
)

func TestConnectionLifecycleAndHistory(t *testing.T) {
	var log Log
	now := time.Now()
	pending := log.Begin("203.0.113.5", 443, now)
	relay := log.Begin("192.0.2.6", 8443, now)
	log.Activate(relay, now.Add(time.Second))
	log.Finish(pending, "handshake-failed", now.Add(2*time.Second))
	log.Finish(pending, "cancelled", now.Add(3*time.Second))
	s := log.Snapshot(7, 90, 0, now.Add(4*time.Second))
	if len(s.Active) != 1 || s.Active[0].ID != relay || s.Active[0].State != "active" || s.Active[0].DurationMS != 4000 {
		t.Fatalf("active snapshot: %+v", s.Active)
	}
	if len(s.Closed) != 1 || s.Closed[0].Reason != "handshake-failed" || s.Closed[0].DurationMS != 2000 {
		t.Fatalf("closed snapshot: %+v", s.Closed)
	}
	log.Finish(relay, "finished", now.Add(5*time.Second))
	after := log.Snapshot(7, 90, s.Cursor, now)
	if len(after.Active) != 0 || len(after.Closed) != 1 || after.Closed[0].ID != relay {
		t.Fatalf("incremental snapshot: %+v", after)
	}
}

func TestBoundedHistorySignalsGap(t *testing.T) {
	var log Log
	now := time.Now()
	for i := 0; i < HistoryLimit+19; i++ {
		id := log.Begin("203.0.113.2", 443, now)
		log.Finish(id, "finished", now)
	}
	s := log.Snapshot(1, 2, 0, now)
	if !s.Lost || len(s.Closed) != HistoryLimit || s.Closed[0].Cursor != 20 || s.Closed[len(s.Closed)-1].Cursor != s.Cursor {
		t.Fatal("ring did not indicate trimmed history")
	}
	for i := 0; i < ActiveLimit; i++ {
		log.Begin("203.0.113.3", 443, now)
	}
	if log.Begin("203.0.113.4", 443, now) != 0 || !log.Snapshot(1, 2, s.Cursor, now).Overflow {
		t.Fatal("active record limit was not enforced")
	}
}
