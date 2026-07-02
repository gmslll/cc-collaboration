package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/localbus"
)

func TestBusHookResponse_PostToolUse_NonBlocking(t *testing.T) {
	out := busHookResponse(busHookEvent{HookEventName: "PostToolUse"}, "msg", 1)
	if out == nil {
		t.Fatal("expected a response for PostToolUse")
	}
	if _, blocked := out["decision"]; blocked {
		t.Error("PostToolUse must not block the turn")
	}
	hso, _ := out["hookSpecificOutput"].(map[string]any)
	if hso == nil || hso["additionalContext"] != "msg" {
		t.Errorf("missing additionalContext: %+v", out)
	}
	if hso["hookEventName"] != "PostToolUse" {
		t.Errorf("hookEventName=%v, want PostToolUse", hso["hookEventName"])
	}
}

func TestBusHookResponse_EmptyEventDefaultsToPostToolUse(t *testing.T) {
	out := busHookResponse(busHookEvent{}, "msg", 1)
	if _, blocked := out["decision"]; blocked {
		t.Error("empty event must default to the non-blocking shape")
	}
	hso, _ := out["hookSpecificOutput"].(map[string]any)
	if hso == nil || hso["hookEventName"] != "PostToolUse" {
		t.Errorf("empty event should default hookEventName to PostToolUse: %+v", out)
	}
}

func TestBusHookResponse_StopBlocks(t *testing.T) {
	out := busHookResponse(busHookEvent{HookEventName: "Stop"}, "msg", 2)
	if out == nil {
		t.Fatal("expected a response for Stop")
	}
	if out["decision"] != "block" {
		t.Errorf("Stop should block to pull a new turn, got decision=%v", out["decision"])
	}
	hso, _ := out["hookSpecificOutput"].(map[string]any)
	if hso == nil || hso["additionalContext"] != "msg" {
		t.Errorf("missing additionalContext: %+v", out)
	}
}

// Note: the wake-loop guard (don't re-block when stop_hook_active) lives in
// runBusHookDrain, which bails before draining so parked messages survive — see
// the end-to-end check rather than here, since busHookResponse is only reached
// once a response is actually wanted.

// runDrainWith invokes runBusHookDrain with payload on stdin and a throwaway
// stdout, restoring both after. The drain reads CC_BUS_DIR/CC_SESSION_ID from
// the env (set via t.Setenv by the caller) and the hook event from stdin.
func runDrainWith(t *testing.T, payload string) {
	t.Helper()
	rIn, wIn, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(wIn, payload); err != nil {
		t.Fatal(err)
	}
	wIn.Close()

	rOut, wOut, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	oldIn, oldOut := os.Stdin, os.Stdout
	os.Stdin, os.Stdout = rIn, wOut
	defer func() {
		os.Stdin, os.Stdout = oldIn, oldOut
		rIn.Close()
		rOut.Close()
	}()

	drainErr := runBusHookDrain()
	wOut.Close() // tiny JSON response stays under the pipe buffer, never blocks
	if drainErr != nil {
		t.Fatalf("runBusHookDrain: %v", drainErr)
	}
}

