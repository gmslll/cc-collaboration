//go:build darwin

package notify

import (
	"context"
	"fmt"
	"os/exec"

	"github.com/cc-collaboration/internal/config"
)

// OpenTerminalCommand opens a new terminal window (or split) running shellCmd
// verbatim. Unlike LaunchTerminal — which rebuilds the command from an Agent +
// prompt file — this runs a caller-supplied command string as-is, so the
// workspace launcher's BuildLaunchCommand output is the single source of truth
// for both the in-place exec path and this windowed path. No prompt injection.
//
// app: "" → Terminal.app default; "terminal" | "iterm2".
// mode: "" → window; "window" | "split".
func OpenTerminalCommand(ctx context.Context, app, mode, shellCmd string) error {
	if app == "" {
		app = config.TerminalAppTerminal
	}
	if mode == "" {
		mode = config.LaunchModeWindow
	}
	if mode != config.LaunchModeWindow && mode != config.LaunchModeSplit {
		return fmt.Errorf("OpenTerminalCommand: unknown launch_mode %q (want %q or %q)",
			mode, config.LaunchModeWindow, config.LaunchModeSplit)
	}

	// ghostty launches directly via `open` (no AppleScript dictionary, window
	// only); terminal/iterm2 go through osascript.
	var cmd *exec.Cmd
	switch app {
	case config.TerminalAppGhostty:
		cmd = ghosttyCommand(ctx, shellCmd)
	case config.TerminalAppITerm2:
		cmd = osascriptCommand(ctx, itermScript(mode, shellCmd, postLaunchInject{kind: injectKindNone}))
	case config.TerminalAppTerminal:
		cmd = osascriptCommand(ctx, terminalAppScript(mode, shellCmd, postLaunchInject{kind: injectKindNone}))
	default:
		return fmt.Errorf("OpenTerminalCommand: unknown terminal_app %q (want %q, %q or %q)",
			app, config.TerminalAppTerminal, config.TerminalAppITerm2, config.TerminalAppGhostty)
	}
	return cmd.Run()
}
