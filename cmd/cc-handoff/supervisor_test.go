package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSupervisorQueueIncludesAttentionDetails(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CC_BUS_DIR", dir)
	t.Setenv("CC_SESSION_ID", "ts0")
	registry := `[
		{"id":"ts0","label":"Supervisor","status":"idle","supervisor":true},
		{"id":"ts1","label":"Worker done","status":"needsReview"},
		{"id":"ts2","label":"Worker failed","status":"idle","statusDetail":"上次工具失败：test exit 1"},
		{"id":"ts3","label":"Worker tool failed","status":"toolFailed"},
		{"id":"ts4","label":"Worker idle","status":"idle"}
	]`
	if err := os.WriteFile(filepath.Join(dir, "sessions.json"), []byte(registry), 0o600); err != nil {
		t.Fatal(err)
	}

	var queueErr error
	out := captureStdout(t, func() {
		queueErr = runSupervisorOverview([]string{"--json"}, true)
	})
	if queueErr != nil {
		t.Fatal(queueErr)
	}
	var got []busSession
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("not valid JSON: %v (%s)", err, out)
	}
	if len(got) != 3 || got[0].ID != "ts1" || got[1].ID != "ts2" || got[2].ID != "ts3" {
		t.Fatalf("queue mismatch: %+v", got)
	}
}

func TestSupervisorReadFallsBackToScreen(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CC_BUS_DIR", dir)
	t.Setenv("CC_SESSION_ID", "ts0")
	outbox := filepath.Join(dir, "outbox")
	const snapshot = "screen fallback content"
	seenTranscript := false
	seenScreen := false
	done := make(chan struct{})

	go func() {
		defer close(done)
		consumeOutbox(t, outbox, func(name string, m map[string]any) {
			base := strings.TrimSuffix(name, ".json")
			os.Remove(filepath.Join(outbox, name))
			if m["transcript"] != true {
				t.Errorf("first read should request transcript, got: %+v", m)
			}
			seenTranscript = true
			os.WriteFile(filepath.Join(outbox, base+".err"), []byte("找不到 transcript"), 0o600)
		})
		consumeOutbox(t, outbox, func(name string, m map[string]any) {
			base := strings.TrimSuffix(name, ".json")
			os.Remove(filepath.Join(outbox, name))
			if m["transcript"] == true {
				t.Errorf("second read should be screen fallback, got transcript payload: %+v", m)
				os.WriteFile(filepath.Join(outbox, base+".err"), []byte("unexpected transcript"), 0o600)
				return
			}
			seenScreen = true
			os.WriteFile(filepath.Join(outbox, base+".ok"), []byte(snapshot), 0o600)
		})
	}()

	var readErr error
	out := captureStdout(t, func() {
		readErr = runSupervisorRead(context.Background(), []string{"--timeout", "1s", "ts1"})
	})
	if readErr != nil {
		t.Fatalf("read: %v", readErr)
	}
	<-done
	if !seenTranscript || !seenScreen {
		t.Fatalf("fallback path not exercised: transcript=%v screen=%v", seenTranscript, seenScreen)
	}
	if !strings.Contains(out, snapshot) {
		t.Fatalf("snapshot not printed: %q", out)
	}
}

func TestSupervisorReadDoesNotFallbackForResolutionError(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CC_BUS_DIR", dir)
	t.Setenv("CC_SESSION_ID", "ts0")
	outbox := filepath.Join(dir, "outbox")
	requests := 0
	done := make(chan struct{})

	go func() {
		defer close(done)
		consumeOutbox(t, outbox, func(name string, _ map[string]any) {
			requests++
			base := strings.TrimSuffix(name, ".json")
			os.Remove(filepath.Join(outbox, name))
			os.WriteFile(filepath.Join(outbox, base+".err"), []byte("找不到目标会话「ts9」"), 0o600)
		})
	}()

	err := runSupervisorRead(context.Background(), []string{"--timeout", "1s", "ts9"})
	if err == nil || !strings.Contains(err.Error(), "找不到目标会话") {
		t.Fatalf("want resolution error, got %v", err)
	}
	<-done
	if requests != 1 {
		t.Fatalf("resolution error should not fallback, got %d requests", requests)
	}
}
