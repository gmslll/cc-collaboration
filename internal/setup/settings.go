package setup

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// stopHookCommand is the command we install / detect under hooks.Stop. We
// match on substring so users can prefix it with their own wrapper (e.g.
// `myenv && cc-handoff stop-hook`) without losing idempotence.
const stopHookCommand = "cc-handoff stop-hook"

// EnsureResult tells the caller whether EnsureStopHook actually wrote anything.
type EnsureResult int

const (
	EnsureWritten EnsureResult = iota
	EnsureAlreadyPresent
)

// EnsureStopHook merges a Stop hook entry pointing at `cc-handoff stop-hook`
// into <repoRoot>/.claude/settings.json. Idempotent: if any existing Stop
// entry's command contains "cc-handoff stop-hook", returns
// EnsureAlreadyPresent and the file is untouched. Unknown keys at any depth
// are preserved by decoding into map[string]any with json.Number for numerics
// (so timeout: 5 doesn't get reformatted as 5.0). Atomic write protects the
// user's settings.json from corruption mid-write.
func EnsureStopHook(repoRoot string) (EnsureResult, error) {
	path := filepath.Join(repoRoot, ".claude", "settings.json")

	root, err := loadSettings(path)
	if err != nil {
		return EnsureAlreadyPresent, err
	}

	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}

	var stops []any
	if existing, ok := hooks["Stop"].([]any); ok {
		stops = existing
	}
	for _, e := range stops {
		entry, _ := e.(map[string]any)
		if cmd, _ := entry["command"].(string); strings.Contains(cmd, stopHookCommand) {
			return EnsureAlreadyPresent, nil
		}
	}

	stops = append(stops, map[string]any{
		"type":    "command",
		"command": stopHookCommand,
		"timeout": json.Number("5"),
	})
	hooks["Stop"] = stops
	root["hooks"] = hooks

	pretty, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		return EnsureAlreadyPresent, err
	}
	pretty = append(pretty, '\n')

	if err := WriteAtomic(path, pretty); err != nil {
		return EnsureAlreadyPresent, err
	}
	return EnsureWritten, nil
}

// BusHookCommand is installed on agent lifecycle hooks for the local session
// bus. It self-gates on $CC_BUS_DIR — the env var the desktop app injects into
// every session it spawns — so it's a sub-millisecond shell no-op in any other
// Claude/Codex session (other repos, plain terminals) and only does real work
// (`cc-handoff bus-hook` records activity and drains the session's bus inbox at
// Stop) inside an app-spawned session. That env guard is how one user-global
// hook stays scoped to "only the app's sessions".
// BusHookInvocation is the bare command the hook runs — the part that survives
// JSON-escaping verbatim (no quotes, &, < or > to escape), so it's the reliable
// signature to detect in a written config (see BusHooksPresent).
const BusHookInvocation = "cc-handoff bus-hook"

const BusHookCommand = `[ -n "$CC_BUS_DIR" ] && ` + BusHookInvocation + ` || true`
const BusHookJSONCommand = `if [ -n "$CC_BUS_DIR" ]; then _cc_hook_out="$(` + BusHookInvocation + `)"; [ -n "$_cc_hook_out" ] && printf "%s\n" "$_cc_hook_out" || printf "{}\n"; else printf "{}\n"; fi`

// codexBusHookEvents are the lifecycle events currently documented by Codex.
// The bus hook records all of them; only Stop drains the local-bus inbox.
var codexBusHookEvents = []string{
	"SessionStart",
	"UserPromptSubmit",
	"PreToolUse",
	"PermissionRequest",
	"PostToolUse",
	"PreCompact",
	"PostCompact",
	"SubagentStart",
	"SubagentStop",
	"Stop",
}

