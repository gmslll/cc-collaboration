package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cc-collaboration/internal/localbus"
	"github.com/cc-collaboration/internal/setup"
)

func TestWriteStopHookDecision_ExactSharedSchema(t *testing.T) {
	var out bytes.Buffer
	if err := writeStopHookDecision(&out, "msg"); err != nil {
		t.Fatal(err)
	}
	if got, want := out.String(), "{\"decision\":\"block\",\"reason\":\"msg\"}\n"; got != want {
		t.Fatalf("Stop JSON=%q, want exact Claude/Codex schema %q", got, want)
	}
}

func TestBusHookDrain_StopNoEnvOutputsEmptyJSON(t *testing.T) {
	t.Setenv("CC_BUS_DIR", "")
	t.Setenv("CC_SESSION_ID", "")

	out := runDrainCapture(t, `{"hook_event_name":"Stop"}`)
	if out != "{}\n" {
		t.Fatalf("Stop without app env stdout=%q, want empty JSON", out)
	}
}

func TestBusHookDrain_StopNoMessagesOutputsEmptyJSON(t *testing.T) {
	t.Setenv("CC_BUS_DIR", t.TempDir())
	t.Setenv("CC_SESSION_ID", "ts-parent")

	out := runDrainCapture(t, `{"hook_event_name":"Stop"}`)
	if out != "{}\n" {
		t.Fatalf("Stop with no messages stdout=%q, want empty JSON", out)
	}
}

func TestBusHookDrain_MalformedPayloadStaysSilent(t *testing.T) {
	t.Setenv("CC_BUS_DIR", t.TempDir())
	t.Setenv("CC_SESSION_ID", "ts-parent")

	out := runDrainCapture(t, `{`)
	if out != "" {
		t.Fatalf("malformed payload stdout=%q, want shell wrapper to provide fallback JSON", out)
	}
}

