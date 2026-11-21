package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"claude-desktop-fake/network-transport/internal/connectionlog"
	"claude-desktop-fake/network-transport/internal/localpipe"
)

func TestFallbackPortAndSession(t *testing.T) {
	first, _, err := bind(0)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	occupied := first.Addr().(*net.TCPAddr).Port
	second, fallback, err := bind(occupied)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	if !fallback || second.Addr().(*net.TCPAddr).Port == occupied || !second.Addr().(*net.TCPAddr).IP.IsLoopback() {
		t.Fatal("server did not fall back to a distinct loopback port")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d := newDashboard(ctx, cancel, second, fallback, false, nil)
	url, err := d.ticket()
	if err != nil {
		t.Fatal(err)
	}
	ticket := strings.SplitN(url, "#ticket=", 2)[1]
	request := func(method, path, origin, bearer, data string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, d.origin+path, strings.NewReader(data))
		r.RemoteAddr = "127.0.0.1:49100"
		r.Header.Set("Origin", origin)
		r.Header.Set("Content-Type", "application/json")
		if bearer != "" {
			r.Header.Set("Authorization", "Bearer "+bearer)
		}
		w := httptest.NewRecorder()
		d.ServeHTTP(w, r)
		return w
	}
	body := fmt.Sprintf(`{"ticket":%q}`, ticket)
	if code := request("POST", "/api/session", "https://example.invalid", "", body).Code; code != http.StatusForbidden {
		t.Fatalf("cross-origin ticket: %d", code)
	}
	opened := request("POST", "/api/session", d.origin, "", body)
	var session map[string]string
	if opened.Code != http.StatusOK || json.Unmarshal(opened.Body.Bytes(), &session) != nil || session["session"] == "" {
		t.Fatalf("session not granted, status %d", opened.Code)
	}
	if code := request("POST", "/api/session", d.origin, "", body).Code; code != http.StatusUnauthorized {
		t.Fatalf("ticket replay: %d", code)
	}
	if code := request("GET", "/api/status", "", "", "").Code; code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status: %d", code)
	}
	if code := request("GET", "/api/status", "", session["session"], "").Code; code != http.StatusOK {
		t.Fatalf("authorized status: %d", code)
	}
	if code := request("POST", "/api/actions", d.origin, session["session"], `{"action":"project.switch","enabled":true}`).Code; code != http.StatusForbidden {
		t.Fatalf("read-only mutation: %d", code)
	}
	r := httptest.NewRequest("GET", "http://other.invalid/api/status", nil)
	r.RemoteAddr = "127.0.0.1:49100"
	r.Header.Set("Authorization", "Bearer "+session["session"])
	w := httptest.NewRecorder()
	d.ServeHTTP(w, r)
	if w.Code != http.StatusForbidden {
		t.Fatalf("host header validation: %d", w.Code)
	}
}

