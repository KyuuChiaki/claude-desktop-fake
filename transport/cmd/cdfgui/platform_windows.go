// Copyright (c) 2026 claude-desktop-fake contributors. MIT license.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"claude-desktop-fake/network-transport/internal/localpipe"
	"golang.org/x/sys/windows"
)

func exclusiveListener() net.ListenConfig {
	return net.ListenConfig{Control: func(_, _ string, raw syscall.RawConn) error {
		var sockErr error
		if err := raw.Control(func(fd uintptr) {
			const soExclusiveAddrUse = -5 // Winsock SO_EXCLUSIVEADDRUSE
			sockErr = windows.SetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, soExclusiveAddrUse, 1)
		}); err != nil {
			return err
		}
		return sockErr
	}}
}

func isAdmin() bool {
	sid, err := windows.CreateWellKnownSid(windows.WinBuiltinAdministratorsSid)
	if err != nil {
		return true
	}
	member, err := windows.Token(0).IsMember(sid)
	return member || err != nil
}

func restrictedToken() (windows.Token, error) {
	var input windows.Token
	access := uint32(windows.TOKEN_QUERY | windows.TOKEN_DUPLICATE | windows.TOKEN_ASSIGN_PRIMARY | windows.TOKEN_ADJUST_DEFAULT)
	if err := windows.OpenProcessToken(windows.CurrentProcess(), access, &input); err != nil {
		return 0, fmt.Errorf("open current token: %w", err)
	}
	defer input.Close()
	admins, err := windows.CreateWellKnownSid(windows.WinBuiltinAdministratorsSid)
	if err != nil {
		return 0, err
	}
	disable := windows.SIDAndAttributes{Sid: admins}
	var output windows.Token
	proc := windows.NewLazySystemDLL("advapi32.dll").NewProc("CreateRestrictedToken")
	const luaToken = 4
	ok, _, callErr := proc.Call(uintptr(input), luaToken, 1, uintptr(unsafe.Pointer(&disable)), 0, 0, 0, 0, uintptr(unsafe.Pointer(&output)))
	if ok == 0 {
		return 0, fmt.Errorf("restrict current token: %w", callErr)
	}
	integrity, err := windows.StringToSid("S-1-16-8192")
	if err == nil {
		label := windows.Tokenmandatorylabel{Label: windows.SIDAndAttributes{Sid: integrity, Attributes: windows.SE_GROUP_INTEGRITY}}
		err = windows.SetTokenInformation(output, windows.TokenIntegrityLevel, (*byte)(unsafe.Pointer(&label)), label.Size())
		runtime.KeepAlive(integrity)
	}
	if err == nil {
		err = setUserDefaultACL(output)
	}
	if err != nil {
		output.Close()
		return 0, fmt.Errorf("set medium integrity: %w", err)
	}
	return output, nil
}

func setUserDefaultACL(token windows.Token) error {
	user, err := token.GetTokenUser()
	if err != nil {
		return err
	}
	// The built-in Administrator can have a default DACL containing only the
	// Administrators group. Give the same user access to the restricted
	// child's newly created objects, such as its subprocess stdio pipes.
	descriptor, err := windows.SecurityDescriptorFromString("D:(A;;GA;;;SY)(A;;GA;;;" + user.User.Sid.String() + ")")
	if err != nil {
		return err
	}
	acl, _, err := descriptor.DACL()
	if err != nil {
		return err
	}
	err = windows.SetTokenInformation(token, windows.TokenDefaultDacl, (*byte)(unsafe.Pointer(&acl)), uint32(unsafe.Sizeof(acl)))
	runtime.KeepAlive(descriptor)
	return err
}

func processExited(id localpipe.Identity) bool {
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE, false, id.PID)
	if err != nil {
		return errors.Is(err, windows.ERROR_INVALID_PARAMETER)
	}
	defer windows.CloseHandle(handle)
	result, err := windows.WaitForSingleObject(handle, 0)
	if err == nil && result == windows.WAIT_OBJECT_0 {
		return true
	}
	var created, exit, kernel, user windows.Filetime
	return windows.GetProcessTimes(handle, &created, &exit, &kernel, &user) == nil &&
		uint64(created.HighDateTime)<<32|uint64(created.LowDateTime) != id.Created
}