// A Task subagent inherits the parent's CC_SESSION_ID, so its tool-call
// PostToolUse hook would (before the agent_id gate) drain and DELETE the
// parent's parked peer messages into the subagent's context — the parent and
// user would never see them. The gate must leave the parent inbox untouched.
func TestBusHookDrain_SubagentDoesNotStealParentInbox(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts-parent"
	if err := localbus.WriteMsg(bus, sid, "001", localbus.Msg{From: "ts-peer", FromLabel: "peer", Body: "hi parent"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", sid)

	// agent_id present → we're inside a subagent.
	runDrainWith(t, `{"hook_event_name":"PostToolUse","agent_id":"sub-123"}`)

	left, err := localbus.ListMsgs(bus, sid)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 1 {
		t.Fatalf("subagent drained the parent inbox: want 1 message still parked, got %d", len(left))
	}
}

// The complement: a top-level tool call (no agent_id) must drain normally, or
// the gate would strand every message.
func TestBusHookDrain_TopLevelDrainsInbox(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts-parent"
	if err := localbus.WriteMsg(bus, sid, "001", localbus.Msg{From: "ts-peer", Body: "hi"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", sid)

	// no agent_id → top-level session.
	runDrainWith(t, `{"hook_event_name":"PostToolUse"}`)

	left, err := localbus.ListMsgs(bus, sid)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		t.Fatalf("top-level hook must drain the inbox, %d message(s) left", len(left))
	}
}

// TestBusHookDrain_ContendedLockBailsWithoutDraining: when the app's
// escalate-timeout path (or another concurrent hook invocation) already holds
// the inbox drain lock, the hook must not block waiting for it indefinitely —
// it bails immediately-ish and leaves the message parked for the next hook,
// never double-delivering. Shrinks busHookDrainLockTimeout so the test doesn't
// eat the real (production) 2s wait.
func TestBusHookDrain_ContendedLockBailsWithoutDraining(t *testing.T) {
	old := busHookDrainLockTimeout
	busHookDrainLockTimeout = 50 * time.Millisecond
	defer func() { busHookDrainLockTimeout = old }()

	bus := t.TempDir()
	const sid = "ts-parent"
	if err := localbus.WriteMsg(bus, sid, "001", localbus.Msg{From: "ts-peer", Body: "hi"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", sid)

	// Simulate the app's escalate path (or a racing hook) holding the lock.
	release, err := localbus.AcquireDrainLock(bus, sid, time.Second)
	if err != nil {
		t.Fatalf("acquire lock: %v", err)
	}
	defer release()

	runDrainWith(t, `{"hook_event_name":"PostToolUse"}`)

	// Message must still be parked — the hook bailed instead of draining.
	left, err := localbus.ListMsgs(bus, sid)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 1 {
		t.Fatalf("contended lock should leave the message parked, got %d left", len(left))
	}
}

// TestBusHookDrain_DrainsAfterLockReleased: the complement — once the
// contending holder releases, the very next hook invocation drains normally.
func TestBusHookDrain_DrainsAfterLockReleased(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts-parent"
	if err := localbus.WriteMsg(bus, sid, "001", localbus.Msg{From: "ts-peer", Body: "hi"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", sid)

	release, err := localbus.AcquireDrainLock(bus, sid, time.Second)
	if err != nil {
		t.Fatalf("acquire lock: %v", err)
	}
	release() // released before the hook runs

	runDrainWith(t, `{"hook_event_name":"PostToolUse"}`)

	left, err := localbus.ListMsgs(bus, sid)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		t.Fatalf("hook should drain normally once the lock is free, %d left", len(left))
	}
}

// readSessionMap reads the CC_SESSION_ID -> agent session id mapping the hook
// records under $CC_BUS_DIR/sessions/<ccID>.json.
func readSessionMap(t *testing.T, bus, ccID string) (map[string]any, bool) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(bus, "sessions", ccID+".json"))
	if os.IsNotExist(err) {
		return nil, false
	}
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("session map not valid JSON: %v", err)
	}
	return m, true
}

// A top-level hook carrying the agent's session_id must record the mapping the
// desktop app reads to resume the tab's exact agent session.
func TestBusHookDrain_RecordsAgentSession(t *testing.T) {
	bus := t.TempDir()
	const ccID = "ts7"
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", ccID)

	runDrainWith(t, `{"hook_event_name":"PostToolUse","session_id":"codex-abc-123","cwd":"/repo"}`)

	m, ok := readSessionMap(t, bus, ccID)
	if !ok {
		t.Fatal("expected a session mapping file to be written")
	}
	if m["id"] != "codex-abc-123" {
		t.Errorf("id=%v, want codex-abc-123", m["id"])
	}
	if m["cwd"] != "/repo" {
		t.Errorf("cwd=%v, want /repo", m["cwd"])
	}
}

// A subagent hook (agent_id set) carries the SUBAGENT's session_id, not the
// tab's — recording it would bind the parent tab to the wrong session. The
// agent_id gate must skip recording (it bails before recordAgentSession).
func TestBusHookDrain_SubagentDoesNotRecordSession(t *testing.T) {
	bus := t.TempDir()
	const ccID = "ts7"
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", ccID)

	runDrainWith(t, `{"hook_event_name":"PostToolUse","agent_id":"sub-1","session_id":"subagent-xyz","cwd":"/repo"}`)

	if _, ok := readSessionMap(t, bus, ccID); ok {
		t.Error("a subagent hook must not record a session mapping for the parent tab")
	}
}

// A hook with no session_id (or outside an app session) must not write a file.
func TestBusHookDrain_NoSessionIdNoRecord(t *testing.T) {
	bus := t.TempDir()
	const ccID = "ts7"
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", ccID)

	runDrainWith(t, `{"hook_event_name":"PostToolUse","cwd":"/repo"}`)

	if _, ok := readSessionMap(t, bus, ccID); ok {
		t.Error("no session_id in payload should write no mapping")
	}
}
