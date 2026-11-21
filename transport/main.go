// Copyright (c) 2026 claude-desktop-fake contributors. MIT license.
package main

/*
#cgo CFLAGS: -I../include
#include "network_transport_abi.h"
static CdfNetworkHostApi cdf_host;
static void cdf_set_host(const CdfNetworkHostApi* h) { cdf_host = *h; }
static int cdf_authorize(uintptr_t s, uint32_t k) { return cdf_host.authorize_socket ? cdf_host.authorize_socket(s,k) : 0; }
static int64_t cdf_clock(void) { return cdf_host.real_utc_ticks ? cdf_host.real_utc_ticks() : 0; }
static int cdf_configure(const uint8_t* a, uint16_t p) { return cdf_host.configure_upstream ? cdf_host.configure_upstream(a,p) : 0; }
*/
import "C"

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/xtls/xray-core/app/dispatcher"
	"github.com/xtls/xray-core/app/proxyman"
	_ "github.com/xtls/xray-core/app/proxyman/inbound"
	_ "github.com/xtls/xray-core/app/proxyman/outbound"
	xlog "github.com/xtls/xray-core/common/log"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/proxy/vless"
	vlessout "github.com/xtls/xray-core/proxy/vless/outbound"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/reality"
	_ "github.com/xtls/xray-core/transport/internet/tagged/taggedimpl"
	_ "github.com/xtls/xray-core/transport/internet/tcp"
	"golang.org/x/sys/windows"
	"golang.org/x/crypto/x509roots/fallback/bundle"
)

const denied = 10013
const refused = 10061
const timedOut = 10060
const unavailable = 10050

type silentLog struct{}
func (silentLog) Handle(xlog.Message) {}

type privateProfile struct {
	Type        string `json:"type"`
	Server      string `json:"server"`
	Port        uint16 `json:"port"`
	UUID        string `json:"uuid"`
	SNI         string `json:"servername"`
	Fingerprint string `json:"client-fingerprint"`
	Flow        string `json:"flow"`
	Network     string `json:"network"`
	Reality     struct {
		PublicKey string `json:"public-key"`
		ShortID   string `json:"short-id"`
	} `json:"reality-opts"`
}
type privateDialer struct {
	server net.IP
	port   uint16
	local  net.IP
	index  int
}

func (d *privateDialer) DestIpAddress() xnet.IP { return d.server }
func (d *privateDialer) Dial(ctx context.Context, _ xnet.Address, destination xnet.Destination, _ *internet.SocketConfig) (net.Conn, error) {
	if destination.Network != xnet.Network_TCP || !destination.Address.Family().IsIP() ||
		!net.IP(destination.Address.IP()).Equal(d.server) || uint16(destination.Port) != d.port {
		return nil, errors.New("restricted outbound")
	}
	dialer := net.Dialer{Timeout: 10 * time.Second, LocalAddr: &net.TCPAddr{IP: d.local},
		Control: func(network, address string, raw syscall.RawConn) error {
			var failure error
			err := raw.Control(func(fd uintptr) {
				if C.cdf_authorize(C.uintptr_t(fd), 1) == 0 {
					failure = errors.New("outbound authorization rejected")
					return
				}
				// IP_UNICAST_IF expects the interface index in network byte order.
				i := uint32(d.index)
				be := (i >> 24) | ((i >> 8) & 0xff00) | ((i << 8) & 0xff0000) | (i << 24)
				failure = windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IP, 31, int(be))
			})
			if err != nil {
				return err
			}
			return failure
		}}
	return dialer.DialContext(ctx, "tcp4", net.JoinHostPort(d.server.String(), strconv.Itoa(int(d.port))))
}

type tunnelConn struct {
	net.Conn
	cancel context.CancelFunc
	once sync.Once
	closeError error
}

func (c *tunnelConn) Close() error { c.once.Do(func(){c.cancel();c.closeError=c.Conn.Close()});return c.closeError }
func (c *tunnelConn) CloseWrite() error {if stream,ok:=c.Conn.(interface{CloseWrite()error});ok{return stream.CloseWrite()};return errors.New("half close unavailable")}