// claudeBusHookEvents are the lifecycle events currently documented by Claude
// Code that are useful to record by default. Claude supports a broader surface
// than Codex, so keep the install lists separate; adding Claude-only event names
// to Codex hooks.json can break Codex.
//
// Do not install MessageDisplay by default: it fires for streamed display
// deltas and would spawn this command many times during one assistant response,
// turning lightweight activity logging into visible output latency.
//
// Do not install WorktreeCreate by default either: it is not a passive
// notification hook. Claude expects this event's hook output to provide the
// worktree path, so a logging-only handler with empty stdout can interfere with
// Claude's own worktree creation.
var claudeBusHookEvents = []string{
	"SessionStart",
	"Setup",
	"UserPromptSubmit",
	"UserPromptExpansion",
	"PreToolUse",
	"PermissionRequest",
	"PermissionDenied",
	"PostToolUse",
	"PostToolUseFailure",
	"PostToolBatch",
	"PreCompact",
	"PostCompact",
	"SubagentStart",
	"SubagentStop",
	"TaskCreated",
	"TaskCompleted",
	"TeammateIdle",
	"Stop",
	"StopFailure",
	"Notification",
	"ConfigChange",
	"WorktreeRemove",
	"CwdChanged",
	"FileChanged",
	"InstructionsLoaded",
	"SessionEnd",
	"Elicitation",
	"ElicitationResult",
}

var claudeBusHookExcludedEvents = []string{
	"MessageDisplay",
	"WorktreeCreate",
}

var busHookJSONEvents = map[string]bool{
	"Stop":         true,
	"StopFailure":  true,
	"SubagentStop": true,
}

func CodexBusHookEvents() []string {
	return append([]string(nil), codexBusHookEvents...)
}

func ClaudeBusHookEvents() []string {
	return append([]string(nil), claudeBusHookEvents...)
}

func BusHooksInstalledEvents(path string, supported []string) []string {
	root, err := loadSettings(path)
	if err != nil {
		return nil
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		return nil
	}
	out := []string{}
	for _, ev := range supported {
		arr, _ := hooks[ev].([]any)
		if hookGroupsContain(arr, BusHookInvocation) {
			out = append(out, ev)
		}
	}
	return out
}

// BusHooksPresent reports whether the bus hook is installed in the agent config
// at [path] — i.e. the file exists and carries our hook. The canonical check for
// `bus-hook status`. It matches BusHookInvocation, NOT the full BusHookCommand:
// the latter's embedded quotes / `&&` are JSON-escaped when written to the config
// (`\"$CC_BUS_DIR\"`, `&&`), so a raw-bytes contains() of the full
// command would never match a properly written file.
func BusHooksPresent(path string) bool {
	b, err := os.ReadFile(path)
	return err == nil && strings.Contains(string(b), BusHookInvocation)
}

func ClaudeBusHooksPresent(path string) bool {
	return busHooksPresentFor(path, claudeBusHookEvents, claudeBusHookExcludedEvents)
}

func CodexBusHooksPresent(path string) bool {
	return busHooksPresentFor(path, codexBusHookEvents, nil)
}

func busHooksPresentFor(path string, required, excluded []string) bool {
	root, err := loadSettings(path)
	if err != nil {
		return false
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		return false
	}
	for _, ev := range required {
		arr, _ := hooks[ev].([]any)
		if !hookGroupsContain(arr, BusHookInvocation) {
			return false
		}
	}
	for _, ev := range excluded {
		arr, _ := hooks[ev].([]any)
		if hookGroupsContain(arr, BusHookInvocation) {
			return false
		}
	}
	return true
}

// EnsureClaudeBusHooks merges the bus lifecycle hooks into a Claude Code
// settings.json (typically the user-global ~/.claude/settings.json so it
// applies to app sessions in any repo). Idempotent: an event already carrying
// BusHookCommand is left untouched. Returns EnsureWritten only when it actually
// changed the file.
func EnsureClaudeBusHooks(settingsPath string) (EnsureResult, error) {
	return EnsureClaudeBusHooksFor(settingsPath, claudeBusHookEvents)
}

