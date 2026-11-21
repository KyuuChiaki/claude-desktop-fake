// Copyright (c) 2026 claude-desktop-fake contributors. MIT license.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web/*
var assets embed.FS

type timeDraft struct {
	Enabled          bool   `json:"enabled"`
	TimeZoneID       string `json:"timeZoneId"`
	UTCOffsetSeconds int64  `json:"utcOffsetSeconds"`
}

type localeDraft struct {
	Enabled      bool   `json:"enabled"`
	FormatLocale string `json:"formatLocale"`
	UILanguage   string `json:"uiLanguage"`
}

type proxyDraft struct {
	InterfaceGUID string `json:"interfaceGuid"`
	Reuse         bool   `json:"reuse"`
	proxyValues
}

type proxyValues struct {
	Server     string `json:"server"`
	Port       int    `json:"port"`
	UUID       string `json:"uuid"`
	ServerName string `json:"serverName"`
	PublicKey  string `json:"publicKey"`
	ShortID    string `json:"shortId"`
}

type action struct {
	Action    string       `json:"action"`
	Revision  string       `json:"revision,omitempty"`
	Enabled   *bool        `json:"enabled,omitempty"`
	Time      *timeDraft   `json:"time,omitempty"`
	Locale    *localeDraft `json:"locale,omitempty"`
	Upgrade   bool         `json:"upgrade,omitempty"`
	Proxy     *proxyDraft  `json:"proxy,omitempty"`
	ProfileID string       `json:"profileId,omitempty"`
}

func (a action) privilege() bool {
	switch a.Action {
	case "project.switch", "proxy.switch", "webrtc.switch", "time.save", "proxy.save":
		return true
	}
	return false
}

func (a action) validate() error {
	if a.ProfileID != "" && ((a.Action != "proxy.save" && a.Action != "proxy.test") || a.Upgrade || a.Proxy == nil ||
		a.Proxy.Reuse || a.Proxy.proxyValues != (proxyValues{}) || len(a.ProfileID) > 80) {
		return errors.New("所选代理配置无效")
	}
	switch a.Action {
	case "project.switch", "proxy.switch", "webrtc.switch":
		if a.Enabled == nil {
			return errors.New("开关值缺失")
		}
	case "time.save", "time.preview":
		if a.Time == nil || a.Locale == nil || len(a.Time.TimeZoneID) == 0 || len(a.Time.TimeZoneID) > 127 ||
			len(a.Locale.FormatLocale) > 85 || len(a.Locale.UILanguage) > 85 {
			return errors.New("时区或语言字段无效")
		}
	case "proxy.save", "proxy.test":
		if a.Proxy == nil || len(a.Proxy.InterfaceGUID) != 38 {
			return errors.New("请选择物理网卡")
		}
		if !a.Proxy.Reuse && a.ProfileID == "" {
			ip, err := netip.ParseAddr(a.Proxy.Server)
			if err != nil || !ip.Is4() || a.Proxy.Port < 1 || a.Proxy.Port > 65535 ||
				len(a.Proxy.UUID) != 36 || len(a.Proxy.ServerName) == 0 || len(a.Proxy.ServerName) > 253 ||
				len(a.Proxy.PublicKey) != 43 || len(a.Proxy.ShortID) > 16 {
				return errors.New("代理地址或 VLESS 参数无效")
			}
		}
	case "status", "check":
	default:
		return errors.New("未知操作")
	}
	if (a.Action == "proxy.save" || a.Action == "time.save" || a.Action == "webrtc.switch") && a.Revision != "missing" {
		if value, err := hex.DecodeString(a.Revision); err != nil || len(value) != 32 {
			return errors.New("缺少配置版本，请刷新页面")
		}
	}
	return nil
}

type job struct {
	ID            string          `json:"id"`
	State         string          `json:"state"`
	Phase         string          `json:"phase,omitempty"`
	Message       string          `json:"message,omitempty"`
	Result        json.RawMessage `json:"result,omitempty"`
	StatusVersion uint64          `json:"statusVersion,omitempty"`
}

type executeAction func(context.Context, action, func(string)) (json.RawMessage, error)

type guiBuildInfo struct {
	Build           string `json:"build"`
	RunningRelease  string `json:"runningRelease,omitempty"`
	SelectedRelease string `json:"selectedRelease,omitempty"`
}

type dashboard struct {
	ctx      context.Context
	cancel   context.CancelFunc
	host     string
	origin   string
	fallback bool
	writes   bool
	run      executeAction
	refresh  chan struct{}

	mu                  sync.Mutex
	tickets             map[string]time.Time
	sessions            map[string]time.Time
	status              json.RawMessage
	statusVersion       uint64
	snapshotVersion     uint64 // Generation of the last successful full status read.
	gui                 guiBuildInfo
	selectedReleaseFile string
	lastStatus          time.Time
	lastError           string
	jobs                map[string]job
	jobOrder            []string
	busy                bool
	history             *history
	profiles            *profileStore
	browserPrefs        string
}