type reservation struct {
	conn    net.Conn
	client net.Conn
	localIP net.IP
	expires *time.Timer
	record uint64
	blockWebRTC bool
}
type bridgeKey struct {
	family uint32
	port   uint16
}

var state struct {
	sync.Mutex
	instance             *core.Instance
	listener4           net.Listener
	pending              map[bridgeKey]*reservation
	sessions map[bridgeKey]*reservation
	opening map[bridgeKey]context.CancelFunc
	client               *http.Client
	active               map[net.Conn]bool
	stopped              bool
	stopTelemetry        context.CancelFunc
	protectionPath       string
}

func realNow() time.Time {
	ticks := int64(C.cdf_clock())
	if ticks <= 116444736000000000 {
		return time.Now()
	}
	return time.Unix(0, (ticks-116444736000000000)*100)
}
func privateRoots()(*x509.CertPool,error){
    pool:=x509.NewCertPool()
    for root:=range bundle.Roots(){certificate,err:=x509.ParseCertificate(root.Certificate);if err!=nil{return nil,err};if root.Constraint==nil{pool.AddCert(certificate)}else{pool.AddCertWithConstraint(certificate,root.Constraint)}}
    return pool,nil
}
func plaintextProfile(path string) (privateProfile, error) {
	var p privateProfile
	sealed, err := os.ReadFile(path)
	if err != nil {
		return p, err
	}
	if len(sealed) == 0 || len(sealed) > 65536 {
		return p, errors.New("profile length")
	}
	input := windows.DataBlob{Size: uint32(len(sealed)), Data: &sealed[0]}
	var output windows.DataBlob
	if err = windows.CryptUnprotectData(&input, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &output); err != nil {
		return p, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(output.Data)))
	plain := unsafe.Slice(output.Data, int(output.Size))
	defer clear(plain)
	decoder := json.NewDecoder(bytes.NewReader(plain))
	decoder.DisallowUnknownFields()
	err = decoder.Decode(&p)
	return p, err
}
func makeInstance(p privateProfile) (*core.Instance, error) {
	publicKey, err := base64.RawURLEncoding.DecodeString(p.Reality.PublicKey)
	if err != nil || len(publicKey) != 32 {
		return nil, errors.New("public key")
	}
	short, err := hex.DecodeString(p.Reality.ShortID)
	if err != nil || len(short) > 8 {
		return nil, errors.New("short id")
	}
	shortID := make([]byte, 8)
	copy(shortID, short)
	security := &reality.Config{Fingerprint: p.Fingerprint, ServerName: p.SNI, PublicKey: publicKey, ShortId: shortID}
	outbound := &vlessout.Config{Vnext: &protocol.ServerEndpoint{Address: xnet.NewIPOrDomain(xnet.ParseAddress(p.Server)), Port: uint32(p.Port), User: &protocol.User{Account: serial.ToTypedMessage(&vless.Account{Id: p.UUID, Flow: p.Flow, Encryption: "none"})}}}
	config := &core.Config{App: []*serial.TypedMessage{serial.ToTypedMessage(&dispatcher.Config{}), serial.ToTypedMessage(&proxyman.InboundConfig{}), serial.ToTypedMessage(&proxyman.OutboundConfig{})},
		Outbound: []*core.OutboundHandlerConfig{{Tag: "private-only", ProxySettings: serial.ToTypedMessage(outbound), SenderSettings: serial.ToTypedMessage(&proxyman.SenderConfig{StreamSettings: &internet.StreamConfig{ProtocolName: "tcp", SecurityType: serial.GetMessageType(security), SecuritySettings: []*serial.TypedMessage{serial.ToTypedMessage(security)}}})}}}
	return core.New(config)
}
func openTunnel(ctx context.Context, host string, port uint16) (net.Conn, error) {
	state.Lock()
	instance := state.instance
	stopped := state.stopped
	state.Unlock()
	if instance == nil || stopped {
		return nil, errors.New("transport unavailable")
	}
	ctx, cancel := context.WithCancel(ctx)
	ready := make(chan error, 1)
	ctx = context.WithValue(ctx, reality.CdfHandshakeKey{}, ready)
	conn, err := core.Dial(ctx, instance, xnet.TCPDestination(xnet.ParseAddress(host), xnet.Port(port)))
	if err != nil {
		cancel()
		return nil, err
	}
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
	select {
	case err = <-ready:
	case <-timer.C:
		err = context.DeadlineExceeded
	case <-ctx.Done():
		err = ctx.Err()
	}
	if err != nil {
		cancel()
		conn.Close()
		return nil, err
	}
	return &tunnelConn{Conn: conn, cancel: cancel}, nil
}
func privateListener(network, address string) (net.Listener, error) {
	lc := net.ListenConfig{Control: func(_, _ string, raw syscall.RawConn) error {
		var failure error
		err := raw.Control(func(fd uintptr) {
			if C.cdf_authorize(C.uintptr_t(fd), 2) == 0 {
				failure = errors.New("bridge authorization rejected")
			}
		})
		if err != nil {
			return err
		}
		return failure
	}}
	return lc.Listen(context.Background(), network, address)
}
func runBridge(listener net.Listener, family uint32) {
	for {
		client, err := listener.Accept()
		if err != nil {
			return
		}
		port := uint16(client.RemoteAddr().(*net.TCPAddr).Port)
		key := bridgeKey{family, port}
		state.Lock()
		item := state.pending[key]
		state.Unlock()
		if item==nil||!client.RemoteAddr().(*net.TCPAddr).IP.Equal(item.localIP)||!sameProcessPeer(client){client.Close();continue}
		state.Lock()
		if state.pending[key]!=item{state.Unlock();client.Close();continue}
		delete(state.pending, key)
		if item != nil {
			item.expires.Stop()
			item.client=client
			state.active[client] = true
			state.active[item.conn] = true
			connections.Activate(item.record, realNow())
		}
		state.Unlock()
		if item == nil {
			client.Close()
			continue
		}
		go func() {
			reason := "finished"
			defer func() {
				client.Close()
				item.conn.Close()
				connections.Finish(item.record, reason, realNow())
				state.Lock()
				delete(state.active, client)
				delete(state.active, item.conn)
				if state.sessions[key]==item{delete(state.sessions,key)}
				state.Unlock()
			}()
			done := make(chan error,2)
			go func() {
				reader := &clientHelloReader{
					Reader: client, blockWebRTC: item.blockWebRTC,
					onName: func(name string) { connections.SetServerName(item.record, name) },
				}
				_, err := io.Copy(item.conn, reader)
				if err==nil{if c,ok:=item.conn.(interface{CloseWrite()error});ok{err=c.CloseWrite()}}
				done<-err
			}()
			go func(){_,err:=io.Copy(client,item.conn);if err==nil{if c,ok:=client.(interface{CloseWrite()error});ok{err=c.CloseWrite()}};done<-err}()
			for i := 0; i < 2; i++ {
				if err := <-done; err != nil {
					if errors.Is(err, errWebRTCBlocked) {
						reason = "webrtc-blocked"
					} else if reason != "webrtc-blocked" {
						reason = "forwarding-error"
					}
					client.Close()
					item.conn.Close()
				}
			}
		}()
	}
}