func sameExecutable(pid uint32, exe string) bool {
	process, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(process)
	name := make([]uint16, 32768)
	size := uint32(len(name))
	return windows.QueryFullProcessImageName(process, 0, &name[0], &size) == nil &&
		strings.EqualFold(windows.UTF16ToString(name[:size]), exe)
}

type environment struct {
	exe          string
	root         string
	owner        localpipe.Identity
	adminChannel string
	adminPID     uint32
	adminGate    chan struct{}
}

func locate() (environment, error) {
	exe, err := os.Executable()
	if err != nil {
		return environment{}, err
	}
	exe, err = filepath.Abs(exe)
	if err != nil {
		return environment{}, err
	}
	bin := filepath.Dir(exe)
	root := filepath.Clean(filepath.Join(bin, "..", "..", "..", ".."))
	if !strings.EqualFold(bin, filepath.Join(root, "out", "build", "x64-release", "bin")) {
		return environment{}, errors.New("请从项目的 Release 输出目录运行控制台")
	}
	owner, err := localpipe.ProcessIdentity(uint32(os.Getpid()))
	return environment{exe: exe, root: root, owner: owner}, err
}

func (e environment) protectedPath() bool {
	programData, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, 0)
	if err != nil {
		return false
	}
	releases := filepath.Join(programData, "ClaudeDesktopFake", "gui", "releases")
	name := filepath.Base(e.root)
	key, err := hex.DecodeString(name)
	return err == nil && len(key) == 32 && strings.EqualFold(filepath.Dir(e.root), releases)
}

func (e environment) verifyRelease() error {
	if !e.protectedPath() {
		return errors.New("管理组件尚未安装")
	}
	manifest, err := os.ReadFile(filepath.Join(e.root, "gui-release.json"))
	if err != nil || len(manifest) > 16384 {
		return errors.New("管理组件清单无法读取")
	}
	sum := sha256.Sum256(manifest)
	if !strings.EqualFold(hex.EncodeToString(sum[:]), filepath.Base(e.root)) {
		return errors.New("管理组件清单已变更")
	}
	var records []struct {
		Path   string `json:"path"`
		SHA256 string `json:"sha256"`
	}
	if json.Unmarshal(manifest, &records) != nil || len(records) == 0 {
		return errors.New("管理组件清单无效")
	}
	for _, record := range records {
		name := filepath.Clean(record.Path)
		if !filepath.IsLocal(name) || name == "." || strings.ContainsAny(name, ":") {
			return errors.New("管理组件路径无效")
		}
		path := filepath.Join(e.root, name)
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() {
			return errors.New("管理组件文件缺失")
		}
		file, err := os.Open(path)
		if err != nil {
			return errors.New("管理组件文件无法读取")
		}
		hash := sha256.New()
		_, err = io.Copy(hash, file)
		file.Close()
		if err != nil || !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), record.SHA256) {
			return errors.New("管理组件文件已变更")
		}
	}
	return nil
}

func (e environment) script(ctx context.Context, data []byte, elevated, transaction bool) ([]byte, error) {
	programFiles, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFiles, 0)
	if err != nil {
		return nil, err
	}
	ps := filepath.Join(programFiles, "PowerShell", "7", "pwsh.exe")
	script := filepath.Join(e.root, "scripts", "Invoke-GuiAction.ps1")
	cmd := exec.CommandContext(ctx, ps, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", script)
	cmd.Dir = e.root
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
	cmd.Stdin = bytes.NewReader(data)
	cmd.Stderr = io.Discard
	if elevated {
		system, err := windows.GetSystemDirectory()
		if err != nil {
			return nil, err
		}
		psHome := filepath.Dir(ps)
		modules := []string{filepath.Join(psHome, "Modules"), filepath.Join(system, "WindowsPowerShell", "v1.0", "Modules")}
		cmd.Env = append(os.Environ(), "PSModulePath="+strings.Join(modules, ";"), "PATH="+system+";"+psHome)
	}
	if transaction {
		// Once a transaction begins, let its own deadline and rollback finish.
		cmd.Cancel = nil
		cmd.WaitDelay = 0
	}
	output, err := cmd.Output()
	if err != nil {
		if ctx.Err() != nil {
			return nil, errors.New("管理操作超时，刷新页面查看结果")
		}
		return nil, fmt.Errorf("无法运行 PowerShell 管理组件 (%v)", err)
	}
	if len(bytes.TrimSpace(output)) == 0 {
		return nil, errors.New("PowerShell 管理组件没有输出")
	}
	return output, nil
}

