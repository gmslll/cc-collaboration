package main

import (
	"context"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/notify"
)

// launchProject starts an agent session for a project. It is the cmd-layer
// orchestration of config.BuildLaunchCommand (the single command-string source)
// plus an execution strategy:
//
//   - window=false (default, SSH-friendly): exec the current shell in place so
//     the terminal you're in becomes the agent session. Does not return on
//     success.
//   - window=true: open a new terminal window running the same command,
//     reusing the project's repo-level [triggers] for terminal app / mode.
//
// The command is identical on both paths — BuildLaunchCommand owns cd +
// pre_launch + editor + agent, so exec and window never diverge.
func launchProject(ctx context.Context, u *config.User, ws config.Workspace, p config.Project, window bool) error {
	command := config.BuildLaunchCommand(u, ws, p)
	if !window {
		return execInShell(command)
	}
	app, mode := projectTerminalPrefs(p.Path)
	return notify.OpenTerminalCommand(ctx, app, mode, command)
}

// projectTerminalPrefs reads the project's repo-level [triggers] for terminal
// app / launch mode, so a --window launch honors the same prefs auto-launch
// uses. Missing or unconfigured repo → empty strings, which OpenTerminalCommand
// resolves to its platform defaults. Uses LoadRepo (not Resolve) so launching
// doesn't require a configured relay/token.
func projectTerminalPrefs(projectPath string) (app, mode string) {
	r, _, err := config.LoadRepo(projectPath)
	if err != nil {
		// Missing config is normal (LoadRepo returns nil,nil); a non-nil error
		// means a corrupt .cc-handoff.toml — surface it but still fall back.
		fmt.Fprintf(os.Stderr, "warning: read terminal prefs: %v\n", err)
		return "", ""
	}
	if r == nil {
		return "", ""
	}
	return r.Triggers.TerminalApp, r.Triggers.LaunchMode
}