// Verify the reverse TCP tuple belongs to this process, not another local client.
func sameProcessPeer(conn net.Conn)bool{
    peer,ok:=conn.RemoteAddr().(*net.TCPAddr);if !ok{return false};local,ok:=conn.LocalAddr().(*net.TCPAddr);if !ok{return false}
    family:=uint32(2);rowSize:=24;if peer.IP.To4()==nil{family=23;rowSize=56}
    proc:=windows.NewLazySystemDLL("iphlpapi.dll").NewProc("GetExtendedTcpTable")
    var size uint32
    result,_,_:=proc.Call(0,uintptr(unsafe.Pointer(&size)),0,uintptr(family),4,0)
    if result!=122||size<4||size>4*1024*1024{return false}
    data:=make([]byte,size);result,_,_=proc.Call(uintptr(unsafe.Pointer(&data[0])),uintptr(unsafe.Pointer(&size)),0,uintptr(family),4,0)
    if result!=0{return false};count:=int(binary.LittleEndian.Uint32(data[:4]));if count>(len(data)-4)/rowSize{return false}
    for i:=0;i<count;i++{row:=data[4+i*rowSize:4+(i+1)*rowSize]
        var source,destination net.IP;var sport,dport uint16;var pid uint32
        if family==2{source=net.IP(row[4:8]);sport=binary.BigEndian.Uint16(row[8:10]);destination=net.IP(row[12:16]);dport=binary.BigEndian.Uint16(row[16:18]);pid=binary.LittleEndian.Uint32(row[20:24])
        }else{source=net.IP(row[:16]);sport=binary.BigEndian.Uint16(row[20:22]);destination=net.IP(row[24:40]);dport=binary.BigEndian.Uint16(row[44:46]);pid=binary.LittleEndian.Uint32(row[52:56])}
        if source.Equal(peer.IP)&&destination.Equal(local.IP)&&int(sport)==peer.Port&&int(dport)==local.Port{return int(pid)==os.Getpid()}
    };return false
}