func TestProxySwitchKeepsVerifiedStatusDuringRefresh(t *testing.T) {
	listener, _, err := bind(0)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first, release, next := make(chan struct{}), make(chan struct{}), make(chan struct{})
	stale := json.RawMessage(`{"proxyEnabled":true,"proxyRequested":true}`)
	run := func(ctx context.Context, request action, phase func(string)) (json.RawMessage, error) {
		if request.Action == "proxy.switch" {
			return json.RawMessage(`{"ok":true,"proxyEnabled":false,"proxyRequested":false}`), nil
		}
		select {
		case <-first:
			close(next)
			<-ctx.Done()
			return nil, ctx.Err()
		default:
			close(first)
			select {
			case <-release:
				return stale, nil
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
	}
	d := newDashboard(ctx, cancel, listener, false, true, run)
	d.status = stale
	go d.update()
	wait := func(ch <-chan struct{}) {
		t.Helper()
		select {
		case <-ch:
		case <-time.After(2 * time.Second):
			t.Fatal("status refresh did not start")
		}
	}
	wait(first)
	d.mu.Lock()
	d.busy = true
	d.mu.Unlock()
	enable := false
	d.perform("fixture", action{Action: "proxy.switch", Enabled: &enable})
	close(release)
	wait(next)
	d.mu.Lock()
	defer d.mu.Unlock()
	result := d.jobs["fixture"]
	if result.State != "done" || result.StatusVersion != 1 || d.snapshotVersion != 0 ||
		string(d.status) != `{"proxyEnabled":false,"proxyRequested":false}` {
		t.Fatalf("stale refresh replaced verified result: %s, %+v", d.status, result)
	}
}

func TestJobReportsExecutionPhaseAndCollectsFreshStatus(t *testing.T) {
	listener, _, err := bind(0)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	entered, finish := make(chan struct{}), make(chan struct{})
	run := func(ctx context.Context, request action, report func(string)) (json.RawMessage, error) {
		if request.Action == "status" {
			return json.RawMessage(`{"timeRevision":"new"}`), nil
		}
		report("authorization")
		close(entered)
		select {
		case <-finish:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		return json.RawMessage(`{"ok":true,"timeRevision":"new"}`), nil
	}
	d := newDashboard(ctx, cancel, listener, false, true, run)
	d.jobs["draft"] = job{ID: "draft", State: "running", Phase: "queued"}
	d.busy = true
	done := make(chan struct{})
	go func() {
		d.perform("draft", action{Action: "time.save"})
		close(done)
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("missing progress notification")
	}
	d.mu.Lock()
	phase := d.jobs["draft"].Phase
	d.mu.Unlock()
	if phase != "authorization" {
		t.Fatal(phase)
	}
	close(finish)
	<-done
	if d.statusVersion != 1 || d.snapshotVersion != 0 {
		t.Fatal("cached snapshot marked fresh before a full read")
	}
	go d.update()
	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); {
		d.mu.Lock()
		fresh := d.snapshotVersion == 1 && string(d.status) == `{"timeRevision":"new"}`
		d.mu.Unlock()
		if fresh {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("fresh status did not advance snapshot generation")
}

func TestReadSelectedGUIRelease(t *testing.T) {
	file := filepath.Join(t.TempDir(), "current.json")
	if got := readSelectedRelease(file); got != "" {
		t.Fatal(got)
	}
	key := strings.Repeat("ab", 32)
	for _, tc := range []struct{ text, want string }{
		{fmt.Sprintf(`{"schemaVersion":1,"release":%q}`, key), strings.ToUpper(key)},
		{fmt.Sprintf(`{"schemaVersion":2,"release":%q}`, key), ""},
		{`{"schemaVersion":1,"release":"unrelated"}`, ""},
		{strings.Repeat(" ", 4097) + fmt.Sprintf(`{"schemaVersion":1,"release":%q}`, key), ""},
	} {
		if err := os.WriteFile(file, []byte(tc.text), 0600); err != nil {
			t.Fatal(err)
		}
		if got := readSelectedRelease(file); got != tc.want {
			t.Errorf("got %q; want %q", got, tc.want)
		}
	}
}

func TestHistoryPollUsesVerifiedPeerCreationTime(t *testing.T) {
	identity, err := localpipe.ProcessIdentity(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	name := localpipe.Name(identity.Logon, fmt.Sprintf("connections.%d", identity.PID))
	pipe, err := localpipe.Listen(name, identity)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	now := time.Now()
	var log connectionlog.Log
	log.Activate(log.Begin("203.0.113.9", 443, now), now)
	go pipe.Serve(ctx, func(_ []byte, _ localpipe.Identity) []byte {
		result, _ := json.Marshal(log.Snapshot(identity.PID, identity.Created+36_000_000_000, 0, now))
		return result
	})
	h := newHistory(now)
	h.poll(ctx, identity, []processRow{{
		PID: identity.PID, Created: fmt.Sprint(identity.Created), NetworkLoaded: true,
	}})
	if source := h.list[procKey(identity)]; source == nil || len(source.active) != 1 || h.waiting != 0 {
		t.Fatalf("connection from the verified peer was dropped: %+v", h.view())
	}
}

func TestDNSHistoryIsIndependentAndDoesNotReplay(t *testing.T) {
	now := time.Now()
	h := newHistory(now)
	id := localpipe.Identity{PID: 42, Created: 99}
	target := processRow{PID: id.PID, Name: "fixture.exe"}
	var log connectionlog.Log
	log.RecordDNS(connectionlog.DNSRecord{Name: "service.example", Type: "A", Status: "ok", Finished: now.Add(time.Second)})
	snapshot := log.Snapshot(id.PID, id.Created, 0, now)
	snapshot.DNS = log.DNS(0)
	h.record(id, target, snapshot, now.Add(time.Second))
	h.record(id, target, snapshot, now.Add(time.Second))
	if len(h.dnsQueries) != 1 || h.dnsQueries[0].PID != id.PID {
		t.Fatalf("query attribution or replay failed: %+v", h.dnsQueries)
	}
	h.clear(now.Add(2 * time.Second))
	if len(h.dnsQueries) != 1 {
		t.Fatal("clearing connection history removed DNS records")
	}
	h.clearDNS(now.Add(3 * time.Second))
	h.record(id, target, snapshot, now.Add(3*time.Second))
	if len(h.dnsQueries) != 0 || h.list[procKey(id)].dnsCursor != 1 {
		t.Fatal("DNS records replayed after clearing")
	}
}

func TestHistoryKeepsActiveWhileClearingAndReplaysOnce(t *testing.T) {
	now := time.Now()
	h := newHistory(now)
	id := localpipe.Identity{PID: 42, Created: 99}
	proc := processRow{PID: id.PID, Name: "fixture.exe", Role: "network-service"}
	var log connectionlog.Log
	first := log.Begin("203.0.113.1", 443, now)
	ongoing := log.Begin("203.0.113.2", 443, now)
	log.Activate(ongoing, now)
	log.Finish(first, "cancelled", now.Add(time.Second))
	s := log.Snapshot(id.PID, id.Created, 0, now.Add(2*time.Second))
	h.record(id, proc, s, now.Add(2*time.Second))
	h.record(id, proc, s, now.Add(2*time.Second))
	if len(h.closed) != 1 || len(h.list[procKey(id)].active) != 1 {
		t.Fatal("duplicate event replay or missing active row")
	}
	h.clear(now.Add(3 * time.Second))
	h.record(id, proc, s, now.Add(3*time.Second))
	if len(h.closed) != 0 || len(h.list[procKey(id)].active) != 1 {
		t.Fatal("old history replayed or active record was removed")
	}
	log.Finish(ongoing, "finished", now.Add(4*time.Second))
	h.record(id, proc, log.Snapshot(id.PID, id.Created, s.Cursor, now), now.Add(4*time.Second))
	if len(h.closed) != 1 || h.closed[0].ID != ongoing || len(h.list[procKey(id)].active) != 0 {
		t.Fatal("new history missing after clear")
	}
}