func (e environment) execute(ctx context.Context, a action, phase func(string)) (json.RawMessage, error) {
	data, err := json.Marshal(a)
	if err != nil {
		return nil, err
	}
	defer clear(data)
	var output []byte
	if e.adminChannel != "" && (a.privilege() || a.Action == "status" || a.Action == "check") {
		phase("manager")
		select {
		case e.adminGate <- struct{}{}:
			defer func() { <-e.adminGate }()
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		expected := e.ownerForPeer()
		expected.PID = e.adminPID
		phase("executing")
		output, err = localpipe.Exchange(ctx, localpipe.Name(e.owner.Logon, "supervisor."+e.adminChannel), expected, data)
	} else if a.privilege() {
		output, err = e.elevated(ctx, data, phase)
	} else {
		phase("executing")
		output, err = e.script(ctx, data, false, false)
	}
	if err != nil {
		return nil, err
	}
	return parseResult(output)
}

type shellExecuteInfo struct {
	Size       uint32
	Mask       uint32
	Window     windows.Handle
	Verb       *uint16
	File       *uint16
	Parameters *uint16
	Directory  *uint16
	Show       int32
	Instance   windows.Handle
	IDList     uintptr
	Class      *uint16
	KeyClass   windows.Handle
	HotKey     uint32
	Icon       windows.Handle
	Process    windows.Handle
}

func utf16(s string) *uint16 {
	p, _ := windows.UTF16PtrFromString(s)
	return p
}

func (e environment) elevated(ctx context.Context, data []byte, phase func(string)) ([]byte, error) {
	if !e.protectedPath() {
		return nil, errors.New("请安装管理组件")
	}
	channel, err := token()
	if err != nil {
		return nil, err
	}
	server, err := localpipe.Listen(localpipe.Name(e.owner.Logon, "manager."+channel), e.owner)
	if err != nil {
		return nil, err
	}
	defer server.Close()
	parameters := fmt.Sprintf("-mode worker -channel %s -parent %d", channel, e.owner.PID)
	info := shellExecuteInfo{Mask: 0x40 | 0x100 | 0x400, Verb: utf16("runas"), File: utf16(e.exe),
		Parameters: utf16(parameters), Directory: utf16(e.root), Show: 0}
	info.Size = uint32(unsafe.Sizeof(info))
	proc := windows.NewLazySystemDLL("shell32.dll").NewProc("ShellExecuteExW")
	phase("authorization")
	ok, _, callErr := proc.Call(uintptr(unsafe.Pointer(&info)))
	if ok == 0 || info.Process == 0 {
		if errors.Is(callErr, windows.ERROR_CANCELLED) {
			return nil, errors.New("已取消管理员授权")
		}
		return nil, fmt.Errorf("无法启动管理员管理进程 (%v)", callErr)
	}
	defer windows.CloseHandle(info.Process)
	phase("manager")
	pid, err := windows.GetProcessId(info.Process)
	if err != nil {
		return nil, err
	}
	wait, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	var output []byte
	var resultErr error
	err = server.Accept(wait, func(conn *localpipe.Conn, peer localpipe.Identity) {
		if peer.PID != pid || !sameExecutable(peer.PID, e.exe) {
			resultErr = errors.New("管理进程身份不匹配")
			return
		}
		if resultErr = conn.Write(ctx, data); resultErr == nil {
			phase("executing")
			output, resultErr = conn.Read(ctx)
		}
		if resultErr == nil {
			_ = conn.Write(ctx, []byte{1})
		}
	})
	if err != nil {
		return nil, errors.New("管理员进程未连接。请使用同一 Windows 帐户授权")
	}
	return output, resultErr
}

func (e environment) worker(channel string, parent uint32) error {
	key, err := hex.DecodeString(channel)
	if err != nil || len(key) != 24 || parent == 0 || !isAdmin() || !e.protectedPath() {
		return errors.New("管理进程启动参数无效")
	}
	if err := e.verifyRelease(); err != nil {
		return err
	}
	expected := e.owner
	expected.PID, expected.Created = parent, 0
	conn, err := localpipe.Dial(localpipe.Name(e.owner.Logon, "manager."+channel), expected)
	if err != nil {
		return err
	}
	defer conn.Close()
	if !sameExecutable(conn.Peer.PID, e.exe) {
		return errors.New("管理请求来源不匹配")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Minute)
	defer cancel()
	data, err := conn.Read(ctx)
	if err != nil {
		return err
	}
	defer clear(data)
	output := e.runPrivileged(ctx, data, false)
	if err := conn.Write(ctx, output); err != nil {
		return err
	}
	_, err = conn.Read(ctx)
	return err
}

func (e environment) runPrivileged(ctx context.Context, data []byte, inspect bool) []byte {
	var a action
	if len(data) > 8192 || json.Unmarshal(data, &a) != nil || a.validate() != nil ||
		(!a.privilege() && !(inspect && (a.Action == "status" || a.Action == "check"))) {
		return []byte(`{"ok":false,"message":"管理请求无效"}`)
	}
	if !a.privilege() {
		deadline, cancel := context.WithTimeout(ctx, 19*time.Second)
		defer cancel()
		ctx = deadline
	}
	output, err := e.script(ctx, data, true, a.privilege())
	if err != nil {
		output, _ = json.Marshal(map[string]any{"ok": false, "message": err.Error()})
	}
	return output
}

// When launched from an already elevated terminal, the local worker keeps
// that token and starts the HTTP process with a restricted token. Only the
// exact child created here can submit one of the fixed management requests.
func (e environment) supervise(port int) error {
	if !isAdmin() {
		return errors.New("管理进程需要管理员权限")
	}
	if err := e.verifyRelease(); err != nil {
		return err
	}
	channel, err := token()
	if err != nil {
		return err
	}
	server, err := localpipe.Listen(localpipe.Name(e.owner.Logon, "supervisor."+channel), e.owner)
	if err != nil {
		return err
	}
	defer server.Close()
	restricted, err := restrictedToken()
	if err != nil {
		return err
	}
	defer restricted.Close()
	cmd := exec.Command(e.exe, "-mode", "serve", "-port", strconv.Itoa(port),
		"-channel", channel, "-parent", strconv.Itoa(int(e.owner.PID)))
	cmd.Dir = e.root
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(restricted), HideWindow: true, CreationFlags: windows.DETACHED_PROCESS}
	if err = cmd.Start(); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stopped := make(chan error, 1)
	go func() {
		stopped <- cmd.Wait()
		cancel()
	}()
	for ctx.Err() == nil {
		err := server.Accept(ctx, func(conn *localpipe.Conn, peer localpipe.Identity) {
			if peer.PID != uint32(cmd.Process.Pid) || !sameExecutable(peer.PID, e.exe) {
				notice, cancel := context.WithTimeout(ctx, time.Second)
				defer cancel()
				_ = conn.Write(notice, []byte(`{"ok":false,"message":"控制台进程身份不匹配"}`))
				_, _ = conn.Read(notice)
				return
			}
			readCtx, cancelRead := context.WithTimeout(ctx, 2*time.Second)
			data, err := conn.Read(readCtx)
			cancelRead()
			if err != nil {
				return
			}
			defer clear(data)
			jobCtx, cancelJob := context.WithTimeout(ctx, 6*time.Minute)
			defer cancelJob()
			response := e.runPrivileged(jobCtx, data, true)
			if conn.Write(jobCtx, response) == nil {
				_, _ = conn.Read(jobCtx)
			}
		})
		if err != nil && ctx.Err() == nil {
			time.Sleep(50 * time.Millisecond)
		}
	}
	return <-stopped
}