func token() (string, error) {
	var b [24]byte
	_, err := rand.Read(b[:])
	return hex.EncodeToString(b[:]), err
}

func newDashboard(ctx context.Context, cancel context.CancelFunc, listener net.Listener, fallback, writes bool, run executeAction) *dashboard {
	addr := listener.Addr().String()
	return &dashboard{ctx: ctx, cancel: cancel, host: addr, origin: "http://" + addr, fallback: fallback, writes: writes,
		run: run, tickets: make(map[string]time.Time), sessions: make(map[string]time.Time), jobs: make(map[string]job),
		refresh: make(chan struct{}, 1), history: newHistory(time.Now()), browserPrefs: browserPrefsPath}
}

func (d *dashboard) ticket() (string, error) {
	key, err := token()
	if err != nil {
		return "", err
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	now := time.Now()
	for old, expires := range d.tickets {
		if !now.Before(expires) {
			delete(d.tickets, old)
		}
	}
	if len(d.tickets) >= 32 {
		return "", errors.New("打开票据过多，请稍候再试")
	}
	d.tickets[key] = now.Add(time.Minute)
	return d.origin + "/#ticket=" + key, nil
}

func (d *dashboard) authorized(r *http.Request) bool {
	bearer, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || len(bearer) != 48 {
		return false
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	expires, exists := d.sessions[bearer]
	if !exists || time.Now().After(expires) {
		delete(d.sessions, bearer)
		return false
	}
	d.sessions[bearer] = time.Now().Add(12 * time.Hour)
	return true
}

func readJSON(w http.ResponseWriter, r *http.Request, value any) error {
	media, _, _ := strings.Cut(r.Header.Get("Content-Type"), ";")
	if strings.TrimSpace(media) != "application/json" {
		return errors.New("需要 JSON 请求")
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8192)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return errors.New("请求数据无效")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return errors.New("请求数据无效")
	}
	return nil
}

func respond(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}

func problem(w http.ResponseWriter, status int, msg string) {
	respond(w, status, map[string]string{"message": msg})
}

func (d *dashboard) openSession(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Ticket string `json:"ticket"`
	}
	if err := readJSON(w, r, &request); err != nil {
		problem(w, http.StatusBadRequest, err.Error())
		return
	}
	session, err := token()
	if err != nil {
		problem(w, http.StatusServiceUnavailable, "无法建立会话")
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	now := time.Now()
	expires, exists := d.tickets[request.Ticket]
	delete(d.tickets, request.Ticket)
	if !exists || !now.Before(expires) {
		problem(w, http.StatusUnauthorized, "打开票据已使用或过期，请重新运行启动脚本")
		return
	}
	for key, expires := range d.sessions {
		if !now.Before(expires) {
			delete(d.sessions, key)
		}
	}
	if len(d.sessions) >= 32 {
		var oldest string
		var date time.Time
		for key, expiry := range d.sessions {
			if oldest == "" || expiry.Before(date) {
				oldest, date = key, expiry
			}
		}
		delete(d.sessions, oldest)
	}
	d.sessions[session] = now.Add(12 * time.Hour)
	respond(w, http.StatusOK, map[string]string{"session": session})
}

func (d *dashboard) start(w http.ResponseWriter, r *http.Request) {
	var request action
	if err := readJSON(w, r, &request); err != nil {
		problem(w, http.StatusBadRequest, err.Error())
		return
	}
	if request.privilege() && !d.writes {
		problem(w, http.StatusForbidden, "请先使用管理员 PowerShell 运行启动脚本，安装管理组件")
		return
	}
	if err := request.validate(); err != nil || request.Action == "status" {
		message := "请通过状态接口读取"
		if err != nil {
			message = err.Error()
		}
		problem(w, http.StatusBadRequest, message)
		return
	}
	id, err := token()
	if err != nil {
		problem(w, http.StatusServiceUnavailable, "无法创建任务")
		return
	}
	d.mu.Lock()
	if d.busy {
		d.mu.Unlock()
		problem(w, http.StatusConflict, "已有操作正在执行")
		return
	}
	d.busy = true
	initial := job{ID: id, State: "running", Phase: "queued"}
	d.jobs[id] = initial
	d.jobOrder = append(d.jobOrder, id)
	if len(d.jobOrder) > 32 {
		delete(d.jobs, d.jobOrder[0])
		d.jobOrder = d.jobOrder[1:]
	}
	d.mu.Unlock()
	go d.perform(id, request)
	respond(w, http.StatusAccepted, initial)
}

func (d *dashboard) perform(id string, request action) {
	timeout := 45 * time.Second
	if request.privilege() {
		timeout = 6 * time.Minute
	}
	ctx, cancel := context.WithTimeout(d.ctx, timeout)
	defer cancel()
	report := func(phase string) {
		d.mu.Lock()
		j := d.jobs[id]
		if j.State == "running" {
			j.Phase = phase
			d.jobs[id] = j
		}
		d.mu.Unlock()
	}
	selected := request.ProfileID
	var err error
	var result json.RawMessage
	if selected != "" {
		if d.profiles == nil {
			err = errors.New("代理配置列表不可用")
		} else {
			proxy := *request.Proxy
			proxy.proxyValues, err = d.profiles.resolve(selected, request.Action == "proxy.save")
			request.Proxy = &proxy
		}
		request.ProfileID = ""
	}
	if err == nil {
		result, err = d.run(ctx, request, report)
	}
	done := job{ID: id, State: "done", Result: result}
	if err != nil {
		done.State, done.Message = "failed", err.Error()
	} else if request.Action == "proxy.save" && selected != "" {
		_, prefErr := d.profiles.change(func(b *profileBook) error {
			b.Preferred = selected
			return nil
		})
		if prefErr != nil {
			var receipt map[string]json.RawMessage
			if json.Unmarshal(result, &receipt) == nil && receipt != nil {
				receipt["message"], _ = json.Marshal("已应用代理配置，无法记录上次选中的配置名称。")
				done.Result, _ = json.Marshal(receipt)
			}
		}
	}
	d.mu.Lock()
	if request.privilege() {
		d.statusVersion++
	}
	done.StatusVersion = d.statusVersion
	if err == nil && (request.Action == "proxy.switch" || request.Action == "project.switch") {
		var selection, status map[string]json.RawMessage
		if json.Unmarshal(result, &selection) == nil && selection["proxyEnabled"] != nil &&
			selection["proxyRequested"] != nil && json.Unmarshal(d.status, &status) == nil && status != nil {
			status["proxyEnabled"], status["proxyRequested"] = selection["proxyEnabled"], selection["proxyRequested"]
			d.status, _ = json.Marshal(status)
		}
	}
	if err == nil && request.Action == "webrtc.switch" {
		var selection, status map[string]json.RawMessage
		if json.Unmarshal(result, &selection) == nil && selection["webRTCDisabled"] != nil &&
			selection["webRTCRevision"] != nil && json.Unmarshal(d.status, &status) == nil && status != nil {
			status["webRTCDisabled"], status["webRTCRevision"] = selection["webRTCDisabled"], selection["webRTCRevision"]
			d.status, _ = json.Marshal(status)
		}
	}
	d.jobs[id] = done
	d.busy = false
	d.mu.Unlock()
	select {
	case d.refresh <- struct{}{}:
	default:
	}
}

func (d *dashboard) update() {
	ticker := time.NewTicker(6 * time.Second)
	defer ticker.Stop()
	for d.ctx.Err() == nil {
		d.mu.Lock()
		version, busy := d.statusVersion, d.busy
		d.mu.Unlock()
		if !busy {
			ctx, cancel := context.WithTimeout(d.ctx, 22*time.Second)
			value, err := d.run(ctx, action{Action: "status"}, func(string) {})
			cancel()
			d.mu.Lock()
			if !d.busy && version == d.statusVersion {
				if err != nil {
					d.lastError = err.Error()
				} else {
					d.status = value
					d.snapshotVersion = version
					d.lastStatus = time.Now()
					d.lastError = ""
				}
			}
			d.mu.Unlock()
		}
		select {
		case <-d.ctx.Done():
			return
		case <-ticker.C:
		case <-d.refresh:
		}
	}
}

func (d *dashboard) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || host != "127.0.0.1" || r.Host != d.host {
		problem(w, http.StatusForbidden, "本机地址校验失败")
		return
	}
	origin := r.Header.Get("Origin")
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		problem(w, http.StatusMethodNotAllowed, "请求方法不受支持")
		return
	}
	if (r.Method == http.MethodPost || origin != "") && origin != d.origin {
		problem(w, http.StatusForbidden, "请求来源无效")
		return
	}
	if r.Header.Get("Sec-Fetch-Site") == "cross-site" && strings.HasPrefix(r.URL.Path, "/api/") {
		problem(w, http.StatusForbidden, "跨站请求被拒绝")
		return
	}
	path := r.URL.Path
	if r.Method == http.MethodGet {
		switch path {
		case "/", "/app.css", "/app.js", "/profiles.js", "/icon.svg":
			name := strings.TrimPrefix(path, "/")
			if name == "" {
				name = "index.html"
			}
			data, err := fs.ReadFile(assets, "web/"+name)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			kind := map[string]string{"/": "text/html", "/app.css": "text/css", "/app.js": "text/javascript", "/profiles.js": "text/javascript", "/icon.svg": "image/svg+xml"}[path]
			w.Header().Set("Content-Type", kind+"; charset=utf-8")
			_, _ = w.Write(data)
			return
		case "/health":
			respond(w, http.StatusOK, map[string]bool{"ready": true})
			return
		}
	}
	if r.Method == http.MethodPost && path == "/api/session" {
		d.openSession(w, r)
		return
	}
	if !d.authorized(r) {
		problem(w, http.StatusUnauthorized, "会话无效，请重新运行启动脚本")
		return
	}
	if path == "/api/profiles" || strings.HasPrefix(path, "/api/profiles/") {
		d.serveProfiles(w, r)
		return
	}
	switch {
	case r.Method == http.MethodPost && path == "/api/browser-consent":
		d.setBrowserConsent(w, r)
	case r.Method == http.MethodGet && path == "/api/status":
		consent := readBrowserConsent(d.browserPrefs)
		gui := d.gui
		if d.selectedReleaseFile != "" {
			gui.SelectedRelease = readSelectedRelease(d.selectedReleaseFile)
		}
		d.mu.Lock()
		response := struct {
			Data            json.RawMessage       `json:"data"`
			Updated         time.Time             `json:"updated"`
			Error           string                `json:"error,omitempty"`
			Origin          string                `json:"origin"`
			Fallback        bool                  `json:"fallback"`
			CanManage       bool                  `json:"canManage"`
			StatusVersion   uint64                `json:"statusVersion"`
			SnapshotVersion uint64                `json:"snapshotVersion"`
			GUI             guiBuildInfo          `json:"gui"`
			BrowserConsent  browserConsentSetting `json:"browserConsent"`
		}{d.status, d.lastStatus, d.lastError, d.origin, d.fallback, d.writes, d.statusVersion, d.snapshotVersion, gui, consent}
		d.mu.Unlock()
		respond(w, http.StatusOK, response)
	case r.Method == http.MethodGet && path == "/api/connections":
		respond(w, http.StatusOK, d.history.view())
	case r.Method == http.MethodPost && path == "/api/connections/clear":
		d.history.clear(time.Now())
		respond(w, http.StatusOK, map[string]bool{"cleared": true})
	case r.Method == http.MethodPost && path == "/api/dns/clear":
		d.history.clearDNS(time.Now())
		respond(w, http.StatusOK, map[string]bool{"cleared": true})
	case r.Method == http.MethodPost && path == "/api/actions":
		d.start(w, r)
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/api/jobs/"):
		d.mu.Lock()
		j, found := d.jobs[strings.TrimPrefix(path, "/api/jobs/")]
		d.mu.Unlock()
		if !found {
			problem(w, http.StatusNotFound, "任务不存在")
			return
		}
		respond(w, http.StatusOK, j)
	case r.Method == http.MethodPost && path == "/api/stop":
		d.mu.Lock()
		if d.busy {
			d.mu.Unlock()
			problem(w, http.StatusConflict, "等待当前操作结束后再停止控制台")
			return
		}
		d.busy = true // Reject new jobs during graceful shutdown.
		d.mu.Unlock()
		respond(w, http.StatusOK, map[string]bool{"stopped": true})
		d.cancel()
	default:
		http.NotFound(w, r)
	}
}

func bind(port int) (net.Listener, bool, error) {
	if port < 0 || port > 65535 {
		return nil, false, fmt.Errorf("端口超出范围")
	}
	lc := exclusiveListener()
	listener, err := lc.Listen(context.Background(), "tcp4", "127.0.0.1:"+strconv.Itoa(port))
	if err == nil || port == 0 {
		return listener, false, err
	}
	listener, fallback := lc.Listen(context.Background(), "tcp4", "127.0.0.1:0")
	if fallback != nil {
		return nil, false, fmt.Errorf("本机服务无法绑定端口 %d 或自动分配端口: %w", port, fallback)
	}
	return listener, true, nil
}

func parseResult(data []byte) (json.RawMessage, error) {
	data = bytes.TrimSpace(bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf}))
	var result struct {
		OK      bool   `json:"ok"`
		Message string `json:"message"`
	}
	if json.Unmarshal(data, &result) != nil {
		return nil, errors.New("管理组件没有返回有效结果")
	}
	if !result.OK {
		if result.Message == "" {
			result.Message = "操作失败"
		}
		return nil, errors.New(result.Message)
	}
	return data, nil
}