func TestBusHookDrain_FirstStopUsesExactSchemaAndDrainsAfterWrite(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts-parent"
	if err := localbus.WriteMsg(bus, sid, "001", localbus.Msg{From: "ts-peer", Body: "hi"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", sid)

	out := runDrainCapture(t, `{"hook_event_name":"Stop"}`)
	m := parseStopDecision(t, out)
	if len(m) != 2 || m["decision"] != "block" {
		t.Fatalf("Stop response must contain only decision/reason, got %+v", m)
	}
	reason, _ := m["reason"].(string)
	if !strings.Contains(reason, "[来自 ts-peer · ts-peer] hi") {
		t.Fatalf("Stop reason does not carry the peer message: %q", reason)
	}
	if _, exists := m["hookSpecificOutput"]; exists {
		t.Fatalf("Stop must not return hookSpecificOutput: %+v", m)
	}

	// A successfully written, locally schema-valid response clears the marker so
	// the app's 3s timeout cannot paste a duplicate.
	inbox, err := localbus.ListMsgs(bus, sid)
	if err != nil {
		t.Fatal(err)
	}
	if len(inbox) != 0 {
		t.Fatalf("live inbox still has %d message(s), want drained", len(inbox))
	}
}

func TestBusHookDrain_StopFailureNoMessagesOutputsEmptyJSON(t *testing.T) {
	t.Setenv("CC_BUS_DIR", t.TempDir())
	t.Setenv("CC_SESSION_ID", "ts-parent")

	out := runDrainCapture(t, `{"hook_event_name":"StopFailure"}`)
	if out != "{}\n" {
		t.Fatalf("StopFailure stdout=%q, want empty JSON", out)
	}
}

// The hook is installed on many lifecycle events for activity tracking, but bus
// delivery must only drain on Stop. Events such as PermissionRequest do not
// support this continuation decision; clearing markers there would lose the
// peer message.
func TestBusHookDrain_UnsupportedEventLeavesInboxParked(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts-parent"
	if err := localbus.WriteMsg(bus, sid, "001", localbus.Msg{From: "ts-peer", Body: "hi"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", sid)

	runDrainWith(t, `{"hook_event_name":"PermissionRequest","session_id":"codex-abc-123","cwd":"/repo"}`)

	left, err := localbus.ListMsgs(bus, sid)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 1 {
		t.Fatalf("unsupported event should leave message parked, got %d left", len(left))
	}
	m, ok := readSessionMap(t, bus, sid)
	if !ok {
		t.Fatal("unsupported event should still record the agent session mapping")
	}
	if m["id"] != "codex-abc-123" {
		t.Errorf("id=%v, want codex-abc-123", m["id"])
	}
}

// PostToolUse has a documented feedback shape, but Codex uses it by replacing
// the just-completed tool result. Peer-message delivery must not hide tool
// output, so the hook records activity/session id and leaves the inbox for Stop.
func TestBusHookDrain_PostToolUseLeavesInboxParked(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts-parent"
	if err := localbus.WriteMsg(bus, sid, "001", localbus.Msg{From: "ts-peer", Body: "hi"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", sid)

	runDrainWith(t, `{"hook_event_name":"PostToolUse","session_id":"codex-abc-123","cwd":"/repo"}`)

	left, err := localbus.ListMsgs(bus, sid)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 1 {
		t.Fatalf("PostToolUse should leave message parked, got %d left", len(left))
	}
	m, ok := readSessionMap(t, bus, sid)
	if !ok {
		t.Fatal("PostToolUse should still record the agent session mapping")
	}
	if m["id"] != "codex-abc-123" {
		t.Errorf("id=%v, want codex-abc-123", m["id"])
	}
}

// The acceptance/recovery tests below exercise the real temporary inbox rather
// than only testing response construction.

// runDrainWith invokes runBusHookDrain with payload on stdin and a throwaway
// stdout, restoring both after. The drain reads CC_BUS_DIR/CC_SESSION_ID from
// the env (set via t.Setenv by the caller) and the hook event from stdin.
func runDrainWith(t *testing.T, payload string) {
	t.Helper()
	_ = runDrainCapture(t, payload)
}

func runDrainCapture(t *testing.T, payload string) string {
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
	out, err := io.ReadAll(rOut)
	if err != nil {
		t.Fatalf("read stdout: %v", err)
	}
	return string(out)
}

func parseStopDecision(t *testing.T, out string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("parse Stop stdout %q: %v", out, err)
	}
	return m
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

func TestBusHookDrain_SubagentStopReturnsEmptyJSONAndLeavesParentInbox(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts-parent"
	if err := localbus.WriteMsg(bus, sid, "001", localbus.Msg{From: "ts-peer", Body: "hi parent"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", sid)

	out := runDrainCapture(t, `{"hook_event_name":"SubagentStop","agent_id":"sub-123","stop_hook_active":false}`)
	if out != "{}\n" {
		t.Fatalf("SubagentStop stdout=%q, want empty JSON", out)
	}
	left, err := localbus.ListMsgs(bus, sid)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 1 {
		t.Fatalf("SubagentStop stole parent inbox: got %d message(s)", len(left))
	}
}

// A top-level Stop (no agent_id) must drain normally, or messages would stay
// parked forever once the target agent reaches the end of its turn.
func TestBusHookDrain_TopLevelStopDrainsInbox(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts-parent"
	if err := localbus.WriteMsg(bus, sid, "001", localbus.Msg{From: "ts-peer", Body: "hi"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", sid)

	// no agent_id → top-level session.
	runDrainWith(t, `{"hook_event_name":"Stop"}`)

	left, err := localbus.ListMsgs(bus, sid)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		t.Fatalf("top-level hook must drain the inbox, %d message(s) left", len(left))
	}
}

func TestBusHookDrain_StdoutFailureLeavesInboxForRetry(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts-parent"
	if err := localbus.WriteMsg(bus, sid, "001", localbus.Msg{From: "ts-peer", Body: "retry me"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", sid)

	oldWriter := busHookWriteStopDecision
	busHookWriteStopDecision = func(io.Writer, string) error { return errors.New("broken stdout") }
	defer func() { busHookWriteStopDecision = oldWriter }()

	out := runDrainCapture(t, `{"hook_event_name":"Stop","stop_hook_active":false}`)
	if out != "" {
		t.Fatalf("failed stdout write produced %q", out)
	}
	left, err := localbus.ListMsgs(bus, sid)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 1 || left[0].Msg.Body != "retry me" {
		t.Fatalf("stdout failure lost the marker: %+v", left)
	}
}

func TestBusHookDrain_StopHookActiveDoesNotRepeatOrDrainNewMessage(t *testing.T) {
	bus := t.TempDir()
	const sid = "ts-parent"
	if err := localbus.WriteMsg(bus, sid, "001", localbus.Msg{From: "ts-peer", Body: "first"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", sid)

	first := parseStopDecision(t, runDrainCapture(t, `{"hook_event_name":"Stop","stop_hook_active":false}`))
	if !strings.Contains(first["reason"].(string), "first") {
		t.Fatalf("first response lost message: %+v", first)
	}
	// The first marker was cleared after the exact response was written. This
	// second message arrives while the hook-driven continuation is running and
	// must stay parked when stop_hook_active prevents a wake-loop.
	if err := localbus.WriteMsg(bus, sid, "002", localbus.Msg{From: "ts-new", Body: "second"}); err != nil {
		t.Fatal(err)
	}

	activeOut := runDrainCapture(t, `{"hook_event_name":"Stop","stop_hook_active":true}`)
	if activeOut != "{}\n" {
		t.Fatalf("stop_hook_active stdout=%q, want empty JSON to avoid a continuation loop", activeOut)
	}
	live, err := localbus.ListMsgs(bus, sid)
	if err != nil {
		t.Fatal(err)
	}
	if len(live) != 1 || live[0].Msg.Body != "second" {
		t.Fatalf("stop_hook_active drained a new message without delivery: %+v", live)
	}

	next := parseStopDecision(t, runDrainCapture(t, `{"hook_event_name":"Stop","stop_hook_active":false}`))
	nextReason := next["reason"].(string)
	if !strings.Contains(nextReason, "second") || strings.Contains(nextReason, "first") {
		t.Fatalf("next top-level Stop reason=%q, want only the new message", nextReason)
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

	runDrainWith(t, `{"hook_event_name":"Stop"}`)

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
// contending holder releases, the very next Stop hook invocation drains normally.
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

	runDrainWith(t, `{"hook_event_name":"Stop"}`)

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

func TestBusHookDrain_RecordsClaudeSpecificActivityFields(t *testing.T) {
	bus := t.TempDir()
	const ccID = "ts7"
	t.Setenv("CC_BUS_DIR", bus)
	t.Setenv("CC_SESSION_ID", ccID)

	runDrainWith(t, `{
		"hook_event_name":"TaskCreated",
		"session_id":"claude-abc-123",
		"cwd":"/repo",
		"task_id":"task-001",
		"task_subject":"Implement auth",
		"task_description":"Add login and signup endpoints",
		"teammate_name":"implementer",
		"duration_ms":42
	}`)

	entries, err := os.ReadDir(filepath.Join(bus, "events", ccID))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 activity record, got %d", len(entries))
	}
	raw, err := os.ReadFile(filepath.Join(bus, "events", ccID, entries[0].Name()))
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if m["task_id"] != "task-001" {
		t.Errorf("task_id=%v, want task-001", m["task_id"])
	}
	if m["summary"] != "Implement auth" {
		t.Errorf("summary=%v, want Implement auth", m["summary"])
	}
	if m["duration_ms"] != float64(42) {
		t.Errorf("duration_ms=%v, want 42", m["duration_ms"])
	}
}

func TestBusHookInstall_TargetsOnlyNamedAgent(t *testing.T) {
	home := t.TempDir()
	codexHome := filepath.Join(home, "codex-home")
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("CODEX_HOME", codexHome)

	if err := runBusHookInstall([]string{"codex"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(codexHome, "hooks.json")); err != nil {
		t.Fatalf("codex hooks should be written: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, ".claude", "settings.json")); !os.IsNotExist(err) {
		t.Fatalf("claude settings should not be written for codex-only install, err=%v", err)
	}
}

func TestBusHookInstall_SelectedEventsOnly(t *testing.T) {
	home := t.TempDir()
	codexHome := filepath.Join(home, "codex-home")
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("CODEX_HOME", codexHome)

	if err := runBusHookInstall([]string{"--events", "Stop", "codex"}); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(codexHome, "hooks.json")
	installed := setup.BusHooksInstalledEvents(path, setup.CodexBusHookEvents())
	if len(installed) != 1 || installed[0] != "Stop" {
		t.Fatalf("installed events=%v, want [Stop]", installed)
	}
	if setup.CodexBusHooksPresent(path) {
		t.Fatal("full codex status should be false for a selected-only install")
	}
}

func TestBusHookInstall_SelectedEventsRejectsUnsupported(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	if err := runBusHookInstall([]string{"--events", "SessionEnd", "codex"}); err == nil {
		t.Fatal("expected unsupported event error for codex")
	}
}

func TestBusHookInstall_SelectedEventsValidatesAllTargetsBeforeWriting(t *testing.T) {
	home := t.TempDir()
	codexHome := filepath.Join(home, "codex-home")
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("CODEX_HOME", codexHome)

	if err := runBusHookInstall([]string{"--events", "SessionEnd"}); err == nil {
		t.Fatal("expected unsupported event error for codex")
	}
	if _, err := os.Stat(filepath.Join(home, ".claude", "settings.json")); !os.IsNotExist(err) {
		t.Fatalf("claude settings should not be written after cross-agent validation failure, err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(codexHome, "hooks.json")); !os.IsNotExist(err) {
		t.Fatalf("codex hooks should not be written after validation failure, err=%v", err)
	}
}

func TestBusHookInstall_UnknownAgentErrors(t *testing.T) {
	if err := runBusHookInstall([]string{"nope"}); err == nil {
		t.Fatal("expected unknown agent error")
	}
}

func TestBusHookInstall_EmptyAgentErrors(t *testing.T) {
	if err := runBusHookInstall([]string{""}); err == nil {
		t.Fatal("expected empty agent error")
	}
}

func TestBusHookInstall_ManualAgentErrors(t *testing.T) {
	if err := runBusHookInstall([]string{"manual"}); err == nil {
		t.Fatal("expected manual agent error")
	}
}
