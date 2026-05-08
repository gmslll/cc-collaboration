//go:build darwin

package notify

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/cc-collaboration/internal/agent"
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

// afterExitInteractivePostludeFmt is appended to the materialized prompt
// body when ack_on_launch="after_exit" + interactive — instructs the agent
// to ack via pickup_handoff MCP at end of turn. %s is the handoff id.
const afterExitInteractivePostludeFmt = "\n\n## After integration\n\n**Important**: before completing this turn, call the `pickup_handoff` MCP tool with `id=%s` to ack the relay. The watch daemon already materialized files; this just updates the relay state from `pending` to `picked`.\n"

// pickupSlashCommand is the slash command typed into the REPL when
// ack_on_launch="slash_pickup". Resolves to .claude/commands/pickup.md.
const pickupSlashCommand = "/pickup"

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

	ackMode := opts.AckOnLaunch
	if ackMode == "" {
		ackMode = config.AckOnLaunchNever
	}
	if err := validateAckOnLaunch(ackMode, opts.Interactive, opts.HandoffID); err != nil {
		return err
	}

	preLaunch := opts.PreLaunch
	if ackMode == config.AckOnLaunchOnLaunch {
		// Inject the pickup as part of preLaunch so it lands BETWEEN cd and
		// the agent invocation. Brace-group + `; true` makes it always
		// succeed at the shell level — if the relay is unreachable, claude
		// still opens. Cwd is preserved (no subshell). Quote the id so a
		// hostile id can't escape (relay-issued ids are ASCII alnum + _,
		// but defense in depth is cheap).
		pickup := "{ cc-handoff pickup " + agent.POSIXSingleQuote(opts.HandoffID) + " ; true ; }"
		if preLaunch != "" {
			preLaunch = preLaunch + " && " + pickup
		} else {
			preLaunch = pickup
		}
	}

	shellCmd := opts.Agent.POSIXPromptCmd(opts.CWD, opts.PromptFile, preLaunch, opts.Interactive)

	if ackMode == config.AckOnLaunchAfterExit && !opts.Interactive {
		// Chain pickup AFTER the agent exits; `&&` so it only acks on a
		// successful claude run.
		shellCmd += " && cc-handoff pickup " + agent.POSIXSingleQuote(opts.HandoffID)
	}

	// inject describes what to send to the started REPL after the shellCmd has
	// had a moment to bring the agent up. `text` is the literal payload; `kind`
	// picks how the AppleScript layer types it:
	//   - injectKindNone: nothing to inject
	//   - injectKindPaste: wrap with bracketed-paste markers, no trailing
	//                     newline (multi-line prompt body)
	//   - injectKindLine: type as a single line, with default trailing return
	//                    (slash command — claude submits it)
	var inject postLaunchInject
	if opts.Interactive {
		switch ackMode {
		case config.AckOnLaunchSlashPickup:
			inject = postLaunchInject{kind: injectKindLine, text: pickupSlashCommand}
		default:
			body, err := os.ReadFile(opts.PromptFile)
			if err != nil {
				return fmt.Errorf("LaunchTerminal: read prompt %s: %w", opts.PromptFile, err)
			}
			text := string(body)
			if ackMode == config.AckOnLaunchAfterExit {
				text += fmt.Sprintf(afterExitInteractivePostludeFmt, opts.HandoffID)
			}
			inject = postLaunchInject{kind: injectKindPaste, text: text}
		}
	}

	var script string
	switch app {
	case config.TerminalAppITerm2:
		script = itermScript(mode, shellCmd, inject)
	case config.TerminalAppTerminal:
		script = terminalAppScript(mode, shellCmd, inject)
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

type injectKind int

const (
	injectKindNone injectKind = iota
	injectKindPaste
	injectKindLine
)

type postLaunchInject struct {
	kind injectKind
	text string
}

func itermScript(mode, shellCmd string, inj postLaunchInject) string {
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
	switch inj.kind {
	case injectKindPaste:
		sb.WriteString("\t\tdelay " + launchInjectDelaySec + "\n")
		sb.WriteString("\t\twrite text " + applescriptStringLit(bracketedPaste(inj.text)) + " newline NO\n")
	case injectKindLine:
		sb.WriteString("\t\tdelay " + launchInjectDelaySec + "\n")
		sb.WriteString("\t\twrite text " + applescriptStringLit(inj.text) + "\n")
	}
	sb.WriteString("\tend tell\nend tell")
	return sb.String()
}

func terminalAppScript(mode, shellCmd string, inj postLaunchInject) string {
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
	switch inj.kind {
	case injectKindPaste:
		sb.WriteString("\tdelay " + launchInjectDelaySec + "\n")
		sb.WriteString("\tdo script " + applescriptStringLit(bracketedPaste(inj.text)) + " in target\n")
	case injectKindLine:
		sb.WriteString("\tdelay " + launchInjectDelaySec + "\n")
		sb.WriteString("\tdo script " + applescriptStringLit(inj.text) + " in target\n")
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
