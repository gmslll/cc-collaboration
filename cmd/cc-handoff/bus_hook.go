package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/cc-collaboration/internal/agent"
	"github.com/cc-collaboration/internal/localbus"
	"github.com/cc-collaboration/internal/setup"
)

// runBusHook is the local-bus counterpart of runStopHook. Two modes:
//
//   - `cc-handoff bus-hook install` wires lifecycle hooks into
//     each agent's user-global config (idempotent; the desktop app runs this
//     on start).
//   - `cc-handoff bus-hook` (no args) is the hook handler itself. The agent
//     pipes the hook event on stdin; we drain this session's bus inbox
//     ($CC_BUS_DIR/inbox/$CC_SESSION_ID) and hand the messages back as
//     additionalContext at turn end (Stop), without replacing a just-completed
//     tool result.
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
// setup's agent-specific checks) instead of being reimplemented in the app.
func runBusHookStatus() error {
	type entry struct {
		Agent           string   `json:"agent"`
		Path            string   `json:"path"`
		Installed       bool     `json:"installed"`
		AvailableEvents []string `json:"available_events"`
		InstalledEvents []string `json:"installed_events"`
		MissingEvents   []string `json:"missing_events"`
	}
	out := []entry{}
	for _, ag := range agent.All() {
		path, err := ag.BusHookConfigPath()
		if err != nil || path == "" {
			continue // no hook config for this agent (manual)
		}
		installed := setup.BusHooksPresent(path)
		switch ag.Name() {
		case "claude":
			installed = setup.ClaudeBusHooksPresent(path)
		case "codex":
			installed = setup.CodexBusHooksPresent(path)
		}
		available := busHookEventsForAgent(ag.Name())
		installedEvents := setup.BusHooksInstalledEvents(path, available)
		out = append(out, entry{
			Agent:           ag.Name(),
			Path:            path,
			Installed:       installed,
			AvailableEvents: available,
			InstalledEvents: installedEvents,
			MissingEvents:   missingStrings(available, installedEvents),
		})
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}

func busHookEventsForAgent(name string) []string {
	switch name {
	case "claude":
		return setup.ClaudeBusHookEvents()
	case "codex":
		return setup.CodexBusHookEvents()
	default:
		return nil
	}
}

func missingStrings(all, have []string) []string {
	seen := map[string]bool{}
	for _, s := range have {
		seen[s] = true
	}
	out := []string{}
	for _, s := range all {
		if !seen[s] {
			out = append(out, s)
		}
	}
	return out
}

func installBusHooksForAgentEvents(ag agent.Agent, events []string) error {
	path, err := ag.BusHookConfigPath()
	if err != nil {
		return err
	}
	if path == "" {
		return fmt.Errorf("agent %q has no bus hook config", ag.Name())
	}
	switch ag.Name() {
	case "claude":
		res, err := setup.EnsureClaudeBusHooksFor(path, events)
		if err != nil {
			return err
		}
		reportInstallResult("claude", path, res)
	case "codex":
		res, err := setup.EnsureCodexBusHooksFor(path, events)
		if err != nil {
			return err
		}
		reportInstallResult("codex", path, res)
	default:
		return fmt.Errorf("agent %q has no bus hook event list", ag.Name())
	}
	return nil
}

func reportInstallResult(name, path string, res setup.EnsureResult) {
	switch res {
	case setup.EnsureWritten:
		fmt.Printf("  ✓ installed selected cc-handoff bus hooks for %s → %s\n", name, path)
	case setup.EnsureAlreadyPresent:
		fmt.Printf("  · selected %s bus hooks already present (%s)\n", name, path)
	}
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
	// parent's own Stop hook or the app's idle sweep.
	AgentID string `json:"agent_id"`
	// SessionID + Cwd are the agent's OWN session identity, carried in every
	// Claude Code and Codex hook event. We record CC_SESSION_ID -> SessionID so
	// the desktop app can bind a tab to the agent's exact session for resume
	// (see recordAgentSession). codex (unlike claude) can't be told an id at
	// launch, so this hook is its authoritative, event-driven id source.
	SessionID string `json:"session_id"`
	Cwd       string `json:"cwd"`
}

// busHookDrainLockTimeout bounds how long the hook waits for the inbox drain
// lock (localbus.AcquireDrainLock) before giving up and leaving messages
// parked for the next hook. A var, not a const, so tests can shrink it rather
// than eating the full wait when exercising the contended path.
var busHookDrainLockTimeout = 2 * time.Second

func runBusHookDrain() error {
	// Drain stdin unconditionally and first: the agent pipes a hook payload and
	// returning without consuming it can block the writer or surface an EPIPE in
	// the transcript. Parse is best-effort; an empty/garbage payload simply
	// records no event-specific details and will not drain the inbox.
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

	recordHookActivity(busDir, sid, raw, ev)

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

	// The hook is installed on every lifecycle event so the app can record a
	// useful activity stream, but bus message delivery itself is only safe on
	// Stop. Its delivery contract does not risk hiding a tool result. Codex's
	// PostToolUse "block" feedback replaces the just-completed tool result,
	// which is wrong for peer-message delivery; keep messages parked until Stop
	// can pull a clean continuation turn.
	//
	// Other events either do not support additionalContext for this purpose
	// (PermissionRequest, PreCompact, PostCompact), would be surprising delivery
	// points, or would replace useful tool output (PostToolUse). Leave messages
	// parked for Stop instead of
	// clearing them into an ignored hook response.
	if !supportsBusDeliveryEvent(ev.HookEventName) {
		return nil
	}

	// A Stop already inside a hook-driven continuation must not re-block (a
	// wake-loop). Bail BEFORE draining so the messages stay parked for a later
	// top-level Stop — clearing them here would silently drop them.
	if ev.HookEventName == "Stop" && ev.StopHookActive {
		return nil
	}

	// Hold the inbox drain lock for the whole list-render-clear sequence below,
	// so the desktop app's escalate-timeout path (which force-delivers a parked
	// message this hook hasn't drained in time — see terminal_deck.dart) can
	// never act on the same marker file at the same time (double delivery). A
	// busy lock means the app is actively escalating this inbox right now;
	// bail quietly rather than blocking the agent's tool call/turn — the
	// messages the app didn't escalate stay parked for the next hook.
	release, lockErr := localbus.AcquireDrainLock(busDir, sid, busHookDrainLockTimeout)
	if lockErr != nil {
		return nil
	}
	defer release()

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

func supportsBusDeliveryEvent(name string) bool {
	return name == "Stop"
}

func recordHookActivity(busDir, sid string, raw []byte, ev busHookEvent) {
	if busDir == "" || sid == "" || len(raw) == 0 {
		return
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return
	}
	event := str(m["hook_event_name"])
	if event == "" {
		event = ev.HookEventName
	}
	if event == "" {
		event = "Hook"
	}
	at := time.Now().UTC()
	out := map[string]any{
		"at":                    at.Format(time.RFC3339Nano),
		"event":                 event,
		"session_id":            str(m["session_id"]),
		"turn_id":               str(m["turn_id"]),
		"agent_id":              str(m["agent_id"]),
		"agent_type":            str(m["agent_type"]),
		"agent_transcript_path": str(m["agent_transcript_path"]),
		"cwd":                   str(m["cwd"]),
		"model":                 str(m["model"]),
		"permission_mode":       str(m["permission_mode"]),
		"transcript_path":       str(m["transcript_path"]),
		"tool_name":             str(m["tool_name"]),
		"tool_use_id":           str(m["tool_use_id"]),
		"exit_code":             m["exit_code"],
		"source":                str(m["source"]),
		"trigger":               str(m["trigger"]),
		"stop_active":           m["stop_hook_active"],
	}
	for _, key := range []string{
		"duration_ms",
		"task_id",
		"task_subject",
		"task_description",
		"teammate_name",
		"team_name",
		"notification_type",
		"message_id",
		"index",
		"final",
		"error",
		"error_details",
		"file_path",
		"old_cwd",
		"new_cwd",
		"mcp_server_name",
		"mode",
		"action",
		"elicitation_id",
		"worktree_path",
		"permission_suggestions",
		"background_tasks",
		"session_crons",
	} {
		if v, ok := m[key]; ok {
			out[key] = v
		}
	}
	addSnippet(out, "prompt", m["prompt"], 1200)
	addSnippet(out, "message", m["message"], 1200)
	addSnippet(out, "delta", m["delta"], 1200)
	addSnippet(out, "tool_input", m["tool_input"], 2000)
	addSnippet(out, "tool_response", firstPresent(m, "tool_response", "tool_output"), 2000)
	addSnippet(out, "last_assistant_message", m["last_assistant_message"], 2000)
	addSnippet(out, "content", m["content"], 1200)
	addSnippet(out, "requested_schema", m["requested_schema"], 1200)
	addSnippet(out, "summary", activitySummary(m), 2000)

	dir := filepath.Join(busDir, "events", sid)
	name := fmt.Sprintf("%020d-%s.json", at.UnixNano(), sanitizeEventName(event))
	_ = writePrivateAtomic(filepath.Join(dir, name), mustJSON(out))
	pruneHookActivities(dir, 200)
}

func writePrivateAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	_ = os.Chmod(filepath.Dir(path), 0o700)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func firstPresent(m map[string]any, keys ...string) any {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			return v
		}
	}
	return nil
}

