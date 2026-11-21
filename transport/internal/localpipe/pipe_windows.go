// Copyright (c) 2026 claude-desktop-fake contributors. MIT license.
package localpipe

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync/atomic"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const MaxFrame = 2 << 20

type Identity struct {
	PID     uint32
	Created uint64
	User    string
	Logon   string
}

func TokenIdentity(token windows.Token) (user, logon string, err error) {
	account, err := token.GetTokenUser()
	if err != nil {
		return "", "", err
	}
	groups, err := token.GetTokenGroups()
	if err != nil {
		return "", "", err
	}
	for _, group := range groups.AllGroups() {
		if group.Attributes&windows.SE_GROUP_LOGON_ID == windows.SE_GROUP_LOGON_ID {
			return account.User.Sid.String(), group.Sid.String(), nil
		}
	}
	return "", "", errors.New("interactive Windows logon SID unavailable")
}

func ProcessIdentity(pid uint32) (Identity, error) {
	process, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return Identity{}, err
	}
	defer windows.CloseHandle(process)
	var created, exited, kernel, userTime windows.Filetime
	if err := windows.GetProcessTimes(process, &created, &exited, &kernel, &userTime); err != nil {
		return Identity{}, err
	}
	var token windows.Token
	if err := windows.OpenProcessToken(process, windows.TOKEN_QUERY, &token); err != nil {
		return Identity{}, err
	}
	defer token.Close()
	user, logon, err := TokenIdentity(token)
	return Identity{pid, uint64(created.HighDateTime)<<32 | uint64(created.LowDateTime), user, logon}, err
}

func SameLogon(a, b Identity) bool {
	return a.User != "" && a.User == b.User && a.Logon != "" && a.Logon == b.Logon
}

func Name(logon, channel string) string {
	return `\\.\pipe\ClaudeDesktopFake.` + logon + "." + channel
}

type Conn struct {
	handle windows.Handle
	Peer   Identity
}

func Dial(name string, expected Identity) (*Conn, error) {
	path, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return nil, err
	}
	// Identification SQOS prevents a server from impersonating this client.
	const identification = 0x00110000
	handle, err := windows.CreateFile(path, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OVERLAPPED|identification, 0)
	if err != nil {
		return nil, err
	}
	conn := &Conn{handle: handle}
	var pid uint32
	err = windows.GetNamedPipeServerProcessId(handle, &pid)
	if err == nil {
		var peer Identity
		peer, err = ProcessIdentity(pid)
		if err == nil && (!SameLogon(peer, expected) || expected.PID != 0 && (peer.PID != expected.PID || expected.Created != 0 && peer.Created != expected.Created)) {
			err = errors.New("unexpected named pipe server")
		}
		conn.Peer = peer
	}
	if err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

func (c *Conn) Close() { _ = windows.CloseHandle(c.handle) }

func (c *Conn) operation(ctx context.Context, start func(*windows.Overlapped, *uint32) error) (uint32, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	event, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		return 0, err
	}
	defer windows.CloseHandle(event)
	ov := windows.Overlapped{HEvent: event}
	var done uint32
	if err = start(&ov, &done); !errors.Is(err, windows.ERROR_IO_PENDING) {
		return done, err
	}
	for ctx.Err() == nil {
		result, waitErr := windows.WaitForSingleObject(event, 100)
		if result == windows.WAIT_OBJECT_0 {
			err = windows.GetOverlappedResult(c.handle, &ov, &done, false)
			return done, err
		}
		if waitErr != nil {
			err = waitErr
			break
		}
	}
	_ = windows.CancelIoEx(c.handle, &ov)
	_ = windows.GetOverlappedResult(c.handle, &ov, &done, true)
	if ctx.Err() != nil {
		err = ctx.Err()
	}
	return 0, err
}

func (c *Conn) read(ctx context.Context, buffer []byte) error {
	for len(buffer) > 0 {
		n, err := c.operation(ctx, func(ov *windows.Overlapped, done *uint32) error {
			return windows.ReadFile(c.handle, buffer, done, ov)
		})
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrUnexpectedEOF
		}
		buffer = buffer[n:]
	}
	return nil
}

func (c *Conn) write(ctx context.Context, buffer []byte) error {
	for len(buffer) > 0 {
		n, err := c.operation(ctx, func(ov *windows.Overlapped, done *uint32) error {
			return windows.WriteFile(c.handle, buffer, done, ov)
		})
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		buffer = buffer[n:]
	}
	return nil
}

