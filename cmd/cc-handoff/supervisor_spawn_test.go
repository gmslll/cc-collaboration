package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A simulated app consumes the outbox, asserts the spawn payload, and writes back
// the new session id as the .ok receipt — runSupervisorSpawn should print it.
// Also exercises flag-after-positional order (parseFlexible).
func TestSupervisorSpawnDelivered(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CC_BUS_DIR", dir)
	t.Setenv("CC_SESSION_ID", "ts0")
	outbox := filepath.Join(dir, "outbox")

	go consumeOutbox(t, outbox, func(name string, m map[string]any) {
		if m["kind"] != "spawn" || m["from"] != "ts0" ||
			m["project"] != "cc-collaboration" || m["agent"] != "codex" ||
			m["supervisor"] != true || m["workspace"] != "kunlun" ||
			m["workdir"] != "/w/cc/.worktrees/x" {
			t.Errorf("bad spawn payload: %+v", m)
		}
		base := strings.TrimSuffix(name, ".json")
		os.Remove(filepath.Join(outbox, name))                                // simulate claim
		os.WriteFile(filepath.Join(outbox, base+".ok"), []byte("ts7"), 0o600) // new session id receipt
	})

	var spawnErr error
	out := captureStdout(t, func() {
		spawnErr = runSupervisorSpawn(context.Background(), []string{
			"cc-collaboration", "--agent", "codex", "--supervisor",
			"--workspace", "kunlun", "--worktree", "/w/cc/.worktrees/x",
		})
	})
	if spawnErr != nil {
		t.Fatalf("spawn: %v", spawnErr)
	}
	if !strings.Contains(out, "ts7") {
		t.Fatalf("new session id not printed: %q", out)
	}
}

// Defaults: --agent claude, supervisor false, empty workdir/workspace.
func TestSupervisorSpawnDefaults(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CC_BUS_DIR", dir)
	t.Setenv("CC_SESSION_ID", "ts0")
	outbox := filepath.Join(dir, "outbox")

	go consumeOutbox(t, outbox, func(name string, m map[string]any) {
		if m["agent"] != "claude" || m["supervisor"] != false ||
			m["workdir"] != "" || m["workspace"] != "" {
			t.Errorf("bad spawn defaults: %+v", m)
		}
		base := strings.TrimSuffix(name, ".json")
		os.Remove(filepath.Join(outbox, name))
		os.WriteFile(filepath.Join(outbox, base+".ok"), []byte("ts9"), 0o600)
	})

	var spawnErr error
	captureStdout(t, func() {
		spawnErr = runSupervisorSpawn(context.Background(), []string{"myproj"})
	})
	if spawnErr != nil {
		t.Fatalf("spawn: %v", spawnErr)
	}
}

// No project positional → usage error (never touches the bus).
func TestSupervisorSpawnRequiresProject(t *testing.T) {
	t.Setenv("CC_BUS_DIR", t.TempDir())
	t.Setenv("CC_SESSION_ID", "ts0")
	err := runSupervisorSpawn(context.Background(), []string{"--agent", "claude"})
	if err == nil || !strings.Contains(err.Error(), "usage") {
		t.Fatalf("want usage error, got %v", err)
	}
}

// The app's .err receipt (e.g. project not found) surfaces as the command error.
func TestSupervisorSpawnError(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CC_BUS_DIR", dir)
	t.Setenv("CC_SESSION_ID", "ts0")
	outbox := filepath.Join(dir, "outbox")

	go consumeOutbox(t, outbox, func(name string, _ map[string]any) {
		base := strings.TrimSuffix(name, ".json")
		os.Remove(filepath.Join(outbox, name))
		os.WriteFile(filepath.Join(outbox, base+".err"), []byte(`找不到项目 "nope"`), 0o600)
	})

	err := runSupervisorSpawn(context.Background(), []string{"nope"})
	if err == nil || !strings.Contains(err.Error(), "找不到项目") {
		t.Fatalf("want project-not-found error, got %v", err)
	}
}
