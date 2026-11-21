package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"go.yaml.in/yaml/v3"
)

const maxProfileYAML = 1 << 20

type namedProfile struct {
	ID     string      `json:"id"`
	Name   string      `json:"name"`
	Values proxyValues `json:"values"`
}

type profileBook struct {
	Version   int            `json:"version"`
	Entries   []namedProfile `json:"profiles"`
	Preferred string         `json:"preferred,omitempty"`
	active    string
	virtual   bool
	warning   string
}

type profileSummary struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Server string `json:"server"`
	Port   int    `json:"port"`
}

type profileList struct {
	Profiles []profileSummary `json:"profiles"`
	ActiveID string           `json:"activeId"`
	Selected string           `json:"selected,omitempty"`
	Imported int              `json:"imported,omitempty"`
	Skipped  int              `json:"skipped,omitempty"`
	Warning  string           `json:"warning,omitempty"`
}

func (b *profileBook) list() profileList {
	v := profileList{Profiles: make([]profileSummary, 0, len(b.Entries)), ActiveID: b.active, Warning: b.warning}
	for _, p := range b.Entries {
		v.Profiles = append(v.Profiles, profileSummary{p.ID, p.Name, p.Values.Server, p.Values.Port})
	}
	return v
}

func (b *profileBook) find(id string) *namedProfile {
	for i := range b.Entries {
		if b.Entries[i].ID == id {
			return &b.Entries[i]
		}
	}
	return nil
}

func (b *profileBook) nameTaken(name, except string) bool {
	for _, p := range b.Entries {
		if p.ID != except && strings.EqualFold(name, p.Name) {
			return true
		}
	}
	return false
}

func validName(s string) (string, error) {
	s = strings.TrimSpace(s)
	if s == "" || utf8.RuneCountInString(s) > 80 || strings.IndexFunc(s, unicode.IsControl) >= 0 {
		return "", errors.New("名称须为 1 至 80 个可显示字符")
	}
	return s, nil
}

var uuidPattern = regexp.MustCompile(`(?i)^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)
var sniPattern = regexp.MustCompile(`(?i)^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}$`)
var keyPattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{43}$`)

func (v *proxyValues) normalize() error {
	ip, err := netip.ParseAddr(v.Server)
	if err != nil || !ip.Is4() || v.Port < 1 || v.Port > 65535 {
		return errors.New("需要有效的服务器 IPv4 和 1 至 65535 的端口")
	}
	if !uuidPattern.MatchString(v.UUID) || v.UUID == "00000000-0000-0000-0000-000000000000" {
		return errors.New("VLESS UUID 无效")
	}
	if !sniPattern.MatchString(v.ServerName) || len(v.ServerName) > 253 || !keyPattern.MatchString(v.PublicKey) {
		return errors.New("SNI 或 REALITY 公钥无效")
	}
	if _, err := hex.DecodeString(v.ShortID); err != nil || len(v.ShortID) > 16 {
		return errors.New("Short ID 须为空或最多 16 位偶数个十六进制字符")
	}
	v.Server, v.UUID, v.ServerName, v.ShortID = ip.String(), strings.ToLower(v.UUID), strings.ToLower(v.ServerName), strings.ToLower(v.ShortID)
	return nil
}

// The deployed transport keeps its existing credential schema. Names and IDs
// only belong to the console's per-user catalog.
type clashProfile struct {
	Name        string      `yaml:"name" json:"name"`
	Type        string      `yaml:"type" json:"type"`
	Server      string      `yaml:"server" json:"server"`
	Port        json.Number `yaml:"port" json:"port"`
	UUID        string      `yaml:"uuid" json:"uuid"`
	SNI         string      `yaml:"servername" json:"servername"`
	Network     string      `yaml:"network" json:"network"`
	Flow        string      `yaml:"flow" json:"flow"`
	TLS         *bool       `yaml:"tls" json:"tls"`
	Fingerprint string      `yaml:"client-fingerprint" json:"client-fingerprint"`
	Reality     struct {
		Key string `yaml:"public-key" json:"public-key"`
		ID  string `yaml:"short-id" json:"short-id"`
	} `yaml:"reality-opts" json:"reality-opts"`
}

func (c clashProfile) supported() bool {
	return c.Type == "vless" && (c.Network == "" || c.Network == "tcp") && c.Flow == "xtls-rprx-vision" &&
		(c.TLS == nil || *c.TLS) && c.Reality.Key != "" && (c.Fingerprint == "" || c.Fingerprint == "chrome")
}

func (c clashProfile) values() (proxyValues, error) {
	port, _ := strconv.Atoi(c.Port.String())
	v := proxyValues{Server: c.Server, Port: port, UUID: c.UUID, ServerName: c.SNI, PublicKey: c.Reality.Key, ShortID: c.Reality.ID}
	err := v.normalize()
	return v, err
}

