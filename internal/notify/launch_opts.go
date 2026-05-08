package notify

import "github.com/cc-collaboration/internal/agent"

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
}
