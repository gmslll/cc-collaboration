//go:build windows

package notify

import (
	"strings"
	"testing"

	"github.com/cc-collaboration/internal/config"
)

func TestPSSingleQuote(t *testing.T) {
	cases := map[string]string{
		"":                `''`,
		"plain":           `'plain'`,
		"with space":      `'with space'`,
		"with'quote":      `'with''quote'`,
		"a'b'c":           `'a''b''c'`,
		`/path/with"d`:    `'/path/with"d'`,
		`C:\Users\me\dir`: `'C:\Users\me\dir'`,
	}
	for in, want := range cases {
		if got := psSingleQuote(in); got != want {
			t.Errorf("psSingleQuote(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestLaunchTerminalDry covers the command-building path without actually
// invoking cmd.exe / wt.exe / powershell.exe, by routing through Dry=true and
// validating it returns nil.
func TestLaunchTerminalDry(t *testing.T) {
	for _, app := range []string{
		"",
		config.TerminalAppWindowsTerminal,
		config.TerminalAppPowerShell,
	} {
		err := LaunchTerminal(t.Context(), LaunchOpts{
			App:        app,
			CWD:        `C:\repo with space`,
			PromptFile: `C:\repo with space\.claude\handoff-inbox\h_x\prompt.md`,
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
		CWD:        `C:\tmp`,
		PromptFile: `C:\tmp\p.md`,
		Dry:        true,
	})
	if err == nil || !strings.Contains(err.Error(), "unknown terminal_app") {
		t.Errorf("expected unknown terminal_app error, got %v", err)
	}
}

func TestLaunchTerminalRequiresCWDAndPromptFile(t *testing.T) {
	if err := LaunchTerminal(t.Context(), LaunchOpts{Dry: true}); err == nil {
		t.Error("expected error when CWD and PromptFile are empty")
	}
	if err := LaunchTerminal(t.Context(), LaunchOpts{CWD: `C:\tmp`, Dry: true}); err == nil {
		t.Error("expected error when PromptFile is empty")
	}
}
