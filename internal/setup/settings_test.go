package setup

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnsureStopHook_CreatesFile(t *testing.T) {
	root := t.TempDir()
	res, err := EnsureStopHook(root)
	if err != nil {
		t.Fatalf("EnsureStopHook: %v", err)
	}
	if res != EnsureWritten {
		t.Errorf("expected EnsureWritten, got %v", res)
	}

	body := readSettings(t, root)
	if !strings.Contains(body, stopHookCommand) {
		t.Errorf("settings.json missing stop hook command: %s", body)
	}
	stops := stopEntries(t, body)
	if len(stops) != 1 {
		t.Fatalf("expected 1 Stop entry, got %d", len(stops))
	}
}

func TestEnsureStopHook_Idempotent(t *testing.T) {
	root := t.TempDir()
	if _, err := EnsureStopHook(root); err != nil {
		t.Fatalf("first EnsureStopHook: %v", err)
	}
	res, err := EnsureStopHook(root)
	if err != nil {
		t.Fatalf("second EnsureStopHook: %v", err)
	}
	if res != EnsureAlreadyPresent {
		t.Errorf("expected EnsureAlreadyPresent on second call, got %v", res)
	}
	stops := stopEntries(t, readSettings(t, root))
	if len(stops) != 1 {
		t.Fatalf("expected 1 Stop entry after re-run, got %d", len(stops))
	}
}

func TestEnsureStopHook_PreservesUnknownKeys(t *testing.T) {
	root := t.TempDir()
	settingsPath := filepath.Join(root, ".claude", "settings.json")
	if err := os.MkdirAll(filepath.Dir(settingsPath), 0o755); err != nil {
		t.Fatal(err)
	}
	pre := `{
  "model": "claude-opus-4-7",
  "env": {"FOO": "bar"},
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre"}]}]
  }
}`
	if err := os.WriteFile(settingsPath, []byte(pre), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := EnsureStopHook(root); err != nil {
		t.Fatalf("EnsureStopHook: %v", err)
	}

	body := readSettings(t, root)
	for _, want := range []string{"claude-opus-4-7", "FOO", "PreToolUse", "echo pre", stopHookCommand} {
		if !strings.Contains(body, want) {
			t.Errorf("settings.json missing %q after merge:\n%s", want, body)
		}
	}
}

func TestEnsureStopHook_AppendsAlongsideExistingStopEntry(t *testing.T) {
	root := t.TempDir()
	settingsPath := filepath.Join(root, ".claude", "settings.json")
	if err := os.MkdirAll(filepath.Dir(settingsPath), 0o755); err != nil {
		t.Fatal(err)
	}
	pre := `{"hooks":{"Stop":[{"type":"command","command":"echo other"}]}}`
	if err := os.WriteFile(settingsPath, []byte(pre), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := EnsureStopHook(root); err != nil {
		t.Fatalf("EnsureStopHook: %v", err)
	}
	stops := stopEntries(t, readSettings(t, root))
	if len(stops) != 2 {
		t.Fatalf("expected 2 Stop entries (existing + ours), got %d", len(stops))
	}
}

func readSettings(t *testing.T, root string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, ".claude", "settings.json"))
	if err != nil {
		t.Fatalf("read settings.json: %v", err)
	}
	return string(b)
}

func stopEntries(t *testing.T, body string) []map[string]any {
	t.Helper()
	var parsed map[string]any
	if err := json.Unmarshal([]byte(body), &parsed); err != nil {
		t.Fatalf("parse settings.json: %v", err)
	}
	hooks, _ := parsed["hooks"].(map[string]any)
	rawStops, _ := hooks["Stop"].([]any)
	var out []map[string]any
	for _, e := range rawStops {
		if m, ok := e.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}