func addSnippet(out map[string]any, key string, v any, limit int) {
	s := snippet(v, limit)
	if s != "" {
		out[key] = s
	}
}

func activitySummary(m map[string]any) string {
	for _, key := range []string{
		"prompt",
		"message",
		"delta",
		"task_subject",
		"task_description",
		"error_details",
		"error",
		"last_assistant_message",
		"file_path",
		"source",
		"trigger",
		"mcp_server_name",
		"action",
		"notification_type",
	} {
		if s := snippet(m[key], 2000); s != "" {
			return s
		}
	}
	oldCwd, newCwd := str(m["old_cwd"]), str(m["new_cwd"])
	if oldCwd != "" || newCwd != "" {
		return strings.TrimSpace(oldCwd + " -> " + newCwd)
	}
	return ""
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

func snippet(v any, limit int) string {
	if v == nil {
		return ""
	}
	var b strings.Builder
	appendSnippetValue(&b, v, limit)
	s := b.String()
	s = strings.TrimSpace(s)
	if len(s) > limit {
		return s[:limit] + "…"
	}
	return s
}

func appendSnippetValue(b *strings.Builder, v any, limit int) {
	if b.Len() >= limit {
		return
	}
	write := func(s string) {
		if b.Len() >= limit {
			return
		}
		if b.Len()+len(s) > limit {
			s = s[:limit-b.Len()]
		}
		b.WriteString(s)
	}
	switch x := v.(type) {
	case string:
		write(x)
	case nil:
		write("null")
	case bool:
		write(fmt.Sprint(x))
	case float64:
		write(fmt.Sprint(x))
	case json.Number:
		write(x.String())
	case []any:
		write("[")
		for i, item := range x {
			if i >= 6 || b.Len() >= limit {
				write("…")
				break
			}
			if i > 0 {
				write(", ")
			}
			appendSnippetValue(b, item, limit)
		}
		write("]")
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		write("{")
		for i, k := range keys {
			if i >= 12 || b.Len() >= limit {
				write("…")
				break
			}
			if i > 0 {
				write(", ")
			}
			write(k + ": ")
			appendSnippetValue(b, x[k], limit)
		}
		write("}")
	default:
		write(fmt.Sprint(x))
	}
}

func sanitizeEventName(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	if b.Len() == 0 {
		return "Hook"
	}
	return b.String()
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		return []byte("{}")
	}
	return append(b, '\n')
}