func EnsureClaudeBusHooksFor(settingsPath string, selectedEvents []string) (EnsureResult, error) {
	root, err := loadSettings(settingsPath)
	if err != nil {
		return EnsureAlreadyPresent, err
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	changed := false
	for _, ev := range claudeBusHookExcludedEvents {
		if removeHookEntry(hooks, ev, BusHookInvocation) {
			changed = true
		}
	}
	selected := stringSet(selectedEvents)
	for _, ev := range claudeBusHookEvents {
		if !selected[ev] {
			if removeHookEntry(hooks, ev, BusHookInvocation) {
				changed = true
			}
			continue
		}
		if ensureBusHookEntry(hooks, ev, busHookCommandForEvent(ev)) {
			changed = true
		}
	}
	if !changed {
		return EnsureAlreadyPresent, nil
	}
	root["hooks"] = hooks
	return EnsureWritten, marshalWrite(settingsPath, root)
}

// EnsureCodexBusHooks does the same for a Codex hooks.json (typically
// $CODEX_HOME/hooks.json, default ~/.codex/hooks.json). Codex expects everything
// under a top-level "hooks" object — the same nested matcher-group shape as
// Claude's settings.json. Older builds wrote the events at the FILE ROOT, which
// codex rejects ("unknown field `PostToolUse`, expected `hooks`") and then
// ignores the whole file; we migrate that layout here.
func EnsureCodexBusHooks(hooksPath string) (EnsureResult, error) {
	return EnsureCodexBusHooksFor(hooksPath, codexBusHookEvents)
}

func EnsureCodexBusHooksFor(hooksPath string, selectedEvents []string) (EnsureResult, error) {
	root, err := loadSettings(hooksPath)
	if err != nil {
		return EnsureAlreadyPresent, err
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	changed := false
	// Migrate the old rejected layout: lift any event arrays written at the file
	// root under "hooks" and drop them from the root.
	for _, ev := range codexBusHookEvents {
		if old, ok := root[ev]; ok {
			if _, exists := hooks[ev]; !exists {
				hooks[ev] = old
			}
			delete(root, ev)
			changed = true
		}
	}
	selected := stringSet(selectedEvents)
	for _, ev := range codexBusHookEvents {
		if !selected[ev] {
			if removeHookEntry(hooks, ev, BusHookInvocation) {
				changed = true
			}
			continue
		}
		if ensureBusHookEntry(hooks, ev, busHookCommandForEvent(ev)) {
			changed = true
		}
	}
	if !changed {
		return EnsureAlreadyPresent, nil
	}
	root["hooks"] = hooks
	return EnsureWritten, marshalWrite(hooksPath, root)
}

func stringSet(items []string) map[string]bool {
	out := make(map[string]bool, len(items))
	for _, item := range items {
		out[item] = true
	}
	return out
}

func busHookCommandForEvent(event string) string {
	if busHookJSONEvents[event] {
		return BusHookJSONCommand
	}
	return BusHookCommand
}

func ensureBusHookEntry(container map[string]any, event, command string) bool {
	arr, _ := container[event].([]any)
	if hookGroupsContainExact(arr, command) &&
		!hookGroupsContainStaleBusCommand(arr, command) {
		return false
	}
	changed := removeHookEntry(container, event, BusHookInvocation)
	if ensureHookEntry(container, event, command) {
		changed = true
	}
	return changed
}

// ensureHookEntry appends a matcher-less command hook for `event` into
// `container` (event-name → []group) unless some entry already references
// `command`. Writes the canonical nested shape {hooks:[{type,command}]} that
// both Claude and Codex accept for every event (including PostToolUse, which
// the flat shape EnsureStopHook uses isn't guaranteed to match for). Returns
// true iff it mutated the container.
func ensureHookEntry(container map[string]any, event, command string) bool {
	var arr []any
	if existing, ok := container[event].([]any); ok {
		arr = existing
	}
	if hookGroupsContain(arr, command) {
		return false
	}
	arr = append(arr, map[string]any{
		"hooks": []any{
			map[string]any{"type": "command", "command": command},
		},
	})
	container[event] = arr
	return true
}

func removeHookEntry(container map[string]any, event, commandSig string) bool {
	existing, ok := container[event].([]any)
	if !ok || len(existing) == 0 {
		return false
	}
	changed := false
	next := make([]any, 0, len(existing))
	for _, e := range existing {
		entry, _ := e.(map[string]any)
		if entry == nil {
			next = append(next, e)
			continue
		}
		if cmd, _ := entry["command"].(string); strings.Contains(cmd, commandSig) {
			changed = true
			continue
		}
		hooks, _ := entry["hooks"].([]any)
		if len(hooks) == 0 {
			next = append(next, e)
			continue
		}
		filtered := make([]any, 0, len(hooks))
		for _, h := range hooks {
			hook, _ := h.(map[string]any)
			cmd, _ := hook["command"].(string)
			if hook != nil && strings.Contains(cmd, commandSig) {
				changed = true
				continue
			}
			filtered = append(filtered, h)
		}
		if len(filtered) == 0 {
			changed = true
			continue
		}
		if len(filtered) != len(hooks) {
			clone := map[string]any{}
			for k, v := range entry {
				clone[k] = v
			}
			clone["hooks"] = filtered
			next = append(next, clone)
			continue
		}
		next = append(next, e)
	}
	if !changed {
		return false
	}
	if len(next) == 0 {
		delete(container, event)
	} else {
		container[event] = next
	}
	return true
}

// hookGroupsContain reports whether any entry under an event already carries
// `command`, tolerating both the flat {type,command} shape and the nested
// {hooks:[{command}]} group shape so re-installing is a no-op regardless of how
// the entry was written.
func hookGroupsContain(arr []any, command string) bool {
	for _, e := range arr {
		entry, _ := e.(map[string]any)
		if entry == nil {
			continue
		}
		if cmd, _ := entry["command"].(string); strings.Contains(cmd, command) {
			return true
		}
		nested, _ := entry["hooks"].([]any)
		for _, h := range nested {
			hm, _ := h.(map[string]any)
			if hm == nil {
				continue
			}
			if cmd, _ := hm["command"].(string); strings.Contains(cmd, command) {
				return true
			}
		}
	}
	return false
}

func hookGroupsContainExact(arr []any, command string) bool {
	for _, e := range arr {
		entry, _ := e.(map[string]any)
		if entry == nil {
			continue
		}
		if cmd, _ := entry["command"].(string); cmd == command {
			return true
		}
		nested, _ := entry["hooks"].([]any)
		for _, h := range nested {
			hm, _ := h.(map[string]any)
			if hm == nil {
				continue
			}
			if cmd, _ := hm["command"].(string); cmd == command {
				return true
			}
		}
	}
	return false
}

func hookGroupsContainStaleBusCommand(arr []any, desired string) bool {
	for _, e := range arr {
		entry, _ := e.(map[string]any)
		if entry == nil {
			continue
		}
		if cmd, _ := entry["command"].(string); strings.Contains(cmd, BusHookInvocation) && cmd != desired {
			return true
		}
		nested, _ := entry["hooks"].([]any)
		for _, h := range nested {
			hm, _ := h.(map[string]any)
			if hm == nil {
				continue
			}
			if cmd, _ := hm["command"].(string); strings.Contains(cmd, BusHookInvocation) && cmd != desired {
				return true
			}
		}
	}
	return false
}

// marshalWrite pretty-prints root and atomically writes it to path. Shared by
// the bus-hook installers (EnsureStopHook inlines the same steps for its own
// historical reasons).
func marshalWrite(path string, root map[string]any) error {
	pretty, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		return err
	}
	pretty = append(pretty, '\n')
	return WriteAtomic(path, pretty)
}

// loadSettings parses <path> into a generic map. Missing file returns an
// empty map. Numbers stay as json.Number so a round-trip can't reformat
// integers a user set to floats.
func loadSettings(path string) (map[string]any, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return map[string]any{}, nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var out map[string]any
	if err := dec.Decode(&out); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if out == nil {
		out = map[string]any{}
	}
	return out, nil
}

// WriteAtomic does mkdir + WriteFile(tmp) + Rename so a crash mid-write
// can't corrupt the user's settings.json.
func WriteAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
