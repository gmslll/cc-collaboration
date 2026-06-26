package main

import "testing"

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