func pruneHookActivities(dir string, keep int) {
	files, err := os.ReadDir(dir)
	if err != nil || len(files) <= keep {
		return
	}
	var names []string
	for _, f := range files {
		if !f.IsDir() && strings.HasSuffix(f.Name(), ".json") {
			names = append(names, f.Name())
		}
	}
	if len(names) <= keep {
		return
	}
	sort.Strings(names)
	for _, n := range names[:len(names)-keep] {
		_ = os.Remove(filepath.Join(dir, n))
	}
}

// busHookResponse shapes the Stop-hook output. Stop blocks to pull the agent
// into a fresh turn with the messages (the cross-machine wake-on-comment
// pattern). The "Stop already inside a continuation" case is handled upstream in
// runBusHookDrain (it bails before draining so messages stay parked), so this is
// only reached when a response is wanted.
func busHookResponse(ev busHookEvent, ctxText string, n int) map[string]any {
	if ev.HookEventName == "Stop" {
		return map[string]any{
			"decision": "block",
			"reason":   ctxText,
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
	selectedEvents, args, err := parseBusHookInstallArgs(args)
	if err != nil {
		return err
	}
	// With no args, install for every known agent: each writes its own
	// user-global config (Claude ~/.claude/settings.json, Codex
	// ~/.codex/hooks.json), idempotent and env-guarded, so this is safe to run
	// on every app start. With args, install only the named agents so the manual
	// UI/CLI flow can repair exactly what the user chooses.
	targets := agent.All()
	if selectedEvents != nil && len(args) == 0 {
		targets = targets[:0]
		for _, ag := range agent.All() {
			if len(busHookEventsForAgent(ag.Name())) > 0 {
				targets = append(targets, ag)
			}
		}
	}
	if len(args) > 0 {
		targets = targets[:0]
		seen := map[string]bool{}
		for _, name := range args {
			name = strings.TrimSpace(name)
			if name == "" {
				return fmt.Errorf("agent name is required")
			}
			ag, err := agent.Resolve(name)
			if err != nil {
				return err
			}
			if seen[ag.Name()] {
				continue
			}
			path, err := ag.BusHookConfigPath()
			if err != nil {
				return err
			}
			if path == "" {
				return fmt.Errorf("agent %q has no bus hook config", ag.Name())
			}
			seen[ag.Name()] = true
			targets = append(targets, ag)
		}
	}
	eventsByAgent := map[string][]string{}
	if selectedEvents != nil {
		for _, ag := range targets {
			events, err := validateBusHookEvents(ag.Name(), selectedEvents)
			if err != nil {
				return err
			}
			eventsByAgent[ag.Name()] = events
		}
	}
	var firstErr error
	for _, ag := range targets {
		var err error
		if selectedEvents == nil {
			err = ag.InstallBusHooks(os.Stdout)
		} else {
			err = installBusHooksForAgentEvents(ag, eventsByAgent[ag.Name()])
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "bus-hook install (%s): %v\n", ag.Name(), err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	if len(args) > 0 || selectedEvents != nil {
		return firstErr
	}
	return nil
}

func parseBusHookInstallArgs(args []string) ([]string, []string, error) {
	var events []string
	sawEvents := false
	out := []string{}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--events" || arg == "--event":
			sawEvents = true
			i++
			if i >= len(args) {
				return nil, nil, fmt.Errorf("%s requires a comma-separated hook list", arg)
			}
			events = append(events, splitHookEvents(args[i])...)
		case strings.HasPrefix(arg, "--events="):
			sawEvents = true
			events = append(events, splitHookEvents(strings.TrimPrefix(arg, "--events="))...)
		case strings.HasPrefix(arg, "--event="):
			sawEvents = true
			events = append(events, splitHookEvents(strings.TrimPrefix(arg, "--event="))...)
		default:
			out = append(out, arg)
		}
	}
	if sawEvents && len(events) == 0 {
		return nil, nil, fmt.Errorf("--events requires at least one hook")
	}
	if !sawEvents {
		return nil, out, nil
	}
	return events, out, nil
}

func splitHookEvents(raw string) []string {
	out := []string{}
	for _, part := range strings.Split(raw, ",") {
		ev := strings.TrimSpace(part)
		if ev != "" {
			out = append(out, ev)
		}
	}
	return out
}

func validateBusHookEvents(agentName string, events []string) ([]string, error) {
	allowed := busHookEventsForAgent(agentName)
	if len(allowed) == 0 {
		return nil, fmt.Errorf("agent %q has no selectable bus hooks", agentName)
	}
	allowedSet := map[string]bool{}
	for _, ev := range allowed {
		allowedSet[ev] = true
	}
	seen := map[string]bool{}
	out := []string{}
	for _, ev := range events {
		if !allowedSet[ev] {
			return nil, fmt.Errorf("hook %q is not supported by %s", ev, agentName)
		}
		if seen[ev] {
			continue
		}
		seen[ev] = true
		out = append(out, ev)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("at least one hook must be selected")
	}
	return out, nil
}
