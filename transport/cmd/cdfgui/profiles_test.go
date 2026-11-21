package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

var exampleProxy = proxyValues{
	Server: "192.0.2.10", Port: 443, UUID: "11111111-2222-4333-8444-555555555555",
	ServerName: "edge.example", PublicKey: strings.Repeat("A", 43), ShortID: "0004",
}

func yamlNode(name, port string) string {
	return fmt.Sprintf("{name: %q, type: vless, server: %s, port: %s, uuid: %s, servername: %s, tls: true, flow: xtls-rprx-vision, reality-opts: {public-key: %s, short-id: 0004}}",
		name, exampleProxy.Server, port, exampleProxy.UUID, exampleProxy.ServerName, exampleProxy.PublicKey)
}

func TestLocalProfileYAML(t *testing.T) {
	node := yamlNode("示例", "443")
	for _, raw := range []string{node, "- " + yamlNode("示例", "'443'"), "global-client-fingerprint: chrome\nproxies:\n  - " + node,
		"name: 示例\ntype: vless\nserver: 192.0.2.10\nport: 443\nuuid: " + exampleProxy.UUID + "\nservername: edge.example\nflow: xtls-rprx-vision\nreality-opts:\n  public-key: " + exampleProxy.PublicKey + "\n  short-id: '0004'"} {
		profiles, skipped, err := parseProfilesYAML([]byte(raw))
		if err != nil || skipped != 0 || len(profiles) != 1 || profiles[0].Name != "示例" || profiles[0].Values != exampleProxy {
			t.Fatalf("valid YAML was not preserved: skipped=%d error=%v", skipped, err)
		}
	}
	mixed := "proxies:\n - {name: other, type: ss}\n - " + node + "\n - " + strings.Replace(node, "tls: true", "tls: false", 1)
	if profiles, skipped, err := parseProfilesYAML([]byte(mixed)); err != nil || len(profiles) != 1 || skipped != 2 {
		t.Fatalf("mixed import: skipped=%d error=%v", skipped, err)
	}
	for _, raw := range []string{"", "[]", "proxies: {}", "proxies: []\nproxies: []", node + "\n---\n" + node,
		"global-client-fingerprint: firefox\nproxies:\n - " + node, strings.Replace(node, "tls: true", "tls: true, network: ws", 1),
		strings.Replace(node, "port: 443", "port: 443, port: 8443", 1), strings.Replace(node, "port: 443", "port: 70000", 1),
		strings.Replace(node, exampleProxy.Server, "upstream.example", 1), strings.Replace(node, "short-id: 0004", "short-id: 000", 1),
		strings.Replace(node, "port: 443", "port: ["+exampleProxy.UUID+"]", 1), strings.Repeat("x", maxProfileYAML+1)} {
		if _, _, err := parseProfilesYAML([]byte(raw)); err == nil || strings.Contains(err.Error(), exampleProxy.UUID) {
			t.Fatal("expected an error with no credentials")
		}
	}
}

type profileFixture struct {
	d      *dashboard
	bearer string
}

func newProfileFixture(t *testing.T) profileFixture {
	t.Helper()
	l, _, err := bind(0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	d := newDashboard(ctx, cancel, l, false, true, nil)
	dir := t.TempDir()
	d.profiles = &profileStore{filepath.Join(dir, "catalog.dpapi"), filepath.Join(dir, "active.dpapi")}
	key := strings.Repeat("a", 48)
	d.sessions[key] = time.Now().Add(time.Hour)
	return profileFixture{d, key}
}

func (f profileFixture) request(method, route, mime string, body []byte) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, f.d.origin+route, bytes.NewReader(body))
	r.RemoteAddr = "127.0.0.1:49101"
	r.Header.Set("Origin", f.d.origin)
	r.Header.Set("Authorization", "Bearer "+f.bearer)
	r.Header.Set("Content-Type", mime)
	w := httptest.NewRecorder()
	f.d.ServeHTTP(w, r)
	return w
}

func (f profileFixture) catalog(t *testing.T, route string, payload any, want int) profileList {
	t.Helper()
	method, mime := "POST", "application/json"
	var body []byte
	switch v := payload.(type) {
	case nil:
		method = "GET"
	case string:
		mime = "application/yaml"
		body = []byte(v)
	default:
		var err error
		body, err = json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
	}
	w := f.request(method, route, mime, body)
	if w.Code != want || strings.Contains(w.Body.String(), exampleProxy.UUID) || strings.Contains(w.Body.String(), exampleProxy.PublicKey) {
		t.Fatalf("%s: expected redacted HTTP %d, got %d", route, want, w.Code)
	}
	var list profileList
	if err := json.Unmarshal(w.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	return list
}

func storeFixtureBytes(t *testing.T, path string, plain []byte) {
	t.Helper()
	sealed, err := profileDPAPI(plain, true)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, sealed, 0600); err != nil {
		t.Fatal(err)
	}
}

