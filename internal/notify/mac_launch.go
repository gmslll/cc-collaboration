//go:build darwin

package notify

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/cc-collaboration/internal/config"
)

// LaunchTerminal opens a new Terminal.app or iTerm2 window in the requested
// directory and starts the agent's prompt invocation.
//
// Quoting is two-layered: the agent owns POSIX shell quoting for cwd /
// promptFile (single-quoted, embedded ' as '\”); the entire shell command
// then becomes an AppleScript string literal with backslashes and
// double-quotes escaped.
func LaunchTerminal(ctx context.Context, opts LaunchOpts) error {
	if opts.Agent == nil {
		return fmt.Errorf("LaunchTerminal: Agent required")
	}
	if opts.CWD == "" || opts.PromptFile == "" {
		return fmt.Errorf("LaunchTerminal: CWD and PromptFile required")
	}

	shellCmd := opts.Agent.POSIXPromptCmd(opts.CWD, opts.PromptFile)

	app := opts.App
	if app == "" {
		app = config.TerminalAppTerminal
	}

	var script string
	switch app {
	case config.TerminalAppITerm2:
		script = `tell application "iTerm"
	activate
	set newWindow to (create window with default profile)
	tell current session of newWindow
		write text ` + applescriptStringLit(shellCmd) + `
	end tell
end tell`
	case config.TerminalAppTerminal:
		script = `tell application "Terminal"
	activate
	do script ` + applescriptStringLit(shellCmd) + `
end tell`
	default:
		return fmt.Errorf("LaunchTerminal: unknown terminal_app %q (want %q or %q)",
			app, config.TerminalAppTerminal, config.TerminalAppITerm2)
	}

	if opts.Dry {
		fmt.Fprintf(os.Stderr, "would launch terminal=%s cwd=%s prompt=%s\n",
			app, opts.CWD, opts.PromptFile)
		return nil
	}
	return exec.CommandContext(ctx, "osascript", "-e", script).Run()
}

// applescriptStringLit wraps s in AppleScript double-quotes, escaping
// backslashes and double-quotes as `\\` and `\"`.
func applescriptStringLit(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	return `"` + r.Replace(s) + `"`
}
