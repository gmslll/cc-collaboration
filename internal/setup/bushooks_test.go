package setup

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// firstHookCommand digs the command out of one event's first matcher group,
// tolerating the nested {hooks:[{command}]} shape the bus installers write.
func firstHookCommand(t *testing.T, container map[string]any, event string) string {
	t.Helper()
	arr, _ := container[event].([]any)
	if len(arr) == 0 {
		t.Fatalf("event %q has no entries: %+v", event, container)
	}
	group, _ := arr[0].(map[string]any)
	hooks, _ := group["hooks"].([]any)
	if len(hooks) == 0 {
		t.Fatalf("event %q group has no hooks: %+v", event, group)
	}
	h, _ := hooks[0].(map[string]any)
	cmd, _ := h["command"].(string)
	return cmd
}

func loadJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	return m
}

func TestEnsureClaudeBusHooks_CreatesAndIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".claude", "settings.json")

	res, err := EnsureClaudeBusHooks(path)
	if err != nil {
		t.Fatalf("EnsureClaudeBusHooks: %v", err)
	}
	if res != EnsureWritten {
		t.Fatalf("expected EnsureWritten, got %v", res)
	}

	root := loadJSON(t, path)
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		t.Fatalf("missing hooks block: %+v", root)
	}
	for _, ev := range claudeBusHookEvents {
		if got := firstHookCommand(t, hooks, ev); got != BusHookCommand {
			t.Errorf("%s command=%q, want %q", ev, got, BusHookCommand)
		}
	}
	if _, has := hooks["MessageDisplay"]; has {
		t.Error("Claude install must not include high-frequency MessageDisplay by default")
	}
	if _, has := hooks["WorktreeCreate"]; has {
		t.Error("Claude install must not include WorktreeCreate because it requires path output")
	}

	// Re-run: no change, and no duplicate entries.
	res2, err := EnsureClaudeBusHooks(path)
	if err != nil {
		t.Fatalf("second EnsureClaudeBusHooks: %v", err)
	}
	if res2 != EnsureAlreadyPresent {
		t.Errorf("expected EnsureAlreadyPresent on re-run, got %v", res2)
	}
	hooks2, _ := loadJSON(t, path)["hooks"].(map[string]any)
	if arr, _ := hooks2["PostToolUse"].([]any); len(arr) != 1 {
		t.Errorf("expected 1 PostToolUse entry after re-run, got %d", len(arr))
	}
}

// BusHooksPresent must return true for a file the installer just wrote. Guards
// the JSON-escaping trap: BusHookCommand has quotes/`&&` that are escaped on disk
// (`\"$CC_BUS_DIR\"`), so matching the full command against raw bytes fails —
// detection must key off BusHookInvocation, which survives escaping verbatim.
func TestBusHooksPresent_MatchesWrittenConfig(t *testing.T) {
	claude := filepath.Join(t.TempDir(), ".claude", "settings.json")
	if _, err := EnsureClaudeBusHooks(claude); err != nil {
		t.Fatalf("EnsureClaudeBusHooks: %v", err)
	}
	if !BusHooksPresent(claude) {
		t.Errorf("BusHooksPresent=false for a freshly installed claude config")
	}
	if !ClaudeBusHooksPresent(claude) {
		t.Errorf("ClaudeBusHooksPresent=false for a freshly installed claude config")
	}

	codex := filepath.Join(t.TempDir(), ".codex", "hooks.json")
	if _, err := EnsureCodexBusHooks(codex); err != nil {
		t.Fatalf("EnsureCodexBusHooks: %v", err)
	}
	if !BusHooksPresent(codex) {
		t.Errorf("BusHooksPresent=false for a freshly installed codex config")
	}
	if !CodexBusHooksPresent(codex) {
		t.Errorf("CodexBusHooksPresent=false for a freshly installed codex config")
	}

	if BusHooksPresent(filepath.Join(t.TempDir(), "nope.json")) {
		t.Errorf("BusHooksPresent=true for a missing file")
	}
}

func TestClaudeBusHooksPresent_RejectsStaleUnsafeOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	seed := map[string]any{
		"hooks": map[string]any{
			"WorktreeCreate": []any{
				map[string]any{
					"hooks": []any{
						map[string]any{"type": "command", "command": BusHookCommand},
					},
				},
			},
		},
	}
	raw, err := json.Marshal(seed)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if !BusHooksPresent(path) {
		t.Fatal("generic BusHooksPresent should detect the stale command signature")
	}
	if ClaudeBusHooksPresent(path) {
		t.Error("ClaudeBusHooksPresent must reject stale unsafe-only installation")
	}
}

