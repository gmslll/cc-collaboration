package main

import (
	"context"
	"fmt"
	"os"

	"github.com/cc-collaboration/internal/agent"
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
	return runLaunchCommand(ctx, p.Path, config.BuildLaunchCommand(u, ws, p), window)
}

// runLaunchCommand executes a prepared launch command with the two strategies
// launchProject and launchAgentWithPrompt share: in-place shell exec
// (SSH-friendly, does not return on success) or a new terminal window honoring
// projectDir's repo-level [triggers]. projectDir is only consulted for the
// window's terminal-app / mode prefs.
func runLaunchCommand(ctx context.Context, projectDir, command string, window bool) error {
	if !window {
		return execInShell(command)
	}
	app, mode := projectTerminalPrefs(projectDir)
	return notify.OpenTerminalCommand(ctx, app, mode, command)
}

// launchAgentWithPrompt starts the agent on a prompt file in projectDir,
// reusing the same two execution strategies as launchProject but with a
// one-shot prompt invocation (`claude -p "$(cat prompt)"`) instead of the
// editor+agent launch command. Used by `cc-handoff logs --open` and the
// push-log auto-launch path: feed the agent a freshly-written log-triage
// prompt and let it troubleshoot in the project.
//
//   - window=false (default, SSH-friendly): replace the current shell in
//     place. Does not return on success. Errors on Windows (no exec).
//   - window=true: open a new terminal window running the same command,
//     honoring the project's repo-level [triggers] for app / mode.
//
// preLaunch is the optional shell snippet (workspace pre_launch) inserted
// between the cd and the agent. Mirrors launchProject's POSIX assumption.
func launchAgentWithPrompt(ctx context.Context, ag agent.Agent, projectDir, promptFile, preLaunch string, window bool) error {
	return runLaunchCommand(ctx, projectDir, ag.POSIXPromptCmd(projectDir, promptFile, preLaunch, false), window)
}

// projectTerminalPrefs reads the project's repo-level [triggers] for terminal
// app / launch mode, so a --window launch honors the same prefs auto-launch
// uses. The repo's terminal_app wins; when it's unset, the user-level default
// (config.toml terminal_app) applies — mirroring Resolve's user→repo precedence
// for the auto-launch path. Both empty → OpenTerminalCommand's platform default.
// Uses LoadRepo (not Resolve) so launching doesn't require a configured relay.
func projectTerminalPrefs(projectPath string) (app, mode string) {
	r, _, err := config.LoadRepo(projectPath)
	if err != nil {
		// Missing config is normal (LoadRepo returns nil,nil); a non-nil error
		// means a corrupt .cc-handoff.toml — surface it but still fall back.
		fmt.Fprintf(os.Stderr, "warning: read terminal prefs: %v\n", err)
	} else if r != nil {
		app, mode = r.Triggers.TerminalApp, r.Triggers.LaunchMode
	}
	if app == "" {
		if u, _, uerr := config.LoadUser(); uerr == nil && u != nil {
			app = u.TerminalApp
		}
	}
	return app, mode
}
