package notify

import (
	"fmt"

	"github.com/cc-collaboration/internal/agent"
	"github.com/cc-collaboration/internal/config"
)

// LaunchOpts is the platform-neutral payload for LaunchTerminal. The actual
// LaunchTerminal implementation lives in mac_launch.go (darwin),
// mac_launch_windows.go (windows), or mac_launch_other.go (everything else).
type LaunchOpts struct {
	// Agent owns the per-tool prompt invocation; required.
	Agent agent.Agent
	// App selects the terminal program. Recognized values depend on the
	// platform:
	//   darwin:  config.TerminalAppTerminal | TerminalAppITerm2 (default Terminal.app)
	//   windows: config.TerminalAppWindowsTerminal | TerminalAppPowerShell (default auto-detect)
	App string
	// CWD is the absolute path to the receiving repo; the launched terminal
	// starts there.
	CWD string
	// PromptFile is the absolute path to prompt.md inside the materialized
	// inbox dir; the launched shell reads it and pipes it into the agent.
	PromptFile string
	// Dry logs what would happen instead of actually opening a window.
	Dry bool
	// PreLaunch is an optional shell snippet inserted between `cd <repo>`
	// and the agent invocation (e.g. "clset 6" to switch OAuth account).
	PreLaunch string
	// Interactive switches launch from one-shot (`claude -p ...`) to an
	// interactive REPL with the prompt body injected via the terminal app's
	// API after the agent starts.
	Interactive bool
	// Mode picks terminal placement: "" / "window" (new window, default) or
	// "split" (split current window). Windows always uses a new window.
	// Terminal.app has no native split; "split" falls back to a new tab there.
	Mode string
	// HandoffID is the relay id of the handoff being launched. Required when
	// AckOnLaunch != "" / "never" so the launcher can build a `cc-handoff
	// pickup <id>` chain or a postlude pointing at the right id.
	HandoffID string
	// AckOnLaunch chooses if/when the handoff is ack'd on the relay during
	// auto-launch. See config.AckOnLaunch* constants for semantics.
	AckOnLaunch string
}

// validateAckOnLaunch enforces the (mode, interactive) combos. on_launch
// runs `cc-handoff pickup <id>` before the agent invocation in the same
// shell — combining with interactive=true would mean the agent runs after
// pickup but the AppleScript prompt-body injection still has to find a
// foreground claude/codex process to type into, which is racy. Refuse
// upfront and point users at after_exit. Unknown modes also error.
func validateAckOnLaunch(mode string, interactive bool, handoffID string) error {
	switch mode {
	case config.AckOnLaunchNever:
		return nil
	case config.AckOnLaunchAfterExit, config.AckOnLaunchOnLaunch, config.AckOnLaunchSlashPickup:
		if handoffID == "" {
			return fmt.Errorf("LaunchTerminal: ack_on_launch=%q requires HandoffID", mode)
		}
	default:
		return fmt.Errorf("LaunchTerminal: unknown ack_on_launch %q (want %q, %q, %q, or %q)",
			mode, config.AckOnLaunchNever, config.AckOnLaunchAfterExit, config.AckOnLaunchOnLaunch, config.AckOnLaunchSlashPickup)
	}
	if mode == config.AckOnLaunchOnLaunch && interactive {
		return fmt.Errorf("LaunchTerminal: ack_on_launch=%q is incompatible with launch_interactive=true (set launch_interactive=false or pick %q)",
			config.AckOnLaunchOnLaunch, config.AckOnLaunchAfterExit)
	}
	if mode == config.AckOnLaunchSlashPickup && !interactive {
		return fmt.Errorf("LaunchTerminal: ack_on_launch=%q requires launch_interactive=true (slash commands need a REPL)",
			config.AckOnLaunchSlashPickup)
	}
	return nil
}