func TestEnsureClaudeBusHooks_PreservesExistingHooks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	// A pre-existing unrelated Stop hook (e.g. the wake-on-comment one) must
	// survive and the bus entry append alongside it.
	seed := `{"hooks":{"Stop":[{"type":"command","command":"cc-handoff stop-hook"}]}}`
	if err := os.WriteFile(path, []byte(seed), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := EnsureClaudeBusHooks(path); err != nil {
		t.Fatalf("EnsureClaudeBusHooks: %v", err)
	}
	hooks, _ := loadJSON(t, path)["hooks"].(map[string]any)
	stops, _ := hooks["Stop"].([]any)
	if len(stops) != 2 {
		t.Fatalf("expected 2 Stop entries (existing + bus), got %d", len(stops))
	}
}

func TestEnsureClaudeBusHooks_RemovesUnsafeBusHooksOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	seed := map[string]any{
		"hooks": map[string]any{
			"WorktreeCreate": []any{
				map[string]any{
					"hooks": []any{
						map[string]any{"type": "command", "command": BusHookCommand},
						map[string]any{"type": "command", "command": "custom-worktree-hook"},
					},
				},
			},
			"MessageDisplay": []any{
				map[string]any{
					"hooks": []any{
						map[string]any{"type": "command", "command": BusHookCommand},
					},
				},
			},
		},
	}
	raw, err := json.Marshal(seed)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := EnsureClaudeBusHooks(path); err != nil {
		t.Fatalf("EnsureClaudeBusHooks: %v", err)
	}
	hooks, _ := loadJSON(t, path)["hooks"].(map[string]any)
	if _, has := hooks["MessageDisplay"]; has {
		t.Error("bus-only MessageDisplay entry should be removed")
	}
	worktrees, _ := hooks["WorktreeCreate"].([]any)
	if len(worktrees) != 1 {
		t.Fatalf("custom WorktreeCreate group should remain, got %d groups", len(worktrees))
	}
	group, _ := worktrees[0].(map[string]any)
	handlers, _ := group["hooks"].([]any)
	if len(handlers) != 1 {
		t.Fatalf("expected only the custom WorktreeCreate hook to remain, got %d", len(handlers))
	}
	h, _ := handlers[0].(map[string]any)
	if h["command"] != "custom-worktree-hook" {
		t.Errorf("remaining command=%v, want custom-worktree-hook", h["command"])
	}
}

func TestEnsureCodexBusHooks_NestedUnderHooks(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".codex", "hooks.json")
	res, err := EnsureCodexBusHooks(path)
	if err != nil {
		t.Fatalf("EnsureCodexBusHooks: %v", err)
	}
	if res != EnsureWritten {
		t.Fatalf("expected EnsureWritten, got %v", res)
	}
	// Codex requires events under a top-level "hooks" object (not the file root,
	// which it rejects with "unknown field `PostToolUse`, expected `hooks`").
	root := loadJSON(t, path)
	if _, atRoot := root["PostToolUse"]; atRoot {
		t.Error("events must NOT be at the file root for codex")
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		t.Fatalf("missing top-level hooks object: %+v", root)
	}
	for _, ev := range codexBusHookEvents {
		if got := firstHookCommand(t, hooks, ev); got != BusHookCommand {
			t.Errorf("%s command=%q, want %q", ev, got, BusHookCommand)
		}
	}
	if _, has := hooks["SessionEnd"]; has {
		t.Error("Codex install must not include Claude-only SessionEnd hook")
	}
	if res2, _ := EnsureCodexBusHooks(path); res2 != EnsureAlreadyPresent {
		t.Errorf("expected idempotent re-run, got %v", res2)
	}
}

// A file written by an older build (events at the root) must be migrated under
// "hooks" so codex stops rejecting it — with no duplicate/leftover root entries.
func TestEnsureCodexBusHooks_MigratesRootLayout(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hooks.json")
	group := func() []any {
		return []any{
			map[string]any{
				"hooks": []any{
					map[string]any{"type": "command", "command": BusHookCommand},
				},
			},
		}
	}
	// Old (rejected) layout: events at the file root, no "hooks" wrapper.
	seed, err := json.Marshal(map[string]any{
		"PostToolUse": group(),
		"Stop":        group(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, seed, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := EnsureCodexBusHooks(path); err != nil {
		t.Fatalf("EnsureCodexBusHooks: %v", err)
	}
	root := loadJSON(t, path)
	if _, atRoot := root["PostToolUse"]; atRoot {
		t.Error("old root-level PostToolUse must be removed after migration")
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		t.Fatalf("migration did not create a hooks object: %+v", root)
	}
	for _, ev := range codexBusHookEvents {
		arr, _ := hooks[ev].([]any)
		if len(arr) != 1 {
			t.Errorf("%s should have exactly 1 entry after migration, got %d", ev, len(arr))
		}
		if got := firstHookCommand(t, hooks, ev); got != BusHookCommand {
			t.Errorf("%s command=%q, want %q", ev, got, BusHookCommand)
		}
	}
}
