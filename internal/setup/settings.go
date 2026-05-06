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

	if err := writeAtomic(path, pretty); err != nil {
		return EnsureAlreadyPresent, err
	}
	return EnsureWritten, nil
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

// writeAtomic does mkdir + WriteFile(tmp) + Rename so a crash mid-write
// can't corrupt the user's settings.json.
func writeAtomic(path string, data []byte) error {
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
