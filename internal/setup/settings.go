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

// BusHookCommand is the command installed under PostToolUse + Stop for the
// local session bus. It self-gates on $CC_BUS_DIR — the env var the desktop
// app injects into every session it spawns — so it's a sub-millisecond shell
// no-op in any other Claude/Codex session (other repos, plain terminals) and
// only does real work (`cc-handoff bus-hook` drains the session's bus inbox)
// inside an app-spawned session. That env guard is how one user-global hook
// stays scoped to "only the app's sessions".
const BusHookCommand = `[ -n "$CC_BUS_DIR" ] && cc-handoff bus-hook || true`

// busHookEvents are the two lifecycle events the bus hook rides: PostToolUse
// surfaces a peer message mid-turn (next tool boundary), Stop catches it at
// turn end when the turn made no further tool calls.
var busHookEvents = []string{"PostToolUse", "Stop"}

// BusHooksPresent reports whether the bus hook is installed in the agent config
// at [path] — i.e. the file exists and carries BusHookCommand. The canonical
// check for `bus-hook status`, so the self-check can't drift from the installer.
func BusHooksPresent(path string) bool {
	b, err := os.ReadFile(path)
	return err == nil && strings.Contains(string(b), BusHookCommand)
}

// EnsureClaudeBusHooks merges the bus PostToolUse + Stop hooks into a Claude
// Code settings.json (typically the user-global ~/.claude/settings.json so it
// applies to app sessions in any repo). Idempotent: an event already carrying
// BusHookCommand is left untouched. Returns EnsureWritten only when it actually
// changed the file.
func EnsureClaudeBusHooks(settingsPath string) (EnsureResult, error) {
	root, err := loadSettings(settingsPath)
	if err != nil {
		return EnsureAlreadyPresent, err
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	changed := false
	for _, ev := range busHookEvents {
		if ensureHookEntry(hooks, ev, BusHookCommand) {
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
// $CODEX_HOME/hooks.json, default ~/.codex/hooks.json). Codex's hooks.json puts
// the lifecycle events at the file root (no "hooks" wrapper), but the matcher
// group / command-handler shape is identical to Claude's — same BusHookCommand,
// same env-guard scoping.
func EnsureCodexBusHooks(hooksPath string) (EnsureResult, error) {
	root, err := loadSettings(hooksPath)
	if err != nil {
		return EnsureAlreadyPresent, err
	}
	changed := false
	for _, ev := range busHookEvents {
		if ensureHookEntry(root, ev, BusHookCommand) {
			changed = true
		}
	}
	if !changed {
		return EnsureAlreadyPresent, nil
	}
	return EnsureWritten, marshalWrite(hooksPath, root)
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
