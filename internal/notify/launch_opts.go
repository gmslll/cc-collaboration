package notify

// LaunchOpts is the platform-neutral payload for LaunchTerminal. The actual
// LaunchTerminal implementation lives in mac_launch.go (darwin),
// mac_launch_windows.go (windows), or mac_launch_other.go (everything else).
type LaunchOpts struct {
	// App selects the terminal program. Recognized values depend on the
	// platform:
	//   darwin:  config.TerminalAppTerminal | TerminalAppITerm2 (default Terminal.app)
	//   windows: config.TerminalAppWindowsTerminal | TerminalAppPowerShell (default auto-detect)
	App string
	// CWD is the absolute path to the receiving repo; the launched terminal
	// starts there.
	CWD string
	// PromptFile is the absolute path to prompt.md inside the materialized
	// inbox dir; the launched shell reads it and pipes it into `claude -p`.
	PromptFile string
	// Dry logs what would happen instead of actually opening a window.
	Dry bool
}
