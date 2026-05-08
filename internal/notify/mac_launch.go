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

// DECSET 2004 bracketed-paste markers. Wrapping injected text with these
// makes a paste-aware REPL (Claude Code, modern shells, vim) treat the whole
// blob as one paste event instead of one line per Enter.
const (
	bracketedPasteStart = "\x1b[200~"
	bracketedPasteEnd   = "\x1b[201~"
)

// launchInjectDelaySec is how long the AppleScript pauses between starting
// the interactive agent and injecting the prompt body. Conservative; covers
// agent startup latency on most machines. If users report "prompt arrives
// before REPL is ready", lift to a config knob.
const launchInjectDelaySec = "1.5"

// LaunchTerminal opens Terminal.app or iTerm2 in the requested directory and
// starts the agent. Behavior depends on opts.Mode and opts.Interactive:
//
//   - Mode="" or "window": brand-new window
//   - Mode="split":         split-pane in the front window (iTerm2 native;
//     Terminal.app falls back to a new tab in the front
//     window since it has no native split)
//   - Interactive=true:     start the agent without -p, then send the prompt
//     body via the terminal's text-injection API,
//     wrapped in bracketed-paste markers so the REPL
//     treats it as one paste, not line-by-line input
//
// Quoting is two-layered: the agent owns POSIX shell quoting for cwd /
// promptFile / pre-launch (single-quoted, embedded ' as '\”); the entire
// shell command then becomes an AppleScript string literal with backslashes
// and double-quotes escaped.
func LaunchTerminal(ctx context.Context, opts LaunchOpts) error {
	if opts.Agent == nil {
		return fmt.Errorf("LaunchTerminal: Agent required")
	}
	if opts.CWD == "" || opts.PromptFile == "" {
		return fmt.Errorf("LaunchTerminal: CWD and PromptFile required")
	}

	app := opts.App
	if app == "" {
		app = config.TerminalAppTerminal
	}

	mode := opts.Mode
	if mode == "" {
		mode = config.LaunchModeWindow
	}
	if mode != config.LaunchModeWindow && mode != config.LaunchModeSplit {
		return fmt.Errorf("LaunchTerminal: unknown launch_mode %q (want %q or %q)",
			mode, config.LaunchModeWindow, config.LaunchModeSplit)
	}

	shellCmd := opts.Agent.POSIXPromptCmd(opts.CWD, opts.PromptFile, opts.PreLaunch, opts.Interactive)

	var promptBody string
	if opts.Interactive {
		body, err := os.ReadFile(opts.PromptFile)
		if err != nil {
			return fmt.Errorf("LaunchTerminal: read prompt %s: %w", opts.PromptFile, err)
		}
		promptBody = string(body)
	}

	var script string
	switch app {
	case config.TerminalAppITerm2:
		script = itermScript(mode, shellCmd, promptBody, opts.Interactive)
	case config.TerminalAppTerminal:
		script = terminalAppScript(mode, shellCmd, promptBody, opts.Interactive)
	default:
		return fmt.Errorf("LaunchTerminal: unknown terminal_app %q (want %q or %q)",
			app, config.TerminalAppTerminal, config.TerminalAppITerm2)
	}

	if opts.Dry {
		fmt.Fprintf(os.Stderr, "would launch terminal=%s mode=%s interactive=%t cwd=%s prompt=%s\n",
			app, mode, opts.Interactive, opts.CWD, opts.PromptFile)
		return nil
	}
	return exec.CommandContext(ctx, "osascript", "-e", script).Run()
}

func itermScript(mode, shellCmd, promptBody string, interactive bool) string {
	var sb strings.Builder
	sb.WriteString("tell application \"iTerm\"\n\tactivate\n")
	switch mode {
	case config.LaunchModeSplit:
		// Split the current session horizontally. If no window exists yet,
		// AppleScript would error; create one then split would be redundant —
		// fall through by creating a window first.
		sb.WriteString("\tif (count of windows) = 0 then\n")
		sb.WriteString("\t\tset target to (create window with default profile)\n")
		sb.WriteString("\t\tset targetSession to current session of target\n")
		sb.WriteString("\telse\n")
		sb.WriteString("\t\ttell current session of current window\n")
		sb.WriteString("\t\t\tset targetSession to (split horizontally with default profile)\n")
		sb.WriteString("\t\tend tell\n")
		sb.WriteString("\tend if\n")
	default: // window
		sb.WriteString("\tset newWindow to (create window with default profile)\n")
		sb.WriteString("\tset targetSession to current session of newWindow\n")
	}
	sb.WriteString("\ttell targetSession\n")
	sb.WriteString("\t\twrite text " + applescriptStringLit(shellCmd) + "\n")
	if interactive && promptBody != "" {
		sb.WriteString("\t\tdelay " + launchInjectDelaySec + "\n")
		sb.WriteString("\t\twrite text " + applescriptStringLit(bracketedPaste(promptBody)) + " newline NO\n")
	}
	sb.WriteString("\tend tell\nend tell")
	return sb.String()
}

func terminalAppScript(mode, shellCmd, promptBody string, interactive bool) string {
	var sb strings.Builder
	sb.WriteString("tell application \"Terminal\"\n\tactivate\n")
	switch mode {
	case config.LaunchModeSplit:
		// Terminal.app has no split-pane API. Best-effort fallback: open a
		// new tab in the front window via System Events ⌘T, then run the
		// command in the (now front-most) tab via `do script ... in window 1`.
		sb.WriteString("\tif (count of windows) = 0 then\n")
		sb.WriteString("\t\tset target to (do script " + applescriptStringLit(shellCmd) + ")\n")
		sb.WriteString("\telse\n")
		sb.WriteString("\t\ttell application \"System Events\" to keystroke \"t\" using command down\n")
		sb.WriteString("\t\tdelay 0.4\n")
		sb.WriteString("\t\tset target to (do script " + applescriptStringLit(shellCmd) + " in window 1)\n")
		sb.WriteString("\tend if\n")
	default: // window
		sb.WriteString("\tset target to (do script " + applescriptStringLit(shellCmd) + ")\n")
	}
	if interactive && promptBody != "" {
		sb.WriteString("\tdelay " + launchInjectDelaySec + "\n")
		sb.WriteString("\tdo script " + applescriptStringLit(bracketedPaste(promptBody)) + " in target\n")
	}
	sb.WriteString("end tell")
	return sb.String()
}

func bracketedPaste(s string) string {
	return bracketedPasteStart + s + bracketedPasteEnd
}

// applescriptStringLit wraps s in AppleScript double-quotes, escaping
// backslashes and double-quotes as `\\` and `\"`. Embedded newlines are
// converted to AppleScript's `\n` escape so the resulting literal stays on
// one line of source.
func applescriptStringLit(s string) string {
	r := strings.NewReplacer(
		`\`, `\\`,
		`"`, `\"`,
		"\n", `\n`,
		"\r", `\r`,
	)
	return `"` + r.Replace(s) + `"`
}