func installExampleProfile(t *testing.T, s *profileStore) {
	t.Helper()
	var c clashProfile
	c.Type, c.Server, c.Port, c.UUID, c.SNI, c.Flow = "vless", exampleProxy.Server, "443", exampleProxy.UUID, exampleProxy.ServerName, "xtls-rprx-vision"
	c.Reality.Key, c.Reality.ID = exampleProxy.PublicKey, exampleProxy.ShortID
	raw, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	storeFixtureBytes(t, s.activeFile, raw)
}

func TestSharedDeploymentAndCatalogWithConsoleToken(t *testing.T) {
	const childDir = "CDF_GUI_FIXTURE_PROFILE_DIR"
	if dir := os.Getenv(childDir); dir != "" {
		f := newProfileFixture(t)
		f.d.profiles = &profileStore{filepath.Join(dir, "user", "catalog.dpapi"), filepath.Join(dir, "active.dpapi")}
		view := f.catalog(t, "/api/profiles", nil, 200)
		if len(view.Profiles) != 1 || view.ActiveID == "" {
			t.Fatal("restricted console could not read the existing test deployment")
		}
		f.catalog(t, "/api/profiles/rename", map[string]string{"id": view.ActiveID, "previousName": "默认代理", "name": "Fixture"}, 200)
		return
	}
	if !isAdmin() {
		t.Skip("requires an elevated parent to exercise both console tokens")
	}
	dir := t.TempDir()
	s := &profileStore{filepath.Join(dir, "user", "catalog.dpapi"), filepath.Join(dir, "active.dpapi")}
	installExampleProfile(t, s)
	restricted, err := restrictedToken()
	if err != nil {
		t.Fatal(err)
	}
	defer restricted.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestSharedDeploymentAndCatalogWithConsoleToken$")
	cmd.Env = append(os.Environ(), childDir+"="+dir)
	cmd.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(restricted), HideWindow: true, CreationFlags: windows.DETACHED_PROCESS}
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("console token: %v\n%s", err, output)
	}
	book, err := s.load()
	if err != nil || len(book.Entries) != 1 || book.Entries[0].Name != "Fixture" || book.Entries[0].Values != exampleProxy {
		t.Fatal("parent could not reopen the catalog saved by the console token")
	}
}

func TestProfileBookRoundTripAndAtomicImport(t *testing.T) {
	f := newProfileFixture(t)
	s := f.d.profiles
	list := func() profileList { return f.catalog(t, "/api/profiles", nil, 200) }
	if view := list(); len(view.Profiles) != 0 || view.ActiveID != "" {
		t.Fatal("new catalog must be empty")
	}
	installExampleProfile(t, s)
	active := list()
	if len(active.Profiles) != 1 || active.Profiles[0].Name != "默认代理" || active.Profiles[0].ID != active.ActiveID || list().ActiveID != active.ActiveID {
		t.Fatal("invalid existing deployment projection")
	}
	for _, p := range []string{s.file, s.file + ".lock"} {
		if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("reading materialized the catalog")
		}
	}
	different := exampleProxy
	different.ShortID = "ab00"
	create := func(name string, want int) profileList {
		return f.catalog(t, "/api/profiles", map[string]any{"name": name, "values": different}, want)
	}
	saved := create("  Travel  ", 200)
	if len(saved.Profiles) != 2 || saved.Profiles[1].Name != "Travel" || saved.ActiveID != active.ActiveID {
		t.Fatal("invalid named profile or mistaken active endpoint")
	}
	create("tRaVeL", 409)
	if got, err := s.resolve(saved.Selected, false); err != nil || got != different {
		t.Fatal("could not resolve re-opened catalog")
	}
	rename := func(previous, name string, want int) {
		f.catalog(t, "/api/profiles/rename", map[string]string{"id": saved.Selected, "previousName": previous, "name": name}, want)
	}
	rename("Travel", "TRAVEL", 200)
	rename("Travel", "Stale", 409)
	rename("TRAVEL", "默认代理", 409)
	readCiphertext := func() []byte {
		raw, err := os.ReadFile(s.file)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	snapshot := readCiphertext()
	if bytes.Contains(snapshot, []byte("TRAVEL")) || bytes.Contains(snapshot, []byte(exampleProxy.UUID)) {
		t.Fatal("catalog must be encrypted on disk")
	}
	batch := "proxies:\n - " + yamlNode("One", "443") + "\n - "
	f.catalog(t, "/api/profiles/import", batch+yamlNode("travel", "443"), 409)
	f.catalog(t, "/api/profiles/import", batch+yamlNode("one", "443"), 409)
	f.catalog(t, "/api/profiles/import", batch+yamlNode("Bad", "70000"), 400)
	if !bytes.Equal(snapshot, readCiphertext()) || len(list().Profiles) != 2 {
		t.Fatal("failed batch partly committed")
	}
	good := f.catalog(t, "/api/profiles/import", batch+"{name: foreign, type: ss}", 200)
	if good.Imported != 1 || good.Skipped != 1 || good.Selected == "" || good.ActiveID != active.ActiveID {
		t.Fatal("unexpected import result")
	}
	f.catalog(t, "/api/profiles/import", strings.Repeat("x", maxProfileYAML+1), 413)
	f.d.writes = false
	f.catalog(t, "/api/profiles/import", batch, 403)
	f.bearer = ""
	f.catalog(t, "/api/profiles", nil, 401)
}

