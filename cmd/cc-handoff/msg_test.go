package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLoadSessions(t *testing.T) {
	dir := t.TempDir()
	// Missing registry → empty, not an error.
	ss, err := loadSessions(dir)
	if err != nil || ss != nil {
		t.Fatalf("missing file: got %v, %v; want nil, nil", ss, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "sessions.json"),
		[]byte(`[{"id":"ts0","label":"api","workdir":"/x"},{"id":"ts1","label":"web","workdir":"/y"}]`),
		0o600); err != nil {
		t.Fatal(err)
	}
	ss, err = loadSessions(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(ss) != 2 || ss[0].ID != "ts0" || ss[1].Label != "web" {
		t.Fatalf("round-trip mismatch: %+v", ss)
	}
}

func TestMsgListFiltersSelf(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CC_BUS_DIR", dir)
	t.Setenv("CC_SESSION_ID", "ts0")
	if err := os.WriteFile(filepath.Join(dir, "sessions.json"),
		[]byte(`[{"id":"ts0","label":"me"},{"id":"ts1","label":"peer"}]`), 0o600); err != nil {
		t.Fatal(err)
	}
	var listErr error
	out := captureStdout(t, func() { listErr = runMsgList([]string{"--json"}) })
	if listErr != nil {
		t.Fatal(listErr)
	}
	if !strings.Contains(out, `"ts1"`) || strings.Contains(out, `"ts0"`) {
		t.Fatalf("list should drop self, keep peers: %s", out)
	}
}

// TestMsgSendDelivered: a simulated app consumes the outbox file → send succeeds
// and the on-disk payload is well-formed.
func TestMsgSendDelivered(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CC_BUS_DIR", dir)
	t.Setenv("CC_SESSION_ID", "ts0")
	outbox := filepath.Join(dir, "outbox")

	go consumeOutbox(t, outbox, func(name string, m map[string]any) {
		if m["to"] != "ts1" || m["from"] != "ts0" || m["body"] != "hi there" || m["submit"] != true {
			t.Errorf("bad payload: %+v", m)
		}
		base := strings.TrimSuffix(name, ".json")
		os.Remove(filepath.Join(outbox, name))                                  // simulate claim
		os.WriteFile(filepath.Join(outbox, base+".ok"), []byte("ok"), 0o600) // success receipt
	})

	if err := runMsgSend(context.Background(), []string{"ts1", "hi", "there"}); err != nil {
		t.Fatalf("send: %v", err)
	}
}

// TestMsgSendError: the app writes a sibling .err → send surfaces it non-nil.
func TestMsgSendError(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CC_BUS_DIR", dir)
	t.Setenv("CC_SESSION_ID", "ts0")
	outbox := filepath.Join(dir, "outbox")

	go consumeOutbox(t, outbox, func(name string, _ map[string]any) {
		base := strings.TrimSuffix(name, ".json")
		os.Remove(filepath.Join(outbox, name))                                          // simulate claim
		os.WriteFile(filepath.Join(outbox, base+".err"), []byte("找不到目标会话「ts9」"), 0o600) // failure receipt
	})

	err := runMsgSend(context.Background(), []string{"ts9", "hello"})
	if err == nil || !strings.Contains(err.Error(), "找不到目标会话") {
		t.Fatalf("want delivery error, got %v", err)
	}
}

// TestMsgSendNoReceiver: nobody consumes → times out with a clear message.
func TestMsgSendNoReceiver(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CC_BUS_DIR", dir)
	t.Setenv("CC_SESSION_ID", "ts0")
	err := runMsgSend(context.Background(), []string{"--timeout", "150ms", "ts1", "yo"})
	if err == nil || !strings.Contains(err.Error(), "无人接收") {
		t.Fatalf("want no-receiver error, got %v", err)
	}
}

func TestMsgSendOutsideBus(t *testing.T) {
	t.Setenv("CC_BUS_DIR", "")
	if err := runMsgSend(context.Background(), []string{"ts1", "x"}); err == nil ||
		!strings.Contains(err.Error(), "CC_BUS_DIR") {
		t.Fatalf("want CC_BUS_DIR error, got %v", err)
	}
}

// consumeOutbox polls outbox until a *.json appears, decodes it, and hands it to
// onMsg (which simulates the app's success/failure write-back). One-shot.
func consumeOutbox(t *testing.T, outbox string, onMsg func(name string, m map[string]any)) {
	t.Helper()
	for i := 0; i < 200; i++ {
		entries, _ := os.ReadDir(outbox)
		for _, e := range entries {
			if strings.HasSuffix(e.Name(), ".json") {
				b, err := os.ReadFile(filepath.Join(outbox, e.Name()))
				if err != nil {
					continue // mid-rename; retry
				}
				var m map[string]any
				if err := json.Unmarshal(b, &m); err != nil {
					t.Errorf("bad json: %v", err)
				}
				onMsg(e.Name(), m)
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
}
