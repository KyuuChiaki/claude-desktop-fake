package main

import (
	"errors"
	"net/http"

	"golang.org/x/sys/windows/registry"
)

const browserPrefsPath = `Software\ClaudeDesktopFake\Preferences`
const browserPrefsValue = "ConfirmBrowserLinks"

type browserConsentSetting struct {
	Enabled bool   `json:"enabled"`
	Error   string `json:"error,omitempty"`
}

func readBrowserConsent(path string) browserConsentSetting {
	key, err := registry.OpenKey(registry.CURRENT_USER, path, registry.QUERY_VALUE)
	if errors.Is(err, registry.ErrNotExist) {
		return browserConsentSetting{}
	}
	if err == nil {
		defer key.Close()
		value, kind, readErr := key.GetIntegerValue(browserPrefsValue)
		if errors.Is(readErr, registry.ErrNotExist) {
			return browserConsentSetting{}
		}
		if readErr == nil && kind == registry.DWORD && value <= 1 {
			return browserConsentSetting{Enabled: value == 1}
		}
	}
	return browserConsentSetting{Enabled: true, Error: "无法确认当前用户的设置；新版组件遇到读取错误时会要求确认。"}
}

func (d *dashboard) setBrowserConsent(w http.ResponseWriter, r *http.Request) {
	if !d.writes {
		problem(w, http.StatusForbidden, "当前控制台为只读模式")
		return
	}
	var change struct {
		Enabled *bool `json:"enabled"`
	}
	if err := readJSON(w, r, &change); err != nil || change.Enabled == nil {
		problem(w, http.StatusBadRequest, "需要明确指定开关值")
		return
	}
	key, _, err := registry.CreateKey(registry.CURRENT_USER, d.browserPrefs, registry.SET_VALUE)
	if err == nil {
		defer key.Close()
		var value uint32
		if *change.Enabled {
			value = 1
		}
		err = key.SetDWordValue(browserPrefsValue, value)
	}
	if err != nil {
		problem(w, http.StatusInternalServerError, "无法保存当前用户的浏览器确认设置")
		return
	}
	setting := readBrowserConsent(d.browserPrefs)
	if setting.Error != "" || setting.Enabled != *change.Enabled {
		problem(w, http.StatusConflict, "当前设置已变化，请刷新后重试")
		return
	}
	respond(w, http.StatusOK, setting)
}