//export CdfTransportStart
func CdfTransportStart(host *C.CdfNetworkHostApi, profilePath *C.uint16_t, interfaceID *C.uint16_t) (result C.int) {
	result = unavailable
	defer func() {
		if recover() != nil {
			result = unavailable
		}
	}()
	if host == nil || host.version != 1 || host.size != C.uint32_t(C.sizeof_CdfNetworkHostApi) || host.authorize_socket == nil || host.real_utc_ticks == nil {
		return denied
	}
	C.cdf_set_host(host)
	xlog.RegisterHandler(silentLog{})
	state.Lock()
	defer state.Unlock()
	if state.instance != nil {
		return 0
	}
	profile := windows.UTF16PtrToString((*uint16)(unsafe.Pointer(profilePath)))
	p, err := plaintextProfile(profile)
	if err != nil {
		return denied
	}
	if p.Type != "vless" || p.Network != "tcp" || p.Flow != "xtls-rprx-vision" || p.Fingerprint != "chrome" || p.Port == 0 || p.SNI == "" {
		return denied
	}
	server := net.ParseIP(p.Server)
	if server == nil || server.To4() == nil {
		return denied
	}
	ip4 := server.To4()
	if C.cdf_configure((*C.uint8_t)(unsafe.Pointer(&ip4[0])), C.uint16_t(p.Port)) == 0 {
		return denied
	}
	id := windows.UTF16PtrToString((*uint16)(unsafe.Pointer(interfaceID)))
	var physical *net.Interface
	interfaces, err := net.Interfaces()
	if err != nil {
		return unavailable
	}
	for _, candidate := range interfaces {
		guid := interfaceGUID(candidate.Index)
		if strings.EqualFold(strings.Trim(guid, "{}"), strings.Trim(id, "{}")) {
			copy := candidate
			physical = &copy
			break
		}
	}
	if physical == nil || physical.Flags&net.FlagUp == 0 {
		return unavailable
	}
	var local net.IP
	addresses, _ := physical.Addrs()
	for _, address := range addresses {
		ip, _, _ := net.ParseCIDR(address.String())
		if ip.To4() != nil && !ip.IsLoopback() {
			local = ip
			break
		}
	}
	if local == nil {
		return unavailable
	}
	net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(context.Context, string, string) (net.Conn, error) { return nil, errors.New("local DNS forbidden") }}
	reality.CdfClock = realNow
	instance, err := makeInstance(p)
	if err != nil {
		return unavailable
	}
	internet.UseAlternativeSystemDialer(&privateDialer{server: server, port: p.Port, local: local, index: physical.Index})
	if err = instance.Start(); err != nil {
		instance.Close()
		return unavailable
	}
	state.instance = instance
	state.protectionPath = filepath.Join(filepath.Dir(profile), "protection.json")
	state.pending = make(map[bridgeKey]*reservation)
	state.sessions=make(map[bridgeKey]*reservation)
	state.opening=make(map[bridgeKey]context.CancelFunc)
	state.active = make(map[net.Conn]bool)
	state.stopped = false
	state.listener4, err = privateListener("tcp4", "127.0.0.1:0")
	if err != nil {
		instance.Close()
		state.instance = nil
		return unavailable
	}
	roots,err:=privateRoots();if err!=nil{return unavailable}
	transport := &http.Transport{Proxy: nil, ForceAttemptHTTP2: false, TLSClientConfig: &tls.Config{RootCAs:roots,ServerName: "cloudflare-dns.com", MinVersion: tls.VersionTLS12, Time: realNow},
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) { return openTunnel(ctx, "1.1.1.1", 443) }, MaxIdleConns: 4, MaxConnsPerHost: 4, IdleConnTimeout: 30 * time.Second}
	state.client = &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("DoH redirect rejected") }}
	go runBridge(state.listener4, 2)
	telemetryContext, stopTelemetry := context.WithCancel(context.Background())
	state.stopTelemetry = stopTelemetry
	go serveConnections(telemetryContext)
	return 0
}