type launchResult struct {
	Origin    string `json:"origin"`
	TicketURL string `json:"ticketUrl,omitempty"`
	Fallback  bool   `json:"fallback"`
	Error     string `json:"error,omitempty"`
}

func (e environment) launchRequest() (launchResult, error) {
	conn, err := localpipe.Dial(localpipe.Name(e.owner.Logon, "console"), e.ownerForPeer())
	if err != nil {
		return launchResult{}, err
	}
	defer conn.Close()
	if !sameExecutable(conn.Peer.PID, e.exe) {
		return launchResult{}, errors.New("已有另一个版本的控制台，请先停止它")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := conn.Write(ctx, []byte("ticket")); err != nil {
		return launchResult{}, err
	}
	data, err := conn.Read(ctx)
	if err != nil {
		return launchResult{}, err
	}
	_ = conn.Write(ctx, []byte{1})
	var result launchResult
	if err := json.Unmarshal(data, &result); err != nil {
		return result, err
	}
	return result, nil
}

func (e environment) ownerForPeer() localpipe.Identity {
	return localpipe.Identity{User: e.owner.User, Logon: e.owner.Logon}
}

func (e environment) launch(port int, open bool) error {
	result, err := e.launchRequest()
	if err != nil {
		if !errors.Is(err, windows.ERROR_FILE_NOT_FOUND) && !errors.Is(err, windows.ERROR_PIPE_BUSY) {
			return err
		}
		var restricted windows.Token
		mode := "serve"
		if isAdmin() && e.protectedPath() {
			mode = "supervise"
		} else if isAdmin() {
			restricted, err = restrictedToken()
			if err != nil {
				return fmt.Errorf("无法创建受限控制台进程: %w", err)
			}
			defer restricted.Close()
		}
		cmd := exec.Command(e.exe, "-mode", mode, "-port", strconv.Itoa(port))
		cmd.Dir = e.root
		cmd.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(restricted), HideWindow: true, CreationFlags: windows.DETACHED_PROCESS}
		diagnostic, err := cmd.StderrPipe()
		if err != nil {
			return err
		}
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("无法启动控制台服务: %w", err)
		}
		exited := make(chan string, 1)
		go func() {
			data, _ := io.ReadAll(io.LimitReader(diagnostic, 4096))
			waitErr := cmd.Wait()
			message := strings.TrimSpace(string(data))
			if message == "" {
				message = fmt.Sprintf("子进程退出 (%v)", waitErr)
			}
			exited <- message
		}()
		startErr := ""
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			time.Sleep(100 * time.Millisecond)
			result, err = e.launchRequest()
			if err == nil {
				break
			}
			select {
			case startErr = <-exited:
				deadline = time.Now()
			default:
			}
		}
		if err != nil {
			if startErr != "" {
				return fmt.Errorf("控制台服务启动失败: %s", startErr)
			}
			return fmt.Errorf("控制台服务启动失败: %w", err)
		}
	}
	if result.Error != "" {
		return errors.New(result.Error)
	}
	if open {
		address, err := url.Parse(result.TicketURL)
		if err != nil || address.Scheme != "http" || address.Hostname() != "127.0.0.1" || address.Port() == "" ||
			address.Path != "/" || address.RawQuery != "" || address.User != nil || !strings.HasPrefix(address.Fragment, "ticket=") ||
			result.Origin != "http://"+address.Host {
			return errors.New("本机控制台地址无效")
		}
		// Open the default association from the interactive launcher. The
		// detached server keeps its restricted token and never opens windows.
		if err := windows.ShellExecute(0, utf16("open"), utf16(address.String()), nil, nil, windows.SW_SHOWNORMAL); err != nil {
			return fmt.Errorf("无法打开默认浏览器，请使用 -NoBrowser 获取本地地址: %w", err)
		}
		result.TicketURL = ""
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}

