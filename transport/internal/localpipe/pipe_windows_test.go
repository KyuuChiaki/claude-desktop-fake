package localpipe

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"
)

func TestLocalPipeVerifiesPeersAndRecoversAfterRejectedClient(t *testing.T) {
	id, err := ProcessIdentity(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	name := Name(id.Logon, fmt.Sprintf("fixture.%d.%d", id.PID, time.Now().UnixNano()))
	server, err := Listen(name, id)
	if err != nil {
		t.Fatal(err)
	}
	if duplicate, err := Listen(name, id); err == nil {
		duplicate.Close()
		t.Fatal("second server acquired an exclusive pipe name")
	}
	go server.Serve(ctx, func(payload []byte, peer Identity) []byte {
		if peer != id {
			return nil
		}
		return append([]byte("echo:"), payload...)
	})
	bad := id
	bad.Created++
	if connection, err := Dial(name, bad); err == nil {
		connection.Close()
		t.Fatal("accepted a mismatched creation time")
	}
	var result []byte
	for i := 0; i < 10; i++ {
		result, err = Exchange(ctx, name, id, []byte("fixture"))
		if err == nil {
			break
		}
		time.Sleep(90 * time.Millisecond)
	}
	if err != nil || string(result) != "echo:fixture" {
		t.Fatalf("valid local IPC exchange: %q %v", result, err)
	}
}