// interfaceGUID avoids storing an interface index across reboots.
func interfaceGUID(index int) string {
	var luid uint64
	var guid windows.GUID
	dll := windows.NewLazySystemDLL("iphlpapi.dll")
	a, _, _ := dll.NewProc("ConvertInterfaceIndexToLuid").Call(uintptr(index), uintptr(unsafe.Pointer(&luid)))
	if a != 0 {
		return ""
	}
	a, _, _ = dll.NewProc("ConvertInterfaceLuidToGuid").Call(uintptr(unsafe.Pointer(&luid)), uintptr(unsafe.Pointer(&guid)))
	if a != 0 {
		return ""
	}
	return guid.String()
}

//export CdfTransportOpen
func CdfTransportOpen(host *C.char, port C.uint16_t, localPort C.uint16_t, family C.uint32_t,localAddress *C.char, bridgePort *C.uint16_t) (result C.int) {
	result = refused
	defer func() {
		if recover() != nil {
			result = refused
		}
	}()
	if host == nil || port == 0 || localPort == 0 || bridgePort == nil || localAddress==nil {
		return denied
	}
	if family != 2 {
		return 10047
	}
	name := C.GoString(host)
	if len(name) == 0 || len(name) > 253 {
		return denied
	}
	localIP:=net.ParseIP(C.GoString(localAddress)).To4();if localIP==nil{return denied}
	ip := net.ParseIP(name)
	if strings.Contains(name, ":") || (ip != nil && ip.To4() == nil) {
		return 10047
	}
	if ip != nil && (ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsMulticast() || ip.IsUnspecified()) {
		return denied
	}
	state.Lock()
	listener := state.listener4
	protectionPath := state.protectionPath
	state.Unlock()
	if listener == nil {
		return unavailable
	}
	blockWebRTC := webRTCDisabled(protectionPath)
	if blockedWebRTCPort(uint16(port), blockWebRTC) {
		now := realNow()
		id := connections.Begin(name, uint16(port), now)
		connections.Finish(id, "webrtc-blocked", now)
		return denied
	}
	if localIP.IsUnspecified(){localIP=listener.Addr().(*net.TCPAddr).IP}
	key := bridgeKey{uint32(family), uint16(localPort)}
	ctx,cancel:=context.WithCancel(context.Background())
	state.Lock();if state.opening[key]!=nil||state.sessions[key]!=nil{state.Unlock();cancel();return denied};state.opening[key]=cancel;state.Unlock()
	record := connections.Begin(name, uint16(port), realNow())
	conn, err := openTunnel(ctx, name, uint16(port))
	if err != nil {
		state.Lock();delete(state.opening,key);state.Unlock()
		cancel()
		if errors.Is(err, context.Canceled) {
			connections.Finish(record, "cancelled", realNow())
			return 995
		}
		if errors.Is(err, context.DeadlineExceeded) {
			connections.Finish(record, "handshake-timeout", realNow())
			return timedOut
		}
		connections.Finish(record, "handshake-failed", realNow())
		return refused
	}
	item := &reservation{conn: conn, localIP: localIP, record: record, blockWebRTC: blockWebRTC}
	state.Lock()
	delete(state.opening,key)
	if state.pending[key] != nil || state.stopped || ctx.Err()!=nil {
		state.Unlock()
		conn.Close()
		cancel()
		connections.Finish(record, "cancelled", realNow())
		return denied
	}
	item.expires = time.AfterFunc(10*time.Second, func() {
		state.Lock()
		if state.pending[key] == item {
			delete(state.pending, key)
			delete(state.sessions,key)
			item.conn.Close()
			connections.Finish(item.record, "bridge-timeout", realNow())
		}
		state.Unlock()
	})
	state.pending[key] = item
	state.sessions[key]=item
	state.Unlock()
	*bridgePort = C.uint16_t(listener.Addr().(*net.TCPAddr).Port)
	return 0
}

