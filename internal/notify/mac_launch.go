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
// directory and starts `claude -p "$(cat <PromptFile>)"`.
//
// Quoting is two-layered: the shell command uses single quotes for paths
// (POSIX-safe), then the entire shell command becomes an AppleScript string
// literal with backslashes and double-quotes escaped.
func LaunchTerminal(ctx context.Context, opts LaunchOpts) error {
	if opts.CWD == "" || opts.PromptFile == "" {
		return fmt.Errorf("LaunchTerminal: CWD and PromptFile required")
	}

	shellCmd := "cd " + shellSingleQuote(opts.CWD) +
		` && claude -p "$(cat ` + shellSingleQuote(opts.PromptFile) + `)"`

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

// shellSingleQuote wraps s in single quotes, escaping embedded single quotes
// using the POSIX idiom '\”.
func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// applescriptStringLit wraps s in AppleScript double-quotes, escaping
// backslashes and double-quotes as `\\` and `\"`.
func applescriptStringLit(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	return `"` + r.Replace(s) + `"`
}
