package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"testing"
	"time"

	"claude-desktop-fake/network-transport/internal/localpipe"
	"golang.org/x/sys/windows"
)

func TestRestrictedServiceCanReadSameUserElevatedPipe(t *testing.T) {
	if parent := os.Getenv("CDF_GUI_FIXTURE_PARENT"); parent != "" {
		n, err := strconv.ParseUint(parent, 10, 32)
		if err != nil {
			t.Fatal(err)
		}
		id, err := localpipe.ProcessIdentity(uint32(n))
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		path := localpipe.Name(id.Logon, fmt.Sprintf("restricted-test.%d", id.PID))
		reply, err := localpipe.Exchange(ctx, path, id, []byte("snapshot"))
		if err != nil || string(reply) != "observed" {
			t.Fatalf("could not read same-user diagnostic pipe: %q %v", reply, err)
		}
		return
	}
	if !isAdmin() {
		t.Skip("an elevated test runner exercises the restricted child")
	}
	id, err := localpipe.ProcessIdentity(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	restricted, err := restrictedToken()
	if err != nil {
		t.Fatal(err)
	}
	defer restricted.Close()
	path := localpipe.Name(id.Logon, fmt.Sprintf("restricted-test.%d", id.PID))
	server, err := localpipe.Listen(path, id)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		server.Serve(ctx, func(_ []byte, _ localpipe.Identity) []byte { return []byte("observed") })
	}()
	defer func() {
		cancel()
		<-stopped
	}()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestRestrictedServiceCanReadSameUserElevatedPipe$")
	cmd.Env = append(os.Environ(), fmt.Sprintf("CDF_GUI_FIXTURE_PARENT=%d", id.PID))
	cmd.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(restricted), HideWindow: true, CreationFlags: windows.DETACHED_PROCESS}
	if result, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("restricted service exited: %v\n%s", err, result)
	}
}