func readSelectedRelease(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 4097))
	var record struct {
		SchemaVersion int    `json:"schemaVersion"`
		Release       string `json:"release"`
	}
	if err != nil || len(data) > 4096 || json.Unmarshal(data, &record) != nil || record.SchemaVersion != 1 {
		return ""
	}
	key, err := hex.DecodeString(record.Release)
	if err != nil || len(key) != sha256.Size {
		return ""
	}
	return strings.ToUpper(record.Release)
}

func (e environment) serve(port int) error {
	if isAdmin() {
		return errors.New("控制台 HTTP 服务需要受限权限")
	}
	listener, fallback, err := bind(port)
	if err != nil {
		return err
	}
	defer listener.Close()
	control, err := localpipe.Listen(localpipe.Name(e.owner.Logon, "console"), e.owner)
	if err != nil {
		return fmt.Errorf("本机控制管道: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d := newDashboard(ctx, cancel, listener, fallback, e.protectedPath(), e.execute)
	local, err := windows.KnownFolderPath(windows.FOLDERID_LocalAppData, 0)
	if err != nil {
		return err
	}
	shared, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, 0)
	if err != nil {
		return err
	}
	d.profiles = &profileStore{
		file:       filepath.Join(local, "ClaudeDesktopFake", "gui", "proxy-profiles.dpapi"),
		activeFile: filepath.Join(shared, "ClaudeDesktopFake", "network", "active.dpapi"),
	}
	// Hash once at startup. The release selection can change while the same
	// console keeps serving its embedded assets and in-memory history.
	exe, err := os.Open(e.exe)
	if err != nil {
		return err
	}
	digest := sha256.New()
	_, err = io.Copy(digest, exe)
	exe.Close()
	if err != nil {
		return err
	}
	d.gui.Build = strings.ToUpper(hex.EncodeToString(digest.Sum(nil)))
	if d.writes {
		d.gui.RunningRelease = strings.ToUpper(filepath.Base(e.root))
		d.selectedReleaseFile = filepath.Join(filepath.Dir(filepath.Dir(e.root)), "current.json")
	}
	server := &http.Server{Handler: d, ReadHeaderTimeout: 4 * time.Second, ReadTimeout: 6 * time.Second,
		WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	go d.update()
	go d.pollConnections(e.owner)
	go control.Serve(ctx, func(data []byte, peer localpipe.Identity) []byte {
		if !sameExecutable(peer.PID, e.exe) || string(data) != "ticket" {
			return nil
		}
		result := launchResult{Origin: d.origin, Fallback: fallback}
		if address, err := d.ticket(); err != nil {
			result.Error = err.Error()
		} else {
			result.TicketURL = address
		}
		value, _ := json.Marshal(result)
		return value
	})
	stopped := make(chan struct{})
	go func() {
		<-ctx.Done()
		grace, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		_ = server.Shutdown(grace)
		close(stopped)
	}()
	err = server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		<-stopped
		return nil
	}
	return err
}

func main() {
	mode := flag.String("mode", "launch", "")
	port := flag.Int("port", 17862, "")
	noBrowser := flag.Bool("no-browser", false, "")
	channel := flag.String("channel", "", "")
	parent := flag.Uint("parent", 0, "")
	flag.Parse()
	env, err := locate()
	if err == nil {
		switch *mode {
		case "launch":
			err = env.launch(*port, !*noBrowser)
		case "serve":
			if data, parseErr := hex.DecodeString(*channel); parseErr == nil && len(data) == 24 && *parent != 0 && env.protectedPath() {
				env.adminChannel, env.adminPID = *channel, uint32(*parent)
				env.adminGate = make(chan struct{}, 1)
			}
			err = env.serve(*port)
		case "supervise":
			err = env.supervise(*port)
		case "worker":
			err = env.worker(*channel, uint32(*parent))
		default:
			err = errors.New("未知控制台启动方式")
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
