//go:build windows

package notify

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/cc-collaboration/internal/config"
)

// LaunchTerminal opens a new terminal window in opts.CWD and starts
// `claude -p (Get-Content -Raw -LiteralPath <PromptFile>)`. The default
// terminal is Windows Terminal (wt.exe); if it isn't on PATH we fall back to
// a plain PowerShell window launched via cmd.exe's start verb.
//
// Quoting is single-layered: the PowerShell command uses single-quoted
// literals (PowerShell 's escape rule: double the embedded single quote),
// then the whole thing becomes a single -Command argument that exec.Command
// passes through Go's CmdLine quoting.
func LaunchTerminal(ctx context.Context, opts LaunchOpts) error {
	if opts.CWD == "" || opts.PromptFile == "" {
		return fmt.Errorf("LaunchTerminal: CWD and PromptFile required")
	}

	app := opts.App
	if app == "" {
		app = pickWindowsDefault()
	}

	inner := "Set-Location -LiteralPath " + psSingleQuote(opts.CWD) +
		"; claude -p (Get-Content -Raw -LiteralPath " + psSingleQuote(opts.PromptFile) + ")"

	var cmd *exec.Cmd
	switch app {
	case config.TerminalAppWindowsTerminal:
		// The empty "" is start's title-arg placeholder so the first quoted
		// string isn't mistaken for the window title.
		cmd = exec.CommandContext(ctx, "cmd.exe", "/c", "start", "",
			"wt.exe", "powershell.exe", "-NoExit", "-NoProfile", "-Command", inner)
	case config.TerminalAppPowerShell:
		cmd = exec.CommandContext(ctx, "cmd.exe", "/c", "start", "",
			"powershell.exe", "-NoExit", "-NoProfile", "-Command", inner)
	default:
		return fmt.Errorf("LaunchTerminal: unknown terminal_app %q (want %q or %q)",
			app, config.TerminalAppWindowsTerminal, config.TerminalAppPowerShell)
	}

	if opts.Dry {
		fmt.Fprintf(os.Stderr, "would launch terminal=%s cwd=%s prompt=%s\n",
			app, opts.CWD, opts.PromptFile)
		return nil
	}
	return cmd.Run()
}

// pickWindowsDefault picks Windows Terminal when wt.exe is on PATH (Win11
// preinstalled, easy install on Win10), and falls back to a plain PowerShell
// window otherwise. Resolution happens once per call; that's fine because
// LaunchTerminal is invoked at most once per urgent handoff.
func pickWindowsDefault() string {
	if _, err := exec.LookPath("wt.exe"); err == nil {
		return config.TerminalAppWindowsTerminal
	}
	return config.TerminalAppPowerShell
}

// psSingleQuote wraps s in a PowerShell single-quoted literal, escaping
// embedded single quotes by doubling them — PowerShell's only escape rule
// inside single-quoted strings.
func psSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}
