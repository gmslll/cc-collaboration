package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/cc-collaboration/internal/agent"
	"github.com/cc-collaboration/internal/localbus"
	"github.com/cc-collaboration/internal/setup"
)

// runBusHook is the local-bus counterpart of runStopHook. Two modes:
//
//   - `cc-handoff bus-hook install` wires the PostToolUse + Stop hooks into
//     each agent's user-global config (idempotent; the desktop app runs this
//     on start).
//   - `cc-handoff bus-hook` (no args) is the hook handler itself. The agent
//     pipes the hook event on stdin; we drain this session's bus inbox
//     ($CC_BUS_DIR/inbox/$CC_SESSION_ID) and hand the messages back as
//     additionalContext so a peer's message surfaces mid-turn (PostToolUse, at
//     the next tool boundary) or, failing that, at turn end (Stop).
//
// Same hook contract on Claude Code and Codex, so this one binary serves both.
func runBusHook(ctx context.Context, args []string) error {
	if len(args) > 0 && args[0] == "install" {
		return runBusHookInstall(args[1:])
	}
	if len(args) > 0 && args[0] == "status" {
		return runBusHookStatus()
	}
	return runBusHookDrain()
}

// runBusHookStatus prints, as JSON, whether the bus hook is installed in each
// agent's config. Backs the desktop app's hook self-check so the config paths
// and the "installed" criterion have ONE source of truth (the agent package +
// setup.BusHooksPresent) instead of being reimplemented in the app.
func runBusHookStatus() error {
	type entry struct {
		Agent     string `json:"agent"`
		Path      string `json:"path"`
		Installed bool   `json:"installed"`
	}
	out := []entry{}
	for _, ag := range agent.All() {
		path, err := ag.BusHookConfigPath()
		if err != nil || path == "" {
			continue // no hook config for this agent (manual)
		}
		out = append(out, entry{
			Agent:     ag.Name(),
			Path:      path,
			Installed: setup.BusHooksPresent(path),
		})
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}

// busHookEvent is the slice of the agent's hook payload we care about. Both
// Claude Code and Codex pipe this JSON on stdin with snake_case keys.
type busHookEvent struct {
	HookEventName  string `json:"hook_event_name"`
	StopHookActive bool   `json:"stop_hook_active"`
	// AgentID is present ONLY when the hook fires inside a Task subagent call
	// (per Claude Code's documented hook payload). A subagent inherits the
	// parent's CC_SESSION_ID via env, so without this gate its tool calls would
	// drain the PARENT session's inbox into the subagent's context and delete
	// it — the parent agent and user would never see those peer messages. We
	// skip draining whenever AgentID is set so messages stay parked for the
	// parent's own next tool boundary / Stop / the app's idle sweep.
	AgentID string `json:"agent_id"`
	// SessionID + Cwd are the agent's OWN session identity, carried in every
	// Claude Code and Codex hook event. We record CC_SESSION_ID -> SessionID so
	// the desktop app can bind a tab to the agent's exact session for resume
	// (see recordAgentSession). codex (unlike claude) can't be told an id at
	// launch, so this hook is its authoritative, event-driven id source.
	SessionID string `json:"session_id"`
	Cwd       string `json:"cwd"`
}

func runBusHookDrain() error {
	// Drain stdin unconditionally and first: the agent pipes a hook payload and
	// returning without consuming it can block the writer or surface an EPIPE in
	// the transcript. Parse is best-effort — an empty/garbage payload still
	// drains the inbox, just via the safe (non-blocking) PostToolUse shape.
	raw, _ := io.ReadAll(os.Stdin)
	var ev busHookEvent
	_ = json.Unmarshal(raw, &ev)

	busDir := os.Getenv("CC_BUS_DIR")
	sid := os.Getenv("CC_SESSION_ID")
	if busDir == "" || sid == "" {
		// Not an app-spawned session. Quiet no-op (the installed hook command
		// also shell-guards on $CC_BUS_DIR, so we usually aren't even invoked).
		return nil
	}

	// Running inside a Task subagent: the inherited CC_SESSION_ID points at the
	// PARENT's inbox, so draining here would steal the parent's peer messages
	// into this subagent's context (and ClearMsgs would delete them). Bail so
	// they stay parked for the parent session itself. See busHookEvent.AgentID.
	if ev.AgentID != "" {
		return nil
	}

	// Record this tab's agent session id for the desktop app to resume exactly.
	// Done on EVERY top-level hook (before the no-messages early return below), so
	// it lands within the session's first turn regardless of bus traffic.
	recordAgentSession(busDir, sid, ev.SessionID, ev.Cwd)

	// A Stop already inside a hook-driven continuation must not re-block (a
	// wake-loop). Bail BEFORE draining so the messages stay parked for the next
	// tool boundary (PostToolUse) or a later top-level Stop — clearing them here
	// would silently drop them.
	if ev.HookEventName == "Stop" && ev.StopHookActive {
		return nil
	}

	entries, err := localbus.ListMsgs(busDir, sid)
	if err != nil || len(entries) == 0 {
		return nil
	}

	// Render the same "[来自 label · id] body" header + reply hint the app pastes
	// for an idle target, so the receiving agent can't tell the delivery path
	// apart and already knows how to answer over the bus.
	var b strings.Builder
	fmt.Fprintf(&b, "📨 收到 %d 条同机会话消息:\n\n", len(entries))
	for _, e := range entries {
		label := e.Msg.FromLabel
		if label == "" {
			label = e.Msg.From
		}
		fmt.Fprintf(&b, "[来自 %s · %s] %s\n", label, e.Msg.From, e.Msg.Body)
	}
	fmt.Fprintf(&b, "\n↩ 回复发件人(用方括号里的 id):cc-handoff msg send %s \"<内容>\"\n", entries[0].Msg.From)

	// Clear before printing so a stdout failure can't strand markers and re-fire
	// the same messages next hook (a wake-loop), matching runStopHook.
	localbus.ClearMsgs(entries)

	if err := json.NewEncoder(os.Stdout).Encode(busHookResponse(ev, b.String(), len(entries))); err != nil {
		fmt.Fprintf(os.Stderr, "bus-hook: encode JSON: %v\n", err)
	}
	return nil
}

// busHookResponse shapes the hook output for the event. Stop blocks to pull the
// agent into a fresh turn with the messages (the cross-machine wake-on-comment
// pattern); every other event (PostToolUse, and the empty default) injects
// additionalContext without blocking so the running turn keeps going. The "Stop
// already inside a continuation" case is handled upstream in runBusHookDrain (it
// bails before draining so messages stay parked), so this is only reached when a
// response is actually wanted.
func busHookResponse(ev busHookEvent, ctxText string, n int) map[string]any {
	if ev.HookEventName == "Stop" {
		return map[string]any{
			"decision": "block",
			"reason":   fmt.Sprintf("cc-handoff: 收到 %d 条同机会话消息,见 hookSpecificOutput.additionalContext。", n),
			"hookSpecificOutput": map[string]any{
				"hookEventName":     ev.HookEventName,
				"additionalContext": ctxText,
			},
		}
	}
	name := ev.HookEventName
	if name == "" {
		name = "PostToolUse"
	}
	return map[string]any{
		"hookSpecificOutput": map[string]any{
			"hookEventName":     name,
			"additionalContext": ctxText,
		},
	}
}

// recordAgentSession persists the mapping CC_SESSION_ID -> agent session_id that
// every Claude/Codex hook payload carries, to $CC_BUS_DIR/sessions/<ccID>.json.
// The desktop app reads it (keyed by the tab's CC_SESSION_ID) to bind the tab to
// the agent's exact session — the event-driven counterpart to its lsof/rollout
// scan, and the only capture path that works on Windows. Best-effort: the hook's
// real job is draining the inbox, so all errors here are swallowed.
func recordAgentSession(busDir, ccID, agentSessionID, cwd string) {
	if busDir == "" || ccID == "" || agentSessionID == "" {
		return
	}
	payload, err := json.Marshal(map[string]any{"id": agentSessionID, "cwd": cwd})
	if err != nil {
		return
	}
	dst := filepath.Join(busDir, "sessions", ccID+".json")
	// The hook fires on EVERY tool call; the mapping rarely changes, so skip the
	// rewrite when the file already holds it (marshal is key-sorted = stable).
	if existing, err := os.ReadFile(dst); err == nil && bytes.Equal(existing, payload) {
		return
	}
	_ = setup.WriteAtomic(dst, payload) // best-effort; draining is the hook's real job
}

func runBusHookInstall(args []string) error {
	// Install for every known agent: each writes its own user-global config
	// (Claude ~/.claude/settings.json, Codex ~/.codex/hooks.json), idempotent
	// and env-guarded, so this is safe to run on every app start. manual no-ops.
	for _, ag := range agent.All() {
		if err := ag.InstallBusHooks(os.Stdout); err != nil {
			fmt.Fprintf(os.Stderr, "bus-hook install (%s): %v\n", ag.Name(), err)
		}
	}
	return nil
}
