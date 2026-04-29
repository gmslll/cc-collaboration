//go:build darwin

package notify

import (
	"strings"
	"testing"
)

func TestShellSingleQuote(t *testing.T) {
	cases := map[string]string{
		"":             `''`,
		"plain":        `'plain'`,
		"with space":   `'with space'`,
		"with'quote":   `'with'\''quote'`,
		"a'b'c":        `'a'\''b'\''c'`,
		`/path/with"d`: `'/path/with"d'`,
	}
	for in, want := range cases {
		if got := shellSingleQuote(in); got != want {
			t.Errorf("shellSingleQuote(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAppleScriptStringLit(t *testing.T) {
	cases := map[string]string{
		"":            `""`,
		"plain":       `"plain"`,
		`with"quote`:  `"with\"quote"`,
		`back\slash`:  `"back\\slash"`,
		`both"\mixed`: `"both\"\\mixed"`,
	}
	for in, want := range cases {
		if got := applescriptStringLit(in); got != want {
			t.Errorf("applescriptStringLit(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestLaunchTerminalDry covers the script-building path without invoking
// osascript, by routing through Dry=true and validating it returns nil.
func TestLaunchTerminalDry(t *testing.T) {
	for _, app := range []string{"", "terminal", "iterm2"} {
		err := LaunchTerminal(t.Context(), LaunchOpts{
			App:        app,
			CWD:        "/tmp/repo with space",
			PromptFile: "/tmp/repo with space/.claude/handoff-inbox/h_x/prompt.md",
			Dry:        true,
		})
		if err != nil {
			t.Errorf("dry launch app=%q: %v", app, err)
		}
	}
}

func TestLaunchTerminalRejectsUnknown(t *testing.T) {
	err := LaunchTerminal(t.Context(), LaunchOpts{
		App:        "kitty",
		CWD:        "/tmp",
		PromptFile: "/tmp/p.md",
		Dry:        true,
	})
	if err == nil || !strings.Contains(err.Error(), "unknown terminal_app") {
		t.Errorf("expected unknown terminal_app error, got %v", err)
	}
}