func parseProfilesYAML(raw []byte) ([]namedProfile, int, error) {
	if len(raw) == 0 || len(raw) > maxProfileYAML {
		return nil, 0, errors.New("请选择一个不超过 1 MiB 的 YAML 文件")
	}
	dec := yaml.NewDecoder(bytes.NewReader(raw))
	var doc, extra yaml.Node
	if dec.Decode(&doc) != nil || len(doc.Content) != 1 || dec.Decode(&extra) != io.EOF {
		return nil, 0, errors.New("需要一个完整的 YAML 文档")
	}
	root := doc.Content[0]
	var nodes []*yaml.Node
	var globalFingerprint string
	switch root.Kind {
	case yaml.SequenceNode:
		nodes = root.Content
	case yaml.MappingNode:
		var header struct {
			Proxies     yaml.Node `yaml:"proxies"`
			Fingerprint string    `yaml:"global-client-fingerprint"`
		}
		if root.Decode(&header) != nil {
			return nil, 0, errors.New("YAML 映射无效或包含重复字段")
		}
		globalFingerprint = header.Fingerprint
		switch header.Proxies.Kind {
		case 0:
			nodes = []*yaml.Node{root}
		case yaml.SequenceNode:
			nodes = header.Proxies.Content
		default:
			return nil, 0, errors.New("proxies 必须是节点列表")
		}
	default:
		return nil, 0, errors.New("请选择节点或带有 proxies 列表的 YAML")
	}
	var entries []namedProfile
	skipped := 0
	for i, node := range nodes {
		var kind struct {
			Type string `yaml:"type"`
		}
		if node.Decode(&kind) != nil || kind.Type == "" {
			return nil, 0, fmt.Errorf("第 %d 个节点缺少有效的 type，未导入", i+1)
		}
		if kind.Type != "vless" {
			skipped++
			continue
		}
		var c clashProfile
		if node.Decode(&c) != nil {
			return nil, 0, fmt.Errorf("第 %d 个节点的字段格式无效", i+1)
		}
		if c.Fingerprint == "" {
			c.Fingerprint = globalFingerprint
		}
		if !c.supported() {
			skipped++
			continue
		}
		name, err := validName(c.Name)
		if err != nil {
			return nil, 0, fmt.Errorf("第 %d 个节点：%w", i+1, err)
		}
		values, err := c.values()
		if err != nil {
			return nil, 0, fmt.Errorf("第 %d 个节点：%w", i+1, err)
		}
		entries = append(entries, namedProfile{Name: name, Values: values})
	}
	if len(entries) == 0 {
		return nil, skipped, errors.New("没有可导入的 VLESS / TCP / REALITY / Vision 节点")
	}
	return entries, skipped, nil
}

func (b *profileBook) includeDeployed(v proxyValues) {
	for _, p := range b.Entries {
		if p.Values == v && (b.active == "" || p.ID == b.Preferred) {
			b.active = p.ID
		}
	}
	if b.active != "" {
		return
	}
	base := "默认代理"
	name := base
	for n := 2; b.nameTaken(name, ""); n++ {
		name = fmt.Sprintf("%s (%d)", base, n)
	}
	raw, _ := json.Marshal(v)
	sum := sha256.Sum256(raw)
	clear(raw)
	b.active = "deployed-" + hex.EncodeToString(sum[:])
	b.Entries = append(b.Entries, namedProfile{ID: b.active, Name: name, Values: v})
	b.virtual = true
}

func (d *dashboard) serveProfiles(w http.ResponseWriter, r *http.Request) {
	if d.profiles == nil {
		problem(w, 503, "代理配置列表不可用")
		return
	}
	if r.Method == http.MethodGet && r.URL.Path == "/api/profiles" {
		book, err := d.profiles.load()
		if err != nil {
			problem(w, 409, err.Error())
			return
		}
		respond(w, 200, book.list())
		return
	}
	if r.Method != http.MethodPost {
		problem(w, 405, "请求方法不受支持")
		return
	}
	if !d.writes {
		problem(w, 403, "当前控制台为只读模式")
		return
	}
	var entries []namedProfile
	var rename struct{ ID, Name, PreviousName string }
	var err error
	skipped := 0
	switch r.URL.Path {
	case "/api/profiles":
		var p struct {
			Name   string
			Values proxyValues
		}
		if err = readJSON(w, r, &p); err == nil {
			p.Name, err = validName(p.Name)
		}
		if err == nil {
			err = p.Values.normalize()
		}
		entries = []namedProfile{{Name: p.Name, Values: p.Values}}
	case "/api/profiles/import":
		if kind, _, _ := strings.Cut(r.Header.Get("Content-Type"), ";"); kind != "application/yaml" {
			problem(w, 415, "需要 YAML 文件")
			return
		}
		raw, readErr := io.ReadAll(http.MaxBytesReader(w, r.Body, maxProfileYAML))
		defer clear(raw)
		if readErr != nil {
			problem(w, 413, "文件超过 1 MiB 或读取失败")
			return
		}
		entries, skipped, err = parseProfilesYAML(raw)
	case "/api/profiles/rename":
		if err = readJSON(w, r, &rename); err == nil {
			rename.Name, err = validName(rename.Name)
		}
		if err == nil && rename.ID == "" {
			err = errors.New("请选择要重命名的配置")
		}
	default:
		http.NotFound(w, r)
		return
	}
	if err != nil {
		problem(w, 400, err.Error())
		return
	}
	var selected string
	book, err := d.profiles.change(func(b *profileBook) error {
		if rename.ID != "" {
			p := b.find(rename.ID)
			if p == nil || p.Name != rename.PreviousName {
				return errors.New("配置名称已经变化，请重新选择")
			}
			if b.nameTaken(rename.Name, p.ID) {
				return fmt.Errorf("配置名称 %q 已存在（忽略大小写）", rename.Name)
			}
			p.Name, selected = rename.Name, p.ID
			return nil
		}
		for _, p := range entries {
			if b.nameTaken(p.Name, "") {
				return fmt.Errorf("配置名称 %q 已存在（忽略大小写），本次未写入", p.Name)
			}
			id, err := token()
			if err != nil {
				return errors.New("无法生成配置编号")
			}
			p.ID = id
			b.Entries = append(b.Entries, p)
			if selected == "" {
				selected = id
			}
		}
		return nil
	})
	if err != nil {
		problem(w, 409, err.Error())
		return
	}
	view := book.list()
	view.Selected, view.Imported, view.Skipped = selected, len(entries), skipped
	respond(w, 200, view)
}