//export CdfTransportRelease
func CdfTransportRelease(port C.uint16_t,family C.uint32_t){
    key:=bridgeKey{uint32(family),uint16(port)}
    state.Lock();cancel:=state.opening[key];item:=state.sessions[key];delete(state.pending,key);delete(state.sessions,key);state.Unlock()
	if cancel != nil {
		cancel()
	}
	if item != nil {
		reason := "cancelled"
		if item.client != nil {
			reason = "socket-closed"
		}
		connections.Finish(item.record, reason, realNow())
		item.expires.Stop()
		if item.client != nil {
			item.client.Close()
		}
		item.conn.Close()
	}
}

//export CdfTransportDns
func CdfTransportDns(input *C.uint8_t, length C.uint32_t, output *C.uint8_t, capacity C.uint32_t, actual *C.uint32_t) C.int {
	return CdfTransportDnsV4(input, length, output, capacity, actual)
}

//export CdfTransportDnsV4
func CdfTransportDnsV4(input *C.uint8_t, length C.uint32_t, output *C.uint8_t, capacity C.uint32_t, actual *C.uint32_t) (result C.int) {
	result = 11002
	defer func() {
		if recover() != nil {
			result = 11002
		}
	}()
	if input == nil || output == nil || actual == nil || length < 12 || length > 65535 || capacity < 12 {
		return denied
	}
	*actual = 0
	query := C.GoBytes(unsafe.Pointer(input), C.int(length))
	state.Lock()
	client := state.client
	if state.stopped {
		client = nil
	}
	state.Unlock()
	started := realNow()
	body, record, status := resolveDNS(client, query)
	if record.Name != "" {
		record.Finished = realNow().UTC()
		record.DurationMS = max(0, record.Finished.Sub(started).Milliseconds())
		if status == 0 && len(body) > int(capacity) {
			record.Status = "buffer-too-small"
		}
		connections.RecordDNS(record)
	}
	if status != 0 {
		return C.int(status)
	}
	*actual = C.uint32_t(len(body))
	if len(body) > int(capacity) {
		return 10055
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(output)), int(capacity)), body)
	return 0
}

//export CdfTransportStop
func CdfTransportStop() {
	state.Lock()
	defer state.Unlock()
	state.stopped = true
	if state.stopTelemetry != nil {
		state.stopTelemetry()
	}
	for _,cancel:=range state.opening{cancel()};clear(state.opening)
	if state.listener4 != nil {
		state.listener4.Close()
	}
	for _, item := range state.pending {
		item.expires.Stop()
		item.conn.Close()
	}
	clear(state.pending)
	for conn := range state.active {
		conn.Close()
	}
	clear(state.active)
	if state.client != nil {
		state.client.CloseIdleConnections()
	}
	// DLL stays loaded until process exit; unloading a Go runtime is unsupported.
}
func main() {}
