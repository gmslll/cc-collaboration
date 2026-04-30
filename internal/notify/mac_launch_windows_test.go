//go:build windows

package notify

import (
	"strings"
	"testing"

	"github.com/cc-collaboration/internal/agent"
	"github.com/cc-collaboration/internal/config"
)

// TestLaunchTerminalDry covers the command-building path without actually
// invoking cmd.exe / wt.exe / powershell.exe, by routing through Dry=true and
// validating it returns nil. PowerShell quoting is owned by the agent and
// tested in internal/agent.
func TestLaunchTerminalDry(t *testing.T) {
	ag, _ := agent.Resolve("claude")
	for _, app := range []string{
		"",
		config.TerminalAppWindowsTerminal,
		config.TerminalAppPowerShell,
	} {
		err := LaunchTerminal(t.Context(), LaunchOpts{
			Agent:      ag,
			App:        app,
			CWD:        `C:\repo with space`,
			PromptFile: `C:\repo with space\.cc-handoff\inbox\h_x\prompt.md`,
			Dry:        true,
		})
		if err != nil {
			t.Errorf("dry launch app=%q: %v", app, err)
		}
	}
}

func TestLaunchTerminalRejectsUnknown(t *testing.T) {
	ag, _ := agent.Resolve("claude")
	err := LaunchTerminal(t.Context(), LaunchOpts{
		Agent:      ag,
		App:        "kitty",
		CWD:        `C:\tmp`,
		PromptFile: `C:\tmp\p.md`,
		Dry:        true,
	})
	if err == nil || !strings.Contains(err.Error(), "unknown terminal_app") {
		t.Errorf("expected unknown terminal_app error, got %v", err)
	}
}

func TestLaunchTerminalRequiresAgent(t *testing.T) {
	err := LaunchTerminal(t.Context(), LaunchOpts{
		CWD:        `C:\tmp`,
		PromptFile: `C:\tmp\p.md`,
		Dry:        true,
	})
	if err == nil || !strings.Contains(err.Error(), "Agent required") {
		t.Errorf("expected Agent required error, got %v", err)
	}
}

func TestLaunchTerminalRequiresCWDAndPromptFile(t *testing.T) {
	ag, _ := agent.Resolve("claude")
	if err := LaunchTerminal(t.Context(), LaunchOpts{Agent: ag, Dry: true}); err == nil {
		t.Error("expected error when CWD and PromptFile are empty")
	}
	if err := LaunchTerminal(t.Context(), LaunchOpts{Agent: ag, CWD: `C:\tmp`, Dry: true}); err == nil {
		t.Error("expected error when PromptFile is empty")
	}
}
