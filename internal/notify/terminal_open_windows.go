//go:build windows

package notify

import (
	"context"
	"fmt"
	"os/exec"

	"github.com/cc-collaboration/internal/config"
)

// OpenTerminalCommand opens a new terminal window running shellCmd verbatim as a
// PowerShell command. mode is ignored on Windows (always a new window), matching
// LaunchTerminal. See the darwin implementation for the rationale.
func OpenTerminalCommand(ctx context.Context, app, mode, shellCmd string) error {
	_ = mode
	if app == "" {
		app = pickWindowsDefault()
	}
	var cmd *exec.Cmd
	switch app {
	case config.TerminalAppWindowsTerminal:
		cmd = exec.CommandContext(ctx, "cmd.exe", "/c", "start", "",
			"wt.exe", "powershell.exe", "-NoExit", "-NoProfile", "-Command", shellCmd)
	case config.TerminalAppPowerShell:
		cmd = exec.CommandContext(ctx, "cmd.exe", "/c", "start", "",
			"powershell.exe", "-NoExit", "-NoProfile", "-Command", shellCmd)
	default:
		return fmt.Errorf("OpenTerminalCommand: unknown terminal_app %q (want %q or %q)",
			app, config.TerminalAppWindowsTerminal, config.TerminalAppPowerShell)
	}
	return cmd.Run()
}
