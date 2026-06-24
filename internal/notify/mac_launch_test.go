//go:build darwin

package notify

import (
	"os"
	"strings"
	"testing"

	"github.com/cc-collaboration/internal/agent"
)

// TestAppleScriptStringLit covers the AppleScript-side escaping that LaunchTerminal
// applies on top of the agent's POSIX shell command. Quoting helpers themselves
// live in internal/agent/quote.go and are tested there.
func TestAppleScriptStringLit(t *testing.T) {
	cases := map[string]string{
		"":             `""`,
		"plain":        `"plain"`,
		`with"quote`:   `"with\"quote"`,
		`back\slash`:   `"back\\slash"`,
		`both"\mixed`:  `"both\"\\mixed"`,
		"line1\nline2": `"line1\nline2"`,
	}
	for in, want := range cases {
		if got := applescriptStringLit(in); got != want {
			t.Errorf("applescriptStringLit(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBracketedPaste(t *testing.T) {
	got := bracketedPaste("hello\nworld")
	want := "\x1b[200~hello\nworld\x1b[201~"
	if got != want {
		t.Errorf("bracketedPaste mismatch: got %q want %q", got, want)
	}
}

// TestLaunchTerminalDry covers the script-building path without invoking
// osascript, by routing through Dry=true and validating it returns nil.
func TestLaunchTerminalDry(t *testing.T) {
	ag, _ := agent.Resolve("claude")
	for _, app := range []string{"", "terminal", "iterm2", "ghostty"} {
		err := LaunchTerminal(t.Context(), LaunchOpts{
			Agent:      ag,
			App:        app,
			CWD:        "/tmp/repo with space",
			PromptFile: "/tmp/repo with space/.cc-handoff/inbox/h_x/prompt.md",
			Dry:        true,
		})
		if err != nil {
			t.Errorf("dry launch app=%q: %v", app, err)
		}
	}
}

// TestGhosttyCommand asserts Ghostty launches via `open` (not osascript) and
// that the shell command stays a single intact argv (no extra quoting).
func TestGhosttyCommand(t *testing.T) {
	const shellCmd = "cd /tmp/x && claude -p foo"
	cmd := ghosttyCommand(t.Context(), shellCmd)
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	}
	want := []string{"open", "-na", "Ghostty.app", "--args", "-e", shell, "-lc", shellCmd}
	if len(cmd.Args) != len(want) {
		t.Fatalf("ghosttyCommand args = %v, want %v", cmd.Args, want)
	}
	for i := range want {
		if cmd.Args[i] != want[i] {
			t.Errorf("arg[%d] = %q, want %q", i, cmd.Args[i], want[i])
		}
	}
}

func TestLaunchTerminalRejectsUnknown(t *testing.T) {
	ag, _ := agent.Resolve("claude")
	err := LaunchTerminal(t.Context(), LaunchOpts{
		Agent:      ag,
		App:        "kitty",
		CWD:        "/tmp",
		PromptFile: "/tmp/p.md",
		Dry:        true,
	})
	if err == nil || !strings.Contains(err.Error(), "unknown terminal_app") {
		t.Errorf("expected unknown terminal_app error, got %v", err)
	}
}

func TestLaunchTerminalRequiresAgent(t *testing.T) {
	err := LaunchTerminal(t.Context(), LaunchOpts{
		CWD:        "/tmp",
		PromptFile: "/tmp/p.md",
		Dry:        true,
	})
	if err == nil || !strings.Contains(err.Error(), "Agent required") {
		t.Errorf("expected Agent required error, got %v", err)
	}
}

func TestLaunchTerminalRejectsUnknownMode(t *testing.T) {
	ag, _ := agent.Resolve("claude")
	err := LaunchTerminal(t.Context(), LaunchOpts{
		Agent:      ag,
		CWD:        "/tmp",
		PromptFile: "/tmp/p.md",
		Mode:       "tab",
		Dry:        true,
	})
	if err == nil || !strings.Contains(err.Error(), "unknown launch_mode") {
		t.Errorf("expected unknown launch_mode error, got %v", err)
	}
}

func TestLaunchTerminalInteractiveDryRun(t *testing.T) {
	ag, _ := agent.Resolve("claude")
	dir := t.TempDir()
	prompt := dir + "/prompt.md"
	if err := os.WriteFile(prompt, []byte("line1\nline2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// ghostty: covers the inject-skip note + split→window fallback under Dry.
	for _, app := range []string{"terminal", "iterm2", "ghostty"} {
		for _, mode := range []string{"window", "split"} {
			err := LaunchTerminal(t.Context(), LaunchOpts{
				Agent:       ag,
				App:         app,
				CWD:         dir,
				PromptFile:  prompt,
				PreLaunch:   "clset 6",
				Interactive: true,
				Mode:        mode,
				Dry:         true,
			})
			if err != nil {
				t.Errorf("dry interactive app=%s mode=%s: %v", app, mode, err)
			}
		}
	}
}