func TestProfileBookRejectsDamageAndConcurrentDuplicates(t *testing.T) {
	f := newProfileFixture(t)
	names := []string{"One", "oNe", "Two", "Three"}
	results := make(chan int, len(names))
	for _, n := range names {
		body, _ := json.Marshal(map[string]any{"name": n, "values": exampleProxy})
		go func() { results <- f.request("POST", "/api/profiles", "application/json", body).Code }()
	}
	codes := map[int]int{}
	for range names {
		codes[<-results]++
	}
	if codes[200] != 3 || codes[409] != 1 || len(f.catalog(t, "/api/profiles", nil, 200).Profiles) != 3 {
		t.Fatalf("concurrent updates: %v", codes)
	}
	for _, broken := range []string{"null", "{}", `{"version":1,"profiles":null}`, "bad JSON"} {
		storeFixtureBytes(t, f.d.profiles.file, []byte(broken))
		before, err := os.ReadFile(f.d.profiles.file)
		if err != nil {
			t.Fatal(err)
		}
		f.catalog(t, "/api/profiles", map[string]any{"name": "new", "values": exampleProxy}, 409)
		after, err := os.ReadFile(f.d.profiles.file)
		if err != nil || !bytes.Equal(before, after) {
			t.Fatal("damaged catalog overwritten")
		}
	}
}

func TestProfileActionsResolveOnlySelectedCredentials(t *testing.T) {
	f := newProfileFixture(t)
	installExampleProfile(t, f.d.profiles)
	v := f.catalog(t, "/api/profiles", map[string]any{"name": "Alias", "values": exampleProxy}, 200)
	id := v.Selected
	const adapter = "{00000000-0000-0000-0000-000000000001}"
	a := action{Action: "proxy.test", ProfileID: id, Proxy: &proxyDraft{InterfaceGUID: adapter}}
	calls := 0
	f.d.run = func(_ context.Context, r action, _ func(string)) (json.RawMessage, error) {
		if r.ProfileID != "" || r.Proxy.proxyValues != exampleProxy || r.Proxy.InterfaceGUID != adapter {
			t.Fatal("incorrect action payload to executor")
		}
		calls++
		return json.RawMessage(`{"ok":true}`), nil
	}
	run := func() {
		if err := a.validate(); err != nil {
			t.Fatal(err)
		}
		f.d.perform("test", a)
	}
	run()
	if calls != 1 || f.d.jobs["test"].State != "done" || f.catalog(t, "/api/profiles", nil, 200).ActiveID != v.ActiveID {
		t.Fatal("testing must not switch names")
	}
	a.Action, a.Revision = "proxy.save", "missing"
	run()
	if calls != 2 || f.d.jobs["test"].State != "done" || f.catalog(t, "/api/profiles", nil, 200).ActiveID != id {
		t.Fatal("successful apply did not record the right alias")
	}
	a.ProfileID = "missing-profile"
	run()
	if calls != 2 || f.d.jobs["test"].State != "failed" {
		t.Fatal("unknown selection executed")
	}
	a.Proxy.Reuse = true
	if a.validate() == nil {
		t.Fatal("ambiguous named and legacy profile accepted")
	}
	a.ProfileID = ""
	if err := a.validate(); err != nil {
		t.Fatal("legacy reuse no longer accepted")
	}
}