func (c *Conn) Read(ctx context.Context) ([]byte, error) {
	var header [4]byte
	if err := c.read(ctx, header[:]); err != nil {
		return nil, err
	}
	length := binary.LittleEndian.Uint32(header[:])
	if length == 0 || length > MaxFrame {
		return nil, errors.New("invalid named pipe frame")
	}
	data := make([]byte, length)
	if err := c.read(ctx, data); err != nil {
		clear(data)
		return nil, err
	}
	return data, nil
}

func (c *Conn) Write(ctx context.Context, data []byte) error {
	if len(data) == 0 || len(data) > MaxFrame {
		return errors.New("invalid named pipe frame")
	}
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], uint32(len(data)))
	if err := c.write(ctx, header[:]); err != nil {
		return err
	}
	return c.write(ctx, data)
}

type Server struct {
	conn  Conn
	owner Identity
	used  atomic.Bool
}

func Listen(name string, owner Identity) (*Server, error) {
	path, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return nil, err
	}
	if owner.Logon == "" {
		return nil, errors.New("named pipe owner logon missing")
	}
	sd, err := windows.SecurityDescriptorFromString(fmt.Sprintf("D:P(A;;GRGW;;;%s)S:(ML;;NW;;;ME)", owner.Logon))
	if err != nil {
		return nil, err
	}
	sa := &windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd}
	handle, err := windows.CreateNamedPipe(path, windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_FIRST_PIPE_INSTANCE|windows.FILE_FLAG_OVERLAPPED,
		windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, sa)
	if err != nil {
		return nil, err
	}
	return &Server{conn: Conn{handle: handle}, owner: owner}, nil
}

func (s *Server) Close() { s.conn.Close() }

// Accept runs one bounded exchange. The caller verifies any additional
// constraints on the authenticated peer before accepting application data.
func (s *Server) Accept(ctx context.Context, function func(*Conn, Identity)) error {
	if !s.used.CompareAndSwap(false, true) {
		return errors.New("concurrent named pipe accept")
	}
	defer s.used.Store(false)
	_, err := s.conn.operation(ctx, func(ov *windows.Overlapped, _ *uint32) error {
		return windows.ConnectNamedPipe(s.conn.handle, ov)
	})
	if err != nil && !errors.Is(err, windows.ERROR_PIPE_CONNECTED) {
		if errors.Is(err, windows.ERROR_NO_DATA) || errors.Is(err, windows.ERROR_BROKEN_PIPE) {
			// A client can connect and close before ConnectNamedPipe runs.
			// Reset that instance so the next client can be accepted.
			_ = windows.DisconnectNamedPipe(s.conn.handle)
		}
		return err
	}
	defer windows.DisconnectNamedPipe(s.conn.handle)
	var pid uint32
	if err := windows.GetNamedPipeClientProcessId(s.conn.handle, &pid); err != nil {
		return err
	}
	client, err := ProcessIdentity(pid)
	if err != nil || !SameLogon(s.owner, client) {
		return errors.New("unexpected named pipe client logon")
	}
	function(&s.conn, client)
	return nil
}

func Exchange(ctx context.Context, name string, expected Identity, request []byte) ([]byte, error) {
	var conn *Conn
	for {
		candidate, err := Dial(name, expected)
		if err == nil {
			conn = candidate
			break
		}
		if !errors.Is(err, windows.ERROR_PIPE_BUSY) && !errors.Is(err, windows.ERROR_PIPE_NOT_CONNECTED) {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(25 * time.Millisecond):
		}
	}
	defer conn.Close()
	if err := conn.Write(ctx, request); err != nil {
		return nil, err
	}
	response, err := conn.Read(ctx)
	if err == nil {
		_ = conn.Write(ctx, []byte{1})
	}
	return response, err
}

func (s *Server) Serve(ctx context.Context, handler func([]byte, Identity) []byte) {
	defer s.Close()
	for ctx.Err() == nil {
		err := s.Accept(ctx, func(conn *Conn, client Identity) {
			exchange, cancel := context.WithTimeout(ctx, 2*time.Second)
			defer cancel()
			request, err := conn.Read(exchange)
			if err != nil {
				return
			}
			defer clear(request)
			response := handler(request, client)
			if len(response) > 0 && conn.Write(exchange, response) == nil {
				_, _ = conn.Read(exchange)
			}
		})
		if err != nil && ctx.Err() == nil {
			time.Sleep(50 * time.Millisecond)
		}
	}
}
