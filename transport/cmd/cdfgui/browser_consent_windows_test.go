package main

import (
	"encoding/json"
	"errors"
	"testing"

	"golang.org/x/sys/windows/registry"
)

func TestBrowserConsentIsOptInAndPerUser(t *testing.T) {
	f := newProfileFixture(t)
	id, err := token()
	if err != nil {
		t.Fatal(err)
	}
	path := `Software\CdfConsentFixture-` + id
	f.d.browserPrefs = path
	t.Cleanup(func() {
		if err := registry.DeleteKey(registry.CURRENT_USER, path); err != nil && !errors.Is(err, registry.ErrNotExist) {
			t.Error(err)
		}
	})
	status := func() browserConsentSetting {
		w := f.request("GET", "/api/status", "", nil)
		var s struct {
			Consent *browserConsentSetting `json:"browserConsent"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &s) != nil || s.Consent == nil {
			t.Fatal("missing consent status")
		}
		return *s.Consent
	}
	set := func(payload string, code int) {
		if got := f.request("POST", "/api/browser-consent", "application/json", []byte(payload)).Code; got != code {
			t.Fatalf("wanted %d, got %d", code, got)
		}
	}
	if s := status(); s.Enabled || s.Error != "" {
		t.Fatal("missing preference must be off")
	}
	if k, err := registry.OpenKey(registry.CURRENT_USER, path, registry.QUERY_VALUE); err == nil {
		k.Close()
		t.Fatal("read created a key")
	}
	f.d.writes = false
	set(`{"enabled":true}`, 403)
	f.d.writes = true
	set(`{}`, 400)
	set(`{"enabled":true,"url":"fixture"}`, 400)
	f.bearer = ""
	set(`{"enabled":true}`, 401)
	f.bearer = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	set(`{"enabled":true}`, 200)
	if s := status(); !s.Enabled || s.Error != "" {
		t.Fatal("enabled preference not persisted")
	}
	k, err := registry.OpenKey(registry.CURRENT_USER, path, registry.SET_VALUE)
	if err != nil {
		t.Fatal(err)
	}
	err = k.SetStringValue(browserPrefsValue, "malformed")
	k.Close()
	if err != nil {
		t.Fatal(err)
	}
	if s := status(); !s.Enabled || s.Error == "" {
		t.Fatal("invalid preference must report a reading error")
	}
	set(`{"enabled":false}`, 200)
	if s := status(); s.Enabled || s.Error != "" {
		t.Fatal("disabled preference not persisted")
	}
}
